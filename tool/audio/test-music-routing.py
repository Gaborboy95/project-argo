#!/usr/bin/python3
"""Check owned link lifetime on a private PipeWire server; no host audio changes."""
import os, tempfile, subprocess, json, time, pathlib
with tempfile.TemporaryDirectory(prefix='argo-private-pw-') as tmp:
    env=dict(os.environ, XDG_RUNTIME_DIR=tmp, PIPEWIRE_RUNTIME_DIR=tmp, PIPEWIRE_REMOTE='argo-private')
    cfg=pathlib.Path(tmp)/'private.conf'
    cfg.write_text('''context.properties = { core.daemon = true core.name = argo-private }
context.spa-libs = { support.* = support/libspa-support audio.convert.* = audioconvert/libspa-audioconvert audiotestsrc = audiotestsrc/libspa-audiotestsrc }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-access }
 { name = libpipewire-module-metadata }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
]
context.objects = [
 { factory = adapter args = { factory.name = audiotestsrc node.name = source media.class = Audio/Source audio.position = [ FL FR ] adapter.auto-port-config = { mode = dsp monitor = true position = preserve } } }
 { factory = adapter args = { factory.name = support.null-audio-sink node.name = target media.class = Audio/Sink audio.position = [ FL FR ] adapter.auto-port-config = { mode = dsp monitor = true position = preserve } } }
]
''')
    log=open(pathlib.Path(tmp)/'log','w+')
    server=subprocess.Popen(['pipewire','-c',str(cfg)],env=env,stdout=log,stderr=log)
    link=None
    try:
        time.sleep(.4)
        def graph():
            return json.loads(subprocess.check_output(['pw-dump'],env=env,timeout=3))
        g=graph()
        ports=[n for n in g if n['type']=='PipeWire:Interface:Port']
        print('Private server ports:',[(n['id'], n['info']['props'].get('port.name')) for n in ports])
        nodes={n['info']['props'].get('node.name'):n['id'] for n in g if n['type']=='PipeWire:Interface:Node'}
        def port(node,direction):
            return next(p['id'] for p in ports if p['info']['props']['node.id']==nodes[node] and p['info']['props']['port.direction']==direction)
        source,target=port('source','out'),port('target','in')
        link=subprocess.Popen(['setpriv','--pdeathsig','TERM','pw-link','-m','-p','{"argo.music.owner":"private-test"}',str(source),str(target)],env=env,stdout=subprocess.DEVNULL,stderr=log)
        time.sleep(.4)
        links=[n for n in graph() if n['type']=='PipeWire:Interface:Link']
        print('Private link state:',[(n['info'].get('state'),n['info'].get('props',{}).get('argo.music.owner')) for n in links])
        assert len(links)==1 and links[0]['info']['props']['argo.music.owner']=='private-test'
        assert links[0]['info']['state'] == 'active'
        link.terminate();link.wait(timeout=3)
        time.sleep(.2)
        assert not [n for n in graph() if n['type']=='PipeWire:Interface:Link']
        print('Non-lingering client cleanup verified; host PipeWire was not used.')
    finally:
        if link and link.poll() is None: link.kill();link.wait()
        server.terminate();server.wait(timeout=3)
        log.seek(0)
        text=log.read()
        if text: print(text[:1200])
