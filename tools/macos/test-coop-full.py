#!/usr/bin/env python3
"""Run two isolated copies of the complete native game through a real co-op battle.

The test injects only a controller into a temporary project, uses a fresh server
and two unique sandbox identities, and never opens the installed user game/save.
An explicit fixture starting-flame balance permits immediate placement of two
starter cards. A synthetic victory then exercises production rewards/SQLite.
Screenshots are saved for visual review.
"""
import argparse, importlib.util, json, os, plistlib, re, select, shutil, sqlite3
import subprocess, sys, tempfile, time, uuid
from pathlib import Path
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('full_support',HERE/'test-autosave.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)

def clone(source,dest):
    # Copy code and metadata; immutable art can share inodes to keep fixtures small.
    if source.suffix.lower() in {'.png','.ogg','.wav','.mp3','.ttf','.otf','.dll','.dylib'}:
        os.link(source,dest)
    else:shutil.copy2(source,dest)

def prepare(root,appid):
    project=root/'project'
    shutil.copytree(s.REPO,project,copy_function=lambda a,b:clone(Path(a),Path(b)),
                    ignore=shutil.ignore_patterns('.git','.venv','__pycache__','serverdata','build','.DS_Store'))
    yypfile=project/'FVM-Reborn.yyp';yyp=s.read_yy(yypfile)
    name='obj_coop_full_fixture';meta=s.read_yy(project/'objects/obj_coop_controller/obj_coop_controller.yy')
    meta['name']=meta['%Name']=name
    meta['eventList']=[e for e in meta['eventList'] if e['eventType'] in (0,3)]
    s.write_yy(project/f'objects/{name}/{name}.yy',meta)
    (project/f'objects/{name}/Create_0.gml').write_text('coop_full_init();\n')
    (project/f'objects/{name}/Step_0.gml').write_text('coop_full_step();\n')
    script='coop_full_fixture';meta=s.read_yy(project/'scripts/CoopSession/CoopSession.yy')
    meta['name']=meta['%Name']=script
    s.write_yy(project/f'scripts/{script}/{script}.yy',meta)
    shutil.copyfile(HERE/'coop-full-fixture.gml',project/f'scripts/{script}/{script}.gml')
    yyp['resources'] += [{'id':{'name':n,'path':f'{kind}/{n}/{n}.yy'}} for kind,n in [('objects',name),('scripts',script)]]
    s.write_yy(yypfile,yyp)
    p=project/'objects/obj_game_init/Other_2.gml'
    p.write_text(p.read_text()+f'\ninstance_create_depth(0,0,-90000,{name});\n')
    # Native fixture has its own identifier even before packaging into two apps.
    p=project/'options/mac/options_mac.yy';m=s.read_yy(p)
    m['option_mac_app_id']=appid;m['option_mac_display_name']='FVM Co-op Integration'
    s.write_yy(p,m)
    return yypfile

def package(root,runtime,role,appid):
    app=root/('FVM Co-op '+role+'.app')
    subprocess.run([sys.executable,str(HERE/'package-local.py'),'--runtime',str(runtime),
        '--game-zip',str(root/'output/game.zip'),'--icon',str(s.REPO/'options/mac/icons/1024.png'),
        '--output',str(app)],check=True,stdout=subprocess.DEVNULL)
    p=app/'Contents/Info.plist';d=plistlib.loads(p.read_bytes())
    d.update(CFBundleIdentifier=appid,CFBundleName='FVM Co-op '+role,CFBundleDisplayName='FVM Co-op '+role)
    p.write_bytes(plistlib.dumps(d))
    ent=root/'entitlements.plist';ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.files.user-selected.read-write':True}))
    subprocess.run(['codesign','--force','--sign','-','--entitlements',str(ent),str(app)],check=True,capture_output=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    return app

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reuse',type=Path,help='Recompile a previous isolated fixture with refreshed production sources')
    parser.add_argument('--reuse-compiled',action='store_true',help='With --reuse, package fresh sandbox identities from its unchanged prior game.zip; useful for retrying external tunnel setup')
    parser.add_argument('--tunnel',action='store_true',help='Run both native clients through a disposable public WSS tunnel to the temporary test database')
    parser.add_argument('--cloudflared',type=Path,default=Path.home()/'Library/Application Support/FVM-Reborn/co-op/bin/cloudflared',help='Existing cloudflared binary used only with --tunnel')
    args=parser.parse_args()
    if args.reuse_compiled and not args.reuse:parser.error('--reuse-compiled requires --reuse')
    os.umask(0o077)
    parent=Path.home()/'Library/Caches/FVM-Reborn/coop-full-tests';parent.mkdir(parents=True,exist_ok=True)
    root=args.reuse or Path(tempfile.mkdtemp(prefix='run-',dir=parent))
    print('Full-game fixture: '+str(root),flush=True)
    appid='io.github.9tempest.fvmreborn.coopfull.'+uuid.uuid4().hex
    if args.reuse_compiled:
        yypfile=root/'project/FVM-Reborn.yyp'
        if not (root/'output/game.zip').is_file():raise RuntimeError('No compiled isolated game.zip exists in this fixture')
    elif args.reuse:
        # Reuse immutable assets/cache, replacing every production source/metadata.
        project=root/'project'
        for group in ['scripts','objects']:
            for p in (s.REPO/group).rglob('*'):
                if p.is_file() and p.suffix in ['.gml','.yy']:
                    dest=project/p.relative_to(s.REPO);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
        # Native libraries are replaced atomically by build-native.sh, so an old
        # hard-linked fixture can retain the prior inode. Refresh these as well.
        for p in (s.REPO/'extensions').rglob('*'):
            if p.is_file():
                dest=project/p.relative_to(s.REPO);dest.parent.mkdir(parents=True,exist_ok=True)
                if not dest.exists() or not os.path.samefile(p,dest):
                    dest.unlink(missing_ok=True);clone(p,dest)
        yypfile=project/'FVM-Reborn.yyp'
        yyp=s.read_yy(s.REPO/'FVM-Reborn.yyp')
        yyp['resources'] += [{'id':{'name':n,'path':f'{kind}/{n}/{n}.yy'}} for kind,n in [('objects','obj_coop_full_fixture'),('scripts','coop_full_fixture')]]
        s.write_yy(yypfile,yyp)
        p=project/'objects/obj_game_init/Other_2.gml';p.write_text(p.read_text()+'\ninstance_create_depth(0,0,-90000,obj_coop_full_fixture);\n')
        shutil.copyfile(HERE/'coop-full-fixture.gml',project/'scripts/coop_full_fixture/coop_full_fixture.gml')
    else:yypfile=prepare(root,appid)
    runtime,igor,user=s.toolchain(Path(os.environ.get('FVM_GAMEMAKER_RUNTIME','/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-'+s.VERSION)))
    for name in ['cache','temp','output','logs']:(root/name).mkdir(exist_ok=True)
    command=[igor,'-j=1','/uf='+str(user),'/lf='+str(user/'licence.plist'),'/rp='+str(runtime),'/project='+str(yypfile),'/cache='+str(root/'cache'),'/temp='+str(root/'temp'),'/runtime=VM','/of='+str(root/'output/test'),'--','Mac','Compile']
    if not args.reuse_compiled:s.command(command,root/'logs/compile.log',cwd=yypfile.parent,env=dict(os.environ,COMPlus_ZapDisable='1'),timeout=420)
    print('Packaging isolated host and guest applications from '+('existing' if args.reuse_compiled else 'newly compiled')+' game.zip.',flush=True)
    apps={}
    for role in ['host','guest']:
        prior=root/('FVM Co-op '+role+'.app')
        if prior.exists():shutil.move(prior,root/(prior.name+'.old-'+uuid.uuid4().hex[:6]))
        apps[role]=package(root,runtime,role,appid+'.'+role)
    server=None;tunnel=None;children=[];logs=[]
    data=root/('server-data-'+uuid.uuid4().hex[:8])
    for role in ['host','guest']:(root/'logs'/f'{role}.log').write_text('')
    try:
        server=subprocess.Popen([str(s.REPO/'server/.venv/bin/python'),str(s.REPO/'server/main.py'),'--data-dir',str(data),'--port','0','--backup-every','0','--auth-timeout','30'],stdout=subprocess.PIPE,stderr=(root/'logs/server.log').open('wb'))
        if not select.select([server.stdout],[],[],10)[0]:raise RuntimeError('Server did not start')
        port=json.loads(server.stdout.readline())['port'];url=f'ws://127.0.0.1:{port}/game'
        if args.tunnel:
            config=root/'test-quick-tunnel.yml';config.write_text('{}\n')
            tunnel_log=(root/'logs/tunnel.log').open('wb');logs.append(tunnel_log)
            tunnel=subprocess.Popen([str(args.cloudflared),'tunnel','--config',str(config),'--no-autoupdate','--url',f'http://127.0.0.1:{port}','--protocol','http2','--metrics','127.0.0.1:0','--management-diagnostics=false'],stdout=tunnel_log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+60;public=None
            while time.monotonic()<deadline:
                if tunnel.poll() is not None:raise RuntimeError('Temporary tunnel stopped; inspect tunnel.log')
                text=(root/'logs/tunnel.log').read_text(errors='replace')
                match=re.search(r'https://[a-z0-9-]+\.trycloudflare\.com',text)
                if match and 'Registered tunnel connection' in text:
                    public=match.group();break
                time.sleep(.5)
            if not public:raise RuntimeError('Temporary tunnel did not register')
            # Registration can precede public DNS by over a minute. Verify the
            # actual trusted WSS route, without authenticating or mutating state.
            deadline=time.monotonic()+180
            url=public.replace('https://','wss://')+'/game'
            probe_code='''import asyncio,sys
from websockets.asyncio.client import connect
async def probe():
    async with connect(sys.argv[1],ping_interval=None,open_timeout=8,close_timeout=2): pass
asyncio.run(probe())
'''
            while True:
                probe=subprocess.run([str(s.REPO/'server/.venv/bin/python'),'-c',probe_code,url],capture_output=True,text=True,timeout=20)
                (root/'logs/network-probe.log').write_text(probe.stdout+probe.stderr)
                if probe.returncode==0:break
                if time.monotonic()>=deadline:
                    detail=probe.stderr.strip().splitlines()[-1] if probe.stderr.strip() else 'Unknown handshake failure'
                    raise RuntimeError('Temporary public WSS endpoint did not become ready: '+detail)
                time.sleep(2)
            print('Temporary public WSS tunnel ready; using isolated test database.',flush=True)
        token=(data/'host-token').read_text().strip()
        def launch(role,secret):
            log=(root/'logs'/f'{role}.log').open('wb');logs.append(log)
            child=subprocess.Popen([str(apps[role]/'Contents/MacOS/Mac_Runner'),role,url,secret],cwd=root,stdout=log,stderr=subprocess.STDOUT)
            children.append(child);return child
        host=launch('host',token)
        print('Host started; waiting for texture/font loading and room invitation.',flush=True)
        deadline=time.monotonic()+440;invite=None
        while time.monotonic()<deadline:
            text=(root/'logs/host.log').read_text(errors='replace')
            match=re.search(r'^FVM_FULL_INVITE=(.+)$',text,re.M)
            if match:invite=match.group(1);break
            if host.poll() is not None:raise RuntimeError('Host exited before invitation; inspect host.log')
            time.sleep(.3)
        if not invite:raise RuntimeError('No invitation within deadline')
        launch('guest',invite)
        print('Guest started; waiting for the real shared battle and victory commit.',flush=True)
        deadline=time.monotonic()+450
        while any(p.poll() is None for p in children) and time.monotonic()<deadline:time.sleep(.5)
        reports=[];images=[]
        for role in ['host','guest']:
            text=(root/'logs'/f'{role}.log').read_text(errors='replace')
            matches=re.findall(r'^FVM_FULL_ASSERT=(\d) (.+)$',text,re.M)
            reports += [{'name':role+': '+n,'passed':ok=='1'} for ok,n in matches]
            reports.append({'name':role+': process completed','passed':f'FVM_FULL_DONE={role}' in text})
            for image in re.findall(r'^FVM_FULL_IMAGE=(.+)$',text,re.M):
                path=Path(image)
                if path.is_file():
                    target=root/(('wss-' if args.tunnel else 'ws-')+path.name);shutil.copyfile(path,target);images.append(str(target))
        db=sqlite3.connect(data/'coop.sqlite3')
        reports.append({'name':'one durable match result','passed':db.execute('select count(*) from match_results').fetchone()[0]==1})
        profiles=[json.loads(row[0]) for row in db.execute('select profile_json from profiles')]
        reports.append({'name':'both profiles persist the same completed campaign','passed':len(profiles)==2 and profiles[0]==profiles[1] and all('cookie_island' in p.get('completed_levels',[]) for p in profiles)})
        reports.append({'name':'both players have durable ordered placement commands','passed':db.execute("select count(distinct player_id) from commands where action='place_card'").fetchone()[0]==2})
        db.close()
        result={'transport':'wss' if args.tunnel else 'ws','passed':sum(t['passed'] for t in reports),'total':len(reports),'tests':reports,'images':images}
        (root/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        (root/('results-'+result['transport']+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
        if result['passed']!=result['total']:raise RuntimeError('Full co-op regression failed; inspect fixture logs')
    finally:
        for p in children:
            if p.poll() is None:p.terminate()
        if server and server.poll() is None:server.terminate()
        if tunnel and tunnel.poll() is None:tunnel.terminate()
        for p in children+([server] if server else [])+([tunnel] if tunnel else []):
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        for f in logs:f.close()
if __name__=='__main__':main()
