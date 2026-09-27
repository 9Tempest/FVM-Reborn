#!/usr/bin/env python3
"""Native game-canvas/JPEG/GUI roundtrip in an isolated sandbox; no user saves."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('screen_test_support', HERE/'test-autosave.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
s.NAME = 'FVM-Coop-Screen-Tests'

def prepare(root, app_id):
    project_file = s.prepare(root, app_id)
    project = project_file.parent
    yyp = s.read_yy(project_file)
    yyp['resources'] = []
    shutil.rmtree(project/'scripts')
    shutil.rmtree(project/'objects')
    parent = {'name':'Harness','path':'folders/Harness.yy'}
    def add(kind, name):
        path = project/kind/name/(name+'.yy')
        yyp['resources'].append({'id':{'name':name,'path':str(path.relative_to(project))}})
        return path
    for kind, names in (('scripts',['CoopScreen']),('extensions',['WindowsNative']),('sprites',['spr_craft_bg'])):
        for name in names:
            path = add(kind,name)
            shutil.copytree(s.REPO/kind/name,path.parent)
            meta = s.read_yy(path); meta['parent'] = parent
            if kind == 'sprites': meta['textureGroupId']={'name':'Default','path':'texturegroups/Default'}
            s.write_yy(path,meta)
    shutil.copyfile(root/'native/libFvmNativeSupport.dylib', project/'extensions/WindowsNative/libFvmNativeSupport.dylib')
    name='screen_fixture'; path=add('scripts',name)
    s.write_yy(path,{'$GMScript':'v1','%Name':name,'name':name,'parent':parent,'resourceType':'GMScript','resourceVersion':'2.0','isCompatibility':False,'isDnD':False})
    shutil.copyfile(HERE/'coop-screen-fixture.gml',path.with_suffix('.gml'))
    name='obj_autosave_tests'; path=add('objects',name)
    meta=s.read_yy(s.REPO/'objects/obj_coop_controller/obj_coop_controller.yy')
    meta.update({'%Name':name,'name':name,'persistent':True,'parent':parent})
    base=meta['eventList'][0]; meta['eventList']=[]
    for typ,num,code in [(0,0,'fixture_create();'),(3,0,'fixture_step();'),(8,0,'fixture_draw();'),(8,74,'coop_screen_gui_begin();'),(8,64,'fixture_gui();'),(8,75,'coop_screen_gui_end(); fixture_after_gui();')]:
        event=copy.deepcopy(base);event.update({'eventType':typ,'eventNum':num});meta['eventList'].append(event)
        path.parent.mkdir(parents=True,exist_ok=True)
        prefix={0:'Create',3:'Step',8:'Draw'}[typ]
        path.with_name(prefix+'_'+str(num)+'.gml').write_text(code+'\n')
    s.write_yy(path,meta)
    old=project/'rooms/room_autosave_tests/room_autosave_tests.yy'
    room=s.read_yy(old); room.update({'%Name':'room_menu','name':'room_menu'})
    room['roomSettings'].update({'Width':1920,'Height':1080})
    for item in room['instanceCreationOrder']: item['path']='rooms/room_menu/room_menu.yy'
    rpath=add('rooms','room_menu'); s.write_yy(rpath,room)
    lobby=copy.deepcopy(room);lobby.update({'%Name':'room_coop','name':'room_coop','instanceCreationOrder':[]})
    lobby['layers'][0]['instances']=[]
    s.write_yy(add('rooms','room_coop'),lobby)
    yyp['RoomOrderNodes']=[{'roomId':{'name':'room_menu','path':'rooms/room_menu/room_menu.yy'}}]
    s.write_yy(project_file,yyp)
    return project_file

def main():
    cache=Path.home()/'Library/Caches/FVM-Reborn/coop-screen-tests';cache.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='run-',dir=cache))
    app_id='io.github.9tempest.fvmreborn.screen-tests.'+uuid.uuid4().hex
    print('Game canvas fixture: '+str(root),flush=True)
    subprocess.run(['bash',str(s.REPO/'FvmNativeSupport/macos/build.sh'),str(root/'native')],check=True)
    project=prepare(root,app_id)
    runtime,igor,user=s.toolchain(Path(os.environ.get('FVM_GAMEMAKER_RUNTIME','/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-'+s.VERSION)))
    for part in ('cache','temp','output','logs'): (root/part).mkdir()
    args=[igor,'-j=1','/uf='+str(user),'/lf='+str(user/'licence.plist'),'/rp='+str(runtime),'/project='+str(project),'/cache='+str(root/'cache'),'/temp='+str(root/'temp'),'/runtime=VM','/of='+str(root/'output/test'),'--','Mac','Compile']
    s.command(args,root/'logs/compile.log',cwd=project.parent,env=dict(os.environ,COMPlus_ZapDisable='1'),timeout=240)
    app=root/(s.NAME+'.app');shutil.copytree(runtime/'mac/YoYo Runner.app',app,symlinks=True)
    contents=app/'Contents';resources=contents/'Resources'
    for name in ('yoyorunner.config','game.yydebug'): (resources/name).unlink(missing_ok=True)
    game=root/'output/assets/game.ios'
    if not game.is_file(): game=root/'output/game.ios'
    shutil.copyfile(game,resources/'game.ios')
    shutil.copyfile(root/'output/options.ini',resources/'options.ini')
    shutil.copyfile(root/'native/libFvmNativeSupport.dylib',resources/'libFvmNativeSupport.dylib')
    ip=contents/'Info.plist';info=plistlib.loads(ip.read_bytes());info.update({'CFBundleIdentifier':app_id,'CFBundleName':s.NAME,'CFBundleDisplayName':s.NAME,'LSMinimumSystemVersion':'13.0'});ip.write_bytes(plistlib.dumps(info))
    ent=root/'entitlements.plist';ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
    for lib in contents.rglob('*.dylib'): subprocess.run(['codesign','--force','--sign','-',str(lib)],check=True,capture_output=True)
    subprocess.run(['codesign','--force','--sign','-','--entitlements',str(ent),str(app)],check=True,capture_output=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    s.command([contents/'MacOS'/info['CFBundleExecutable']],root/'logs/run.log',cwd=root,timeout=45)
    text=(root/'logs/run.log').read_text(errors='replace');matches=re.findall(r'FVM_SCREEN_RESULT=(\{[^\r\n]+\})',text)
    if not matches: raise ValueError('No report: '+str(root/'logs/run.log'))
    report=json.loads(matches[-1]);s.write_yy(root/'results.json',report)
    print(str(report['passed'])+'/'+str(report['total'])+' passed; '+str(root/'results.json'))
    for test in report['tests']:
        if not test['passed']: print('FAIL: '+test['name'])
    return 0 if report['passed']==report['total'] else 1
if __name__=='__main__':sys.exit(main())
