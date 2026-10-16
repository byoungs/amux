import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import fcntl
import pty
import select
import shlex
import struct
import termios
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import names as w
import labels


class NamingIntegration(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='amux-names-test-')
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {'AMUX_HOME': str(self.root / 'state'), 'AMUX_TMUX_SOCKET': 'amux-names-' + uuid.uuid4().hex, 'AMUX_CLI': str(Path(__file__).resolve().parents[3] / 'app/.build/debug/amux-cli')})
        self.env.start()
        self.home = patch.object(w, 'HOME', self.root / 'state'); self.home.start()
        w.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-c', str(self.root), '/bin/zsh -f')
        w.tmux('set-option', '-g', 'default-shell', '/bin/zsh')
        w.tmux('set-option', '-t', 'test', '@amux-managed', '1')

    def tearDown(self):
        w.tmux('kill-server', check=False)
        self.home.stop(); self.env.stop(); self.tmp.cleanup()

    def test_unicode_override_survives_focus_and_reset(self):
        p = w.ensure_inventory()[0]
        identity = p['name_id']
        with w.state() as d:
            d['work'][identity]['agent_title'] = 'Generated title'
        w.rename_work(identity, 'Release 日本語 $(touch nope)')
        subprocess.run([os.environ['AMUX_CLI'], 'update-title', '0', str(self.root)], env={**os.environ, 'AMUX_SESSION': 'test'}, check=True, capture_output=True)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', p['pane'], '@amux-title'), 'Release 日本語 $(touch nope)')
        self.assertFalse((self.root / 'nope').exists())
        w.rename_work(identity, None)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', p['pane'], '@amux-title'), self.root.name)

    def test_long_manual_names_truncate_and_cached_chat_titles_are_ignored(self):
        pane = w.ensure_inventory()[0]
        identity = pane['name_id']
        inherited = '界' * 81
        with w.state() as data:
            data['work'][identity]['agent_title'] = inherited
        w.rename_work(identity, 'm' * 200)
        self.assertEqual(w.cached_entries()['work'][identity]['override'], 'm' * 80)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'm' * 80)
        w.rename_work(identity, None)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), self.root.name)
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'test')
        self.assertEqual(labels.clean('x' * 80), 'x' * 80)

    def test_created_space_keeps_its_name_through_pane_changes(self):
        w.tmux('new-session', '-d', '-s', 'local-mac', '-c', str(self.root), '/bin/zsh -f')
        w.tmux('set-option', '-t', 'local-mac', '@amux-managed', '1')
        w.sync_local()
        pane = next(p for p in w.panes() if p['space'] == 'local-mac')
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'local-mac', '@amux-space-title'), 'local-mac')
        w.rename_work(pane['name_id'], 'Build logs')
        w.sync_local(); w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'local-mac', '@amux-space-title'), 'local-mac')
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'Build logs')

    def test_local_project_branch_and_override_survive_restored_pane(self):
        repo = self.root / 'project'
        repo.mkdir()
        subprocess.run(['git', 'init', '-b', 'main', str(repo)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                        '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'initial'],
                       check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), 'checkout', '-b', 'feature/names'], check=True, capture_output=True)
        nested = repo / 'src'; nested.mkdir()
        pane = w.ensure_inventory()[0]
        w.tmux('respawn-pane', '-k', '-t', pane['pane'], '-c', str(nested), '/bin/zsh -f')
        w.sync_local()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'),
                         'project/feature/names')
        w.rename_work(pane['name_id'], 'Local investigation')
        # Simulate a server restart with its durable naming ID restored by amux.
        w.tmux('kill-server')
        w.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-c', str(nested), '/bin/zsh -f')
        w.tmux('set-option', '-t', 'test', '@amux-managed', '1')
        w.tmux('set-option', '-p', '-t', 'test:0.0', '@amux-names', pane['name_id'])
        w.sync_local()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', 'test:0.0', '@amux-title'), 'Local investigation')
        w.rename_work(pane['name_id'], None)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', 'test:0.0', '@amux-title'), 'project/feature/names')

    def test_explicit_space_rename_does_not_rename_panes(self):
        pane = w.ensure_inventory()[0]
        w.rename_work(pane['name_id'], 'My terminal')
        w.rename_space('test', 'Local Mac')
        w.sync_local(); w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'Local Mac')
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'My terminal')
        w.rename_space('test', '界' * 100)
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), '界' * 80)
        w.rename_space('test', None)
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'test')

    def test_space_and_pane_rename_popups_are_independent(self):
        pane = w.ensure_inventory()[0]
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        env = {**os.environ, 'TERM': 'xterm-256color', 'AMUX_SESSION': 'test'}
        env.pop('TMUX', None)
        base = ['tmux', '-L', os.environ['AMUX_TMUX_SOCKET']]
        client = subprocess.Popen(base + ['attach-session', '-t', 'test'],
                                  stdin=slave, stdout=slave, stderr=slave, env=env)
        popup = None
        def read_until(expected):
            data = b''
            deadline = time.monotonic() + 5
            while expected not in data and time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    data += os.read(master, 65536)
            self.assertIn(expected, data)
        def rename(mode, heading, keys):
            nonlocal popup
            cmd = shlex.join(['env', 'AMUX_SESSION=test', sys.executable, str(w.SELF), mode])
            popup = subprocess.Popen(base + ['display-popup', '-t', 'test', '-E', '-w', '80%', '-h', '10', cmd],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            read_until(heading)
            os.write(master, keys)
            popup.communicate(timeout=5)
            self.assertEqual(popup.returncode, 0)
            w.sync_local()
        try:
            read_until(b'test')
            rename('rename-space', b'Rename space', b'local-mac\r')
            self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'local-mac')
            self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), self.root.name)
            rename('rename', b'Rename local pane', b'Build logs\r')
            self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'Build logs')
            self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'local-mac')
            rename('rename-space', b'Rename space', b'\x1b')
            self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'local-mac')
            rename('rename-space', b'Rename space', b'\x15\r')
            self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'test')
        finally:
            w.tmux('kill-server', check=False)
            if popup and popup.poll() is None:
                popup.terminate(); popup.communicate(timeout=5)
            # The PTY can fill with final redraws while assertions run; do not
            # wait for the client to flush output after killing the test server.
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
            os.close(master); os.close(slave)

    def test_provider_subprocess_and_missing_provider_keep_state(self):
        provider = self.root / 'provider.py'
        provider.write_text('import sys,json\nr=json.load(sys.stdin)\nprint(json.dumps({"version":1,"id":r["id"],"result":{"sessions":[],"locations":[]}}))\n')
        w.atomic(w.HOME / 'providers.json', {'providers': [{'id': 'test', 'command': [sys.executable, str(provider)]}]})
        w.ensure_inventory(); w.sync_remote()
        self.assertIn('snapshot', w.cached_entries()['providers']['test'])
        provider.unlink(); w.sync_remote()
        data = w.cached_entries()
        self.assertIn('snapshot', data['providers']['test'])
        self.assertIn('error', data['providers']['test'])
        self.assertEqual(len(data['work']), 1)

    def test_cli_dispatch_locates_companion(self):
        result = subprocess.run([os.environ['AMUX_CLI'], 'names', 'inspect'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['version'], 1)


    def test_rename_preserves_copy_mode_and_history(self):
        p = w.ensure_inventory()[0]
        w.tmux('respawn-pane', '-k', '-t', p['pane'], "/bin/sh -c 'seq 1 200; exec /bin/sh'")
        import time
        time.sleep(.15)
        w.tmux('copy-mode', '-u', '-t', p['pane'])
        before = w.tmux('display-message', '-p', '-t', p['pane'], '#{pane_in_mode}:#{scroll_position}:#{history_size}')
        w.rename_work(p['name_id'], 'Changed while scrolling')
        w.sync_local()
        after = w.tmux('display-message', '-p', '-t', p['pane'], '#{pane_in_mode}:#{scroll_position}:#{history_size}')
        self.assertTrue(before.startswith('1:'))
        self.assertEqual(after, before)


    def test_exiting_a_named_terminal_closes_its_pane(self):
        import time
        pane = w.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'test', '/bin/sh')
        identity = next(p['name_id'] for p in w.ensure_inventory() if p['pane'] == pane)
        w.rename_work(identity, 'Temporary terminal')
        w.sync_local()
        self.assertEqual(w.tmux('show-options', '-p', '-A', '-v', '-t', pane, 'remain-on-exit'), 'off')
        w.tmux('send-keys', '-t', pane, 'exit', 'Enter')
        deadline = time.monotonic() + 5
        while any(p['pane'] == pane for p in w.panes()) and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertFalse(any(p['pane'] == pane for p in w.panes()))
        self.assertEqual(len(w.panes()), 1)

    def test_binding_roundtrip_preserves_terminal_and_unbinds(self):
        # A generic subprocess provider: amux never depends on a provider's implementation.
        backend = self.root / 'backend.json'
        item = {'ref': 'immutable', 'selector': 'routing-hint', 'state': 'attached', 'revision': 0, 'override': None, 'agent_title': 'Whole prompt should never become a name', 'name': 'session-name', 'display_name': 'session-name', 'location': 'prod / eu1', 'location_name': 'eu1'}
        backend.write_text(json.dumps(item))
        provider = self.root / 'provider.py'
        provider.write_text('''import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());r=json.load(sys.stdin)
if r['method']=='rename':
 s.update(override=r['params']['override'],revision=s['revision']+1)
 s['display_name']=s['override'] or s['name'];p.write_text(json.dumps(s));v=s
else: v={'sessions':[s]}
print(json.dumps({'version':1,'id':r['id'],'result':v}))
''')
        w.atomic(w.HOME / 'providers.json', {'providers': [{'id': 'generic', 'command': [sys.executable, str(provider), str(backend)]}]})
        pane = w.ensure_inventory()[0]
        before = w.tmux('list-panes', '-t', 'test', '-F', '#{pane_id}:#{pane_pid}:#{pane_start_command}')
        with patch.dict(os.environ, {'TMUX_PANE': pane['pane']}):
            w.bind_provider('generic', 'routing-hint', os.getpid())
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'session-name — eu1')
        self.assertEqual(w.effective(w.cached_entries()['work'][pane['name_id']]), 'session-name')
        w.rename_work(pane['name_id'], 'Shared name')
        self.assertEqual(json.loads(backend.read_text())['override'], 'Shared name')
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'Shared name — eu1')
        self.assertEqual(w.tmux('show-options', '-v', '-t', 'test', '@amux-space-title'), 'test')
        value = json.loads(backend.read_text());value.update(override='Renamed externally',revision=2)
        backend.write_text(json.dumps(value));w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'Renamed externally — eu1')
        w.rename_work(pane['name_id'], '界' * 100)
        self.assertEqual(json.loads(backend.read_text())['override'], '界' * 80)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), '界' * 73 + '… — eu1')
        w.rename_work(pane['name_id'], None)
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'session-name — eu1')
        # Providers may change or omit location metadata; never retain a stale suffix.
        value = json.loads(backend.read_text());value.pop('location_name')
        backend.write_text(json.dumps(value));w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'session-name — prod / eu1')
        value.pop('location')
        backend.write_text(json.dumps(value));w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'session-name')
        value['location_name'] = 'us2'
        backend.write_text(json.dumps(value));w.sync_remote()
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'session-name — us2')
        w.unbind_provider(os.getpid());w.render_titles()
        self.assertEqual(w.cached_entries()['work'][pane['name_id']]['provider'], 'local')
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), self.root.name)
        self.assertEqual(w.tmux('list-panes', '-t', 'test', '-F', '#{pane_id}:#{pane_pid}:#{pane_start_command}'), before)

    def test_long_location_leaves_room_for_session_name(self):
        pane = w.ensure_inventory()[0]
        with w.state() as data:
            data['work'][pane['name_id']].update(provider='generic', display_name='s' * 80,
                                                location_name='b' * 100)
        w.render_titles()
        title = w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title')
        self.assertEqual(title, 's' * 36 + '… — ' + 'b' * 39 + '…')
        self.assertEqual(len(title), 80)

    def test_pending_binding_keeps_names_through_missing_identity_and_refresh(self):
        pane = w.ensure_inventory()[0]
        snapshot = {'sessions': [], 'bindings': [{
            'selector': 'new-session', 'display_name': 'Session', 'location_name': 'Remote',
        }]}
        with patch.object(w, 'config', return_value={'providers': [{'id': 'generic'}]}), \
             patch.object(w, 'provider', return_value=snapshot), \
             patch.dict(os.environ, {'TMUX_PANE': pane['pane']}):
            w.bind_provider('generic', 'new-session', os.getpid())
            def title():
                return w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title')
            self.assertEqual(title(), 'Session — Remote')

            self.assertIsNone(w.cached_entries()['work'][pane['name_id']].get('ref'))
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                w.rename_work(pane['name_id'], 'Too early')
            # Existing stuck bindings are repaired by the next cached snapshot.
            with w.state() as data:
                work = data['work'][pane['name_id']]
                work.pop('display_name', None); work.pop('location_name', None)
                work['fallback'] = 'Connecting…'
            w.sync_remote()
            self.assertEqual(title(), 'Session — Remote')
            with patch.object(w, 'provider', side_effect=RuntimeError('offline')):
                w.sync_remote()
                w.bind_provider('generic', 'new-session', os.getpid())
            self.assertEqual(title(), 'Session — Remote')
            # Resolving later freezes the immutable identity as before.
            snapshot['sessions'] = [{**snapshot['bindings'][0], 'ref': 'original',
                                     'state': 'attached', 'display_name': 'Renamed'}]
            w.sync_remote()
            self.assertEqual(title(), 'Renamed — Remote')
            snapshot['sessions'][0].update(ref='replacement', display_name='Wrong session')
            snapshot['bindings'][0]['display_name'] = 'Wrong session'
            w.sync_remote()
            self.assertEqual(title(), 'Renamed — Remote')
            w.unbind_provider(os.getpid()); w.render_titles()
            self.assertEqual(title(), self.root.name)

    def test_rename_resolves_pending_identity_before_saving(self):
        pane = w.ensure_inventory()[0]
        snapshot = {'sessions': [], 'bindings': [{'selector': 'uat-session', 'display_name': 'Original'}]}
        calls = []
        def provider(pid, method, params=None, request_id=None):
            calls.append((method, params))
            if method == 'refresh':
                snapshot['sessions'] = [{'selector': 'uat-session', 'ref': 'verified',
                                         'state': 'attached', 'revision': 0, 'display_name': 'Original'}]
            elif method == 'rename':
                snapshot['sessions'][0].update(override=params['override'], display_name=params['override'], revision=1)
                return snapshot['sessions'][0]
            return snapshot
        with patch.object(w, 'config', return_value={'providers': [
                {'id': 'generic', 'refresh_params': {'environments': ['prod']}}]}), \
             patch.object(w, 'provider', side_effect=provider), \
             patch.dict(os.environ, {'TMUX_PANE': pane['pane']}):
            w.bind_provider('generic', 'uat-session', os.getpid())
            w.rename_work(pane['name_id'], 'New title')
        self.assertIn(('refresh', {'environments': ['prod'], 'selector': 'uat-session'}), calls)
        rename = next(params for method, params in calls if method == 'rename')
        self.assertEqual(rename['ref'], 'verified')
        self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'New title')

    def test_pending_rename_rejects_ambiguous_or_rebound_session(self):
        for outcome in ('ambiguous', 'rebound'):
            with self.subTest(outcome=outcome):
                pane = w.ensure_inventory()[0]
                with w.state() as data:
                    data['work'][pane['name_id']].update(provider='generic', selector='pending', ref=None,
                                                       owner={'pid': os.getpid(), 'stamp': 'original'})
                methods = []
                def provider(pid, method, params=None, request_id=None):
                    methods.append(method)
                    session = {'selector': 'pending', 'ref': 'original', 'state': 'attached', 'revision': 0}
                    if outcome == 'ambiguous':
                        return {'sessions': [session, {**session, 'ref': 'replacement'}]}
                    with w.state() as data:
                        data['work'][pane['name_id']]['owner']['stamp'] = 'new connection'
                    return {'sessions': [session]}
                with patch.object(w, 'config', return_value={'providers': [{'id': 'generic'}]}), \
                     patch.object(w, 'provider', side_effect=provider):
                    with self.assertRaisesRegex(RuntimeError, 'identity|connection changed'):
                        w.rename_work(pane['name_id'], 'Do not apply')
                self.assertNotIn('rename', methods)

    def test_rename_popup_retains_name_and_retries_after_provider_error(self):
        pane = w.ensure_inventory()[0]
        backend = self.root / 'backend.json'
        backend.write_text(json.dumps({'attempts': 0, 'override': None, 'resolved': False}))
        provider = self.root / 'provider.py'
        provider.write_text('''import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());r=json.load(sys.stdin)
item={'ref':'verified','selector':'pending','state':'attached','revision':0,'display_name':s['override'] or 'Original','override':s['override']}
response={'version':1,'id':r['id']}
if r['method']=='refresh':
 assert r['params']['selector']=='pending'
 s['resolved']=True
if r['method']=='rename':
 assert r['params']['ref']=='verified'
 s['attempts']+=1
 if s['attempts']==1: response['error']={'code':'offline','message':'Temporary test failure'}
 else:
  s['override']=r['params']['override'];item.update(override=s['override'],display_name=s['override'])
  response['result']=item
else: response['result']={'sessions':[item] if s['resolved'] else []}
p.write_text(json.dumps(s));print(json.dumps(response))
''')
        w.atomic(w.HOME / 'providers.json', {'providers': [{'id': 'generic',
            'command': [sys.executable, str(provider), str(backend)]}]})
        with patch.dict(os.environ, {'TMUX_PANE': pane['pane']}):
            w.bind_provider('generic', 'pending', os.getpid())
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        env = {**os.environ, 'TERM': 'xterm-256color', 'AMUX_SESSION': 'test'}
        env.pop('TMUX', None)
        base = ['tmux', '-L', os.environ['AMUX_TMUX_SOCKET']]
        client = subprocess.Popen(base + ['attach-session', '-t', 'test'],
                                  stdin=slave, stdout=slave, stderr=slave, env=env)
        popup = None
        def read_until(expected):
            data = b''; deadline = time.monotonic() + 8
            while expected not in data and time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    data += os.read(master, 65536)
            self.assertIn(expected, data)
        try:
            read_until(b'test')
            cmd = shlex.join(['env', 'AMUX_SESSION=test', sys.executable, str(w.SELF), 'rename'])
            popup = subprocess.Popen(base + ['display-popup', '-t', 'test', '-E', '-w', '80%', '-h', '10', cmd],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            read_until(b'Rename session')
            os.write(master, b'Keep my title\r')
            read_until(b'Temporary test failure')
            self.assertIsNone(popup.poll(), 'Error must keep the editable prompt open')
            self.assertIsNone(json.loads(backend.read_text())['override'])
            os.write(master, b'\r')
            popup.communicate(timeout=8)
            self.assertEqual(popup.returncode, 0)
            self.assertEqual(json.loads(backend.read_text())['override'], 'Keep my title')
            self.assertEqual(w.tmux('show-options', '-p', '-v', '-t', pane['pane'], '@amux-title'), 'Keep my title')
        finally:
            w.tmux('kill-server', check=False)
            if popup and popup.poll() is None:
                popup.terminate(); popup.communicate(timeout=5)
            client.terminate()
            try: client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill(); client.wait(timeout=5)
            os.close(master); os.close(slave)

if __name__ == '__main__':
    unittest.main()
