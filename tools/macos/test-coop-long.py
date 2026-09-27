#!/usr/bin/env python3
"""Native large-frame and 72-second JSON-heartbeat test on WS and optional WSS.

Requires the same macOS toolchain as test-coop-transport.py and websockets.
--cloudflared opens a temporary test-only tunnel and shuts it down after the run.
The test server has no credentials, filesystem access, or game database.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import threading
import time
import uuid
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location("fvm_long_helpers",Path(__file__).with_name("test-coop-transport.py"))
network=importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)
helpers=network.helpers

FIXTURE=r'''
function long_expect(_name,_passed){array_push(global.long_tests,{name:_name,passed:_passed});show_debug_message((_passed?"PASS ":"FAIL ")+_name);}
function long_event(_index,_event){
 if(!is_struct(_event)||global.long_done)return;
 var _r=global.long_results[_index];var _peer=global.long_peers[_index];
 if(_event.kind=="connected"){
  _r.connected_at=current_time;_r.connected=true;
  long_expect(_r.name+" connects",true);_peer.send({type:"request_large",size:102400});
 }else if(_event.kind=="error"){
  _r.error=_event.code;long_expect(_r.name+" unexpected transport error "+_event.code,false);
 }else if(_event.kind=="message"){
  var _p=_event.data;
  if(_p.type=="pong"){_r.pongs++;_r.last_pong_ms=current_time-_r.connected_at;}
  if(_p.type=="large"){
   var _expected=string_repeat("a",_p.size)+"中文";
   long_expect(_r.name+" receives complete "+string(_p.size)+" byte payload",_p.body==_expected && string_byte_length(_p.body)==_p.size+6);
   long_expect(_r.name+" sends large standard text frame",_peer.send({type:"large_client",size:_p.size,body:_expected}));
  }
  if(_p.type=="large_ack"){
   long_expect(_r.name+" server verifies complete "+string(_p.size)+" byte payload",_p.valid && _p.bytes==_p.size+6);
   _r.large_roundtrips++;if(_p.size==102400)_peer.send({type:"request_large",size:1048576});
  }
 }
}
function long0(_event){long_event(0,_event);}function long1(_event){long_event(1,_event);}
function transport_test_start(){
 global.long_start=current_time;global.long_ping=0;global.long_done=false;global.long_tests=[];global.long_results=[];
 global.long_peers=[new CoopTransport(long0),new CoopTransport(long1)];var _urls=@URLS@;global.long_count=array_length(_urls);
 for(var _i=0;_i<global.long_count;_i++){
  array_push(global.long_results,{name:_i==0?"WS":"WSS",connected:false,connected_at:0,pongs:0,last_pong_ms:0,large_roundtrips:0,error:""});
  global.long_peers[_i].idle_timeout_ms=15000;
  long_expect((_i==0?"WS":"WSS")+" asynchronous connect accepted",global.long_peers[_i].connect(_urls[_i]));
 }
}
function transport_test_step(){
 if(global.long_done)return;
 for(var _i=0;_i<global.long_count;_i++)global.long_peers[_i].tick();
 if(current_time-global.long_ping>=5000){global.long_ping=current_time;for(var _i=0;_i<global.long_count;_i++)if(global.long_peers[_i].state=="open")global.long_peers[_i].send({type:"ping",seq:floor((current_time-global.long_start)/5000)});}
 if(current_time-global.long_start>=@DURATION@){
  global.long_done=true;var _passed=0;
  for(var _i=0;_i<global.long_count;_i++){
   var _r=global.long_results[_i];
   long_expect(_r.name+" JSON heartbeat survives at least 65 seconds",_r.last_pong_ms>=65000 && _r.error=="" && _r.pongs>=13);
   long_expect(_r.name+" both large frames roundtrip",_r.large_roundtrips==2);
   global.long_peers[_i].close();
  }
  for(var _i=0;_i<array_length(global.long_tests);_i++)if(global.long_tests[_i].passed)_passed++;
  show_debug_message("FVM_TRANSPORT_RESULT="+json_stringify({kind:"native_long_large",passed:_passed,total:array_length(global.long_tests),tests:global.long_tests,connections:global.long_results}));game_end();
 }
}
'''

class LongServer:
    def __init__(self):
        self.ready=threading.Event();self.records=[];self.error=None
        self.thread=threading.Thread(target=self.run,daemon=True)
    def run(self):
        try:asyncio.run(self.serve())
        except BaseException as error:self.error=error;self.ready.set()
    async def serve(self):
        from websockets.asyncio.server import serve
        from websockets.exceptions import ConnectionClosed
        self.loop=asyncio.get_running_loop();self.stop=asyncio.Event()
        async def connection(ws):
            started=time.monotonic()
            try:
                async for message in ws:
                    packet=json.loads(message);kind=packet.get("type")
                    if kind=="ping":await ws.send(json.dumps({"type":"pong","seq":packet.get("seq")}))
                    elif kind=="request_large" and packet.get("size") in (102400,1048576):
                        size=int(packet["size"])
                        await ws.send(json.dumps({"type":"large","size":size,"body":"a"*size+"中文"},ensure_ascii=False))
                    elif kind=="large_client" and packet.get("size") in (102400,1048576):
                        size=int(packet["size"]);body=packet.get("body","");valid=body=="a"*size+"中文"
                        record={"event":"large_client","size":size,"bytes":len(body.encode()),"valid":valid,"sha256":hashlib.sha256(body.encode()).hexdigest()}
                        self.records.append(record)
                        await ws.send(json.dumps({"type":"large_ack",**record}))
                    else:await ws.close(code=1008,reason="Unsupported test request")
            except ConnectionClosed as error:self.records.append({"event":"closed","detail":str(error),"elapsed":time.monotonic()-started})
            finally:self.records.append({"event":"finished","elapsed":time.monotonic()-started})
        # Runtime 2026.0.0.23 sends an unmasked control PONG on macOS.
        # Keep RFC frame validation; use the application's JSON heartbeat instead.
        async with serve(connection,"127.0.0.1",0,ping_interval=None,compression=None,max_size=4194304,close_timeout=1) as server:
            self.port=server.sockets[0].getsockname()[1];self.ready.set();await self.stop.wait()
    def start(self):
        self.thread.start()
        if not self.ready.wait(10) or self.error:raise RuntimeError("Test server failed: "+str(self.error))
    def close(self):
        if hasattr(self,"loop") and not self.loop.is_closed():self.loop.call_soon_threadsafe(self.stop.set)
        self.thread.join(4)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloudflared",type=Path,help="Optional official binary for a disposable public WSS test tunnel")
    parser.add_argument("--duration",type=int,default=75,help="Native run duration; minimum 72 seconds")
    args=parser.parse_args()
    if args.duration<72:parser.error("Use at least 72 seconds to cover three 20-second intervals")
    os.umask(0o077)
    parent=Path.home()/"Library/Caches/FVM-Reborn/coop-long-tests";parent.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix="run-",dir=parent));server=LongServer();tunnel=None;reader=None
    print("Workspace: "+str(root),flush=True)
    logging.basicConfig(filename=root/"websockets-debug.log",level=logging.DEBUG,format="%(asctime)s %(name)s %(levelname)s %(message)s")
    try:
        server.start();urls=["ws://127.0.0.1:"+str(server.port)+"/game"]
        if args.cloudflared:
            config=root/"quick-tunnel.yml";config.write_text("{}\n")
            tunnel=subprocess.Popen([str(args.cloudflared),"tunnel","--config",str(config),"--no-autoupdate","--url","http://127.0.0.1:"+str(server.port),"--protocol","http2","--metrics","127.0.0.1:0","--management-diagnostics=false"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+45;url=None;registered=False;log=(root/"tunnel.log").open("wb")
            while time.monotonic()<deadline and not (url and registered):
                if not select.select([tunnel.stdout],[],[],1)[0]:continue
                line=tunnel.stdout.readline();log.write(line);log.flush()
                if not line:raise RuntimeError("Temporary tunnel stopped unexpectedly")
                match=re.search(rb"https://[a-z0-9-]+\.trycloudflare\.com",line)
                if match:url=match.group().decode().replace("https://","wss://")+"/game"
                if b"Registered tunnel connection" in line:registered=True
            if not url or not registered:raise RuntimeError("Temporary tunnel did not become ready")
            urls.append(url)
            def drain():
                for line in tunnel.stdout:log.write(line);log.flush()
                log.close()
            reader=threading.Thread(target=drain,daemon=True);reader.start()
            # Tunnel registration may precede public DNS propagation. Probe the
            # actual trusted TLS endpoint before starting the native timer.
            from websockets.asyncio.client import connect
            async def probe():
                async with connect(url,ping_interval=None,open_timeout=8) as ws:
                    await ws.send(json.dumps({"type":"ping","seq":-1}))
                    reply=json.loads(await asyncio.wait_for(ws.recv(),8))
                    if reply.get("type")!="pong":raise RuntimeError("Unexpected WSS probe response")
            deadline=time.monotonic()+180
            while True:
                try:asyncio.run(probe());break
                except Exception:
                    if time.monotonic()>=deadline:raise RuntimeError("Temporary public DNS/TLS endpoint did not become ready")
                    time.sleep(2)
            print("Temporary WSS test tunnel passed DNS/TLS readiness probe",flush=True)
        app_id="io.github.9tempest.fvmreborn.coop-long-tests."+uuid.uuid4().hex
        project=network.prepare(root,app_id,urls[0],urls[0])
        fixture=FIXTURE.replace("@URLS@",json.dumps(urls)).replace("@DURATION@",str(args.duration*1000))
        (project.parent/"scripts/transport_fixture/transport_fixture.gml").write_text(fixture)
        (project.parent/"objects/obj_transport_test/Other_68.gml").write_text("for(var _i=0;_i<global.long_count;_i++)global.long_peers[_i].handle_event(async_load);\n")
        original=helpers.command
        def command(command_args,*rest,**kwargs):
            if str(command_args[0]).endswith("/Mac_Runner"):kwargs["timeout"]=args.duration+25
            return original(command_args,*rest,**kwargs)
        helpers.command=command
        helpers.write_yy(root/"manifest.json",{"app_id":app_id,"transport_sha256":hashlib.sha256((helpers.REPO/"scripts/CoopTransport/CoopTransport.gml").read_bytes()).hexdigest(),"urls":urls,"duration":args.duration,"control_ping":False,"synthetic_test_data_only":True})
        result=network.build_run(root,project,app_id);helpers.write_yy(root/"results.json",result)
        print(str(int(result["passed"]))+"/"+str(int(result["total"]))+" native long-connection and large-frame checks passed.")
        print("Report: "+str(root/"results.json"))
        return 0 if result["passed"]==result["total"] else 1
    finally:
        if tunnel and tunnel.poll() is None:
            tunnel.terminate()
            try:tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired:tunnel.kill();tunnel.wait()
        if reader:reader.join(2)
        server.close();helpers.write_yy(root/"server-results.json",server.records)

if __name__=="__main__":sys.exit(main())
