#!/usr/bin/env python3
"""Verify trusted public WSS with a native VM and actual CoopSession.

Uses no real credential. Only unauthenticated and invalid-token requests are sent;
no rooms, profiles, or match records are created on the target server.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location("fvm_wss_helpers",Path(__file__).with_name("test-coop-transport.py"))
network=importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)
helpers=network.helpers

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url",required=True,help="Trusted wss:// endpoint ending in /game")
    args=parser.parse_args()
    if not args.url.startswith("wss://"):
        parser.error("A trusted WSS endpoint is required; verification cannot be disabled")
    os.umask(0o077)
    parent=Path.home()/"Library/Caches/FVM-Reborn/coop-wss-tests"
    parent.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix="run-",dir=parent))
    print("Test workspace: "+str(root),flush=True)
    app_id="io.github.9tempest.fvmreborn.coop-wss-tests."+uuid.uuid4().hex
    project=network.prepare(root,app_id,args.url,args.url)
    metadata=helpers.read_yy(project)
    relative="scripts/CoopSession/CoopSession.yy"
    yy=helpers.read_yy(project.parent/"scripts/CoopTransport/CoopTransport.yy")
    yy.update({"%Name":"CoopSession","name":"CoopSession"})
    helpers.write_yy(project.parent/relative,yy)
    source=(helpers.REPO/"scripts/CoopSession/CoopSession.gml").read_bytes()
    (project.parent/relative).with_suffix(".gml").write_bytes(source)
    metadata["resources"].append({"id":{"name":"CoopSession","path":relative}})
    for name in ("obj_battle","obj_game_over"):
        relative="objects/"+name+"/"+name+".yy"
        yy=helpers.read_yy(project.parent/"objects/obj_transport_test/obj_transport_test.yy")
        yy.update({"%Name":name,"name":name,"eventList":[]})
        helpers.write_yy(project.parent/relative,yy)
        metadata["resources"].append({"id":{"name":name,"path":relative}})
    helpers.write_yy(project,metadata)
    fixture=Path(__file__).with_name("coop-wss-fixture.gml").read_text().replace("@SERVER_URL@",json.dumps(args.url))
    (project.parent/"scripts/transport_fixture/transport_fixture.gml").write_text(fixture)
    (project.parent/"objects/obj_transport_test/Other_68.gml").write_text("var _session_socket = global.session.transport.socket;\nglobal.transport.handle_event(async_load);\nif (_session_socket >= 0) wss_session_event(global.session.transport.handle_event(async_load));\n")
    helpers.write_yy(root/"manifest.json",{"app_id":app_id,"url":args.url,"session_sha256":hashlib.sha256(source).hexdigest(),"credentials":"No valid credentials used","production_writes":False})
    report=network.build_run(root,project,app_id)
    helpers.write_yy(root/"results.json",report)
    print(str(int(report["passed"]))+"/"+str(int(report["total"]))+" public WSS assertions passed.")
    print("Report: "+str(root/"results.json"))
    return 0 if report["passed"]==report["total"] else 1

if __name__=="__main__":
    sys.exit(main())
