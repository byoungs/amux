#!/usr/bin/env python3
"""amux naming companion (stdlib only).

State is local, locked and atomic. Provider executables are explicitly configured
in AMUX_HOME/providers.json. Network work never runs in a focus/zoom hook.
"""
from contextlib import contextmanager
import curses
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
sys.dont_write_bytecode = True
import labels

HOME = Path(os.environ.get('AMUX_HOME', str(Path.home() / '.amux')))
SELF = Path(__file__).resolve()


def run(argv, **kw):
    return subprocess.run(argv, text=True, capture_output=True, timeout=kw.pop('timeout', 15), **kw)

def tmux(*args, check=True):
    cmd = [shutil.which('tmux') or '/opt/homebrew/bin/tmux']
    if os.environ.get('AMUX_TMUX_SOCKET'):
        cmd += ['-L', os.environ['AMUX_TMUX_SOCKET']]
    elif os.environ.get('TMUX'):
        cmd += ['-S', os.environ['TMUX'].rsplit(',', 2)[0]]
    p = run(cmd + list(args))
    if check and p.returncode:
        raise RuntimeError(p.stderr.strip() or 'tmux failed')
    return p.stdout.rstrip('\n')

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.names-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

@contextmanager
def state():
    HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (HOME / 'names.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = HOME / 'names.json'
        value = json.loads(path.read_text()) if path.exists() else {'version': 1, 'work': {}, 'spaces': {}, 'providers': {}}
        yield value
        atomic(path, value)

def config():
    path = HOME / 'providers.json'
    result = json.loads(path.read_text()) if path.exists() else {'providers': []}
    for p in result['providers']:
        if not isinstance(p.get('command'), list) or not p['command'] or not all(isinstance(x, str) for x in p['command']):
            raise RuntimeError('Provider command must be an argv array')
    return result

def provider(pid, method, params=None, request_id=None):
    p = next((p for p in config()['providers'] if p['id'] == pid), None)
    if not p:
        raise RuntimeError('Provider is unavailable: ' + pid)
    request_id = request_id or str(uuid.uuid4())
    req = {'version': 1, 'id': request_id, 'method': method, 'params': params or {}}
    result = run(p['command'], input=json.dumps(req), timeout=120 if method == 'refresh' else 20)
    if result.returncode:
        raise RuntimeError('Provider exited: ' + result.stderr[-400:])
    response = json.loads(result.stdout)
    if response.get('version') != 1 or response.get('id') != request_id:
        raise RuntimeError('Invalid provider response')
    if 'error' in response:
        raise RuntimeError(response['error']['message'])
    return response['result']

def command(*args):
    return shlex.join([sys.executable, str(SELF), *args])

def panes():
    fmt = '#{pane_id}\t#{session_name}\t#{pane_current_path}\t#{@amux-names}\t#{pane_pid}\t#{@amux-managed}\t#{pane_dead}\tEND'
    rows = tmux('list-panes', '-a', '-F', fmt, check=False)
    out = []
    for line in rows.splitlines():
        f = line.split('\t')
        if len(f) == 8 and f[5] == '1':
            out.append(dict(zip(('pane', 'space', 'cwd', 'name_id', 'pid', 'managed', 'dead'), f[:7])))
    return out

def effective(work):
    fallback = work.get('fallback')
    if work.get('provider') != 'local' and fallback in ('Connecting…', 'Connecting...'):
        fallback = None  # migrate the obsolete connection-status placeholder
    return labels.clean(work.get('override') or (work.get('display_name') if work.get('provider') != 'local' else None) or fallback or Path(work.get('cwd') or '').name or 'Terminal') or 'Terminal'

def pane_title(work):
    """Location is presentation only; shared names and rename input stay plain."""
    name = effective(work)
    location = labels.clean(work.get('location_name') or work.get('location') or '')
    if work.get('provider') == 'local' or not location:
        return name
    # Keep both parts visible even if a provider supplies an oversized location.
    location_limit = labels.MAX_NAME_LENGTH // 2
    if len(location) > location_limit:
        location = location[:location_limit - 1] + '…'
    suffix = ' — ' + location
    name_limit = labels.MAX_NAME_LENGTH - len(suffix)
    if len(name) > name_limit:
        name = name[:name_limit - 1] + '…'
    return name + suffix

def auto_title(cwd):
    """Use local Git metadata only; naming never needs network access."""
    fallback = Path(cwd).name or 'Terminal'
    try:
        result = run(['git', '-C', cwd, 'rev-parse', '--show-toplevel', '--abbrev-ref', 'HEAD'], timeout=1)
        lines = result.stdout.splitlines()
        if result.returncode == 0 and len(lines) == 2:
            project, branch = Path(lines[0]).name, lines[1]
            return project + ('/' + branch if branch not in ('main', 'master', 'HEAD') else '')
    except (OSError, subprocess.TimeoutExpired):
        pass
    return fallback

def ensure_inventory():
    observed = panes()
    # Compute once per directory outside the state lock, even with many tiles.
    titles = {cwd: auto_title(cwd) for cwd in {p['cwd'] for p in observed}}
    with state() as data:
        for p in observed:
            identity = p['name_id'] or str(uuid.uuid4())
            if not p['name_id']:
                tmux('set-option', '-p', '-t', p['pane'], '@amux-names', identity)
                p['name_id'] = identity
            if identity not in data['work']:
                data['work'][identity] = {'id': identity, 'provider': 'local', 'cwd': p['cwd'], 'fallback': titles[p['cwd']], 'revision': 0}
            work = data['work'][identity]
            work.update(pane=p['pane'], space=p['space'])
            if work['provider'] == 'local':
                work['cwd'] = p['cwd']
                work['fallback'] = titles[p['cwd']]
            space = data['spaces'].setdefault(p['space'], {'id': str(uuid.uuid4())})
            # Space names belong to the space, never to its first/current pane.
            space.pop('primary', None)  # migrate the old inherited-title model
        return observed

def render_titles():
    observed = panes()
    with state() as data:
        for p in observed:
            w = data['work'].get(p['name_id'])
            if not w:
                continue
            title = pane_title(w)
            if tmux('show-options', '-p', '-v', '-t', p['pane'], '@amux-title', check=False) != title:
                tmux('set-option', '-p', '-t', p['pane'], '@amux-title', title)
        for name, space in data['spaces'].items():
            title = space.get('override') or name
            title = labels.clean(title) or 'Terminal'
            space['display_name'] = title
            if tmux('show-options', '-v', '-t', name + ':', '@amux-space-title', check=False) != title:
                tmux('set-option', '-t', name + ':', '@amux-space-title', title, check=False)

def process_table():
    result = run(['ps', '-axo', 'pid=,ppid=,lstart=,comm='])
    table = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 7)
        if len(parts) == 8:
            table[int(parts[0])] = {'parent': int(parts[1]), 'stamp': ' '.join(parts[2:7]), 'command': parts[7]}
    return table






def sync_local():
    ensure_inventory()
    render_titles()

def sync_remote(refresh=False, *, provider_id=None, selector=None):
    for p in config()['providers']:
        if provider_id is not None and p['id'] != provider_id:
            continue
        try:
            with state() as data:
                bound = any(w['provider'] == p['id'] for w in data['work'].values())
            params = dict(p.get('refresh_params', {}))
            if selector is not None:
                params['selector'] = selector
            result = provider(p['id'], 'refresh' if refresh and bound else 'snapshot', params)
            with state() as data:
                data['providers'][p['id']] = {'snapshot': result, 'checked_at': time.time()}
                by_ref = {s['ref']: s for s in result.get('sessions', [])}
                for w in data['work'].values():
                    if w['provider'] != p['id']:
                        continue
                    current = by_ref.get(w.get('ref'))
                    if not w.get('ref') and w.get('selector'):
                        matches = [s for s in by_ref.values() if s.get('selector') == w['selector'] and s.get('state') in ('attached', 'detached')]
                        current = matches[0] if len(matches) == 1 else None
                        if current:
                            w['ref'] = current['ref']  # freeze identity; never follow name reuse
                    if current:
                        for field in ('display_name', 'override', 'revision', 'state', 'location', 'location_name'):
                            w[field] = current.get(field)
                    elif not w.get('ref'):
                        # Presentation hints do not establish identity or grant
                        # rename access. Never follow them after freezing a ref.
                        hints = [b for b in result.get('bindings', []) if b.get('selector') == w.get('selector')]
                        if hints and all(b == hints[0] for b in hints):
                            for field in ('display_name', 'location', 'location_name'):
                                w[field] = hints[0].get(field)
        except Exception as exc:
            with state() as data:
                data['providers'].setdefault(p['id'], {})['error'] = str(exc)
            if provider_id is not None:
                raise  # Explicit rename must show why its refresh failed.
    render_titles()


def rename_work(identity, value):
    value = labels.clean(value) if value else None
    with state() as data:
        work = data['work'][identity].copy()
    if work['provider'] != 'local':
        if not work.get('ref') and work.get('selector'):
            sync_remote(True, provider_id=work['provider'], selector=work['selector'])
            with state() as data:
                refreshed = data['work'][identity].copy()
            if any(refreshed.get(key) != work.get(key) for key in ('provider', 'selector', 'owner')):
                raise RuntimeError('The pane connection changed; reopen Rename for the current session')
            work = refreshed
        if not work.get('ref'):
            raise RuntimeError('Waiting for the connected session identity; try again shortly')
        result = provider(work['provider'], 'rename', {'ref': work['ref'], 'expected_revision': work.get('revision', 0), 'override': value})
    else:
        result = {'override': value, 'revision': work.get('revision', 0) + 1}
    with state() as data:
        data['work'][identity].update(result)
    if work['provider'] != 'local':
        sync_remote()
    render_titles()


def rename_space(name, value):
    if name not in {p['space'] for p in ensure_inventory()}:
        raise RuntimeError('That space is no longer available')
    with state() as data:
        data['spaces'][name]['override'] = labels.clean(value) if value else None
    render_titles()

def selected_work():
    ensure_inventory()
    pane = tmux('display-message', '-p', '-t', os.environ.get('AMUX_SESSION', 'amux'), '#{pane_id}')
    return next((p['name_id'] for p in panes() if p['pane'] == pane), None)

def read_key(screen):
    try:
        return screen.get_wch()
    except curses.error:
        return None

def prompt(screen, label, default='', error=''):
    screen.erase()
    screen.addnstr(1, 2, label, max(1, screen.getmaxyx()[1] - 4))
    screen.addnstr(3, 2, 'Type to replace; Enter saves; Esc cancels; Ctrl-U clears', max(1, screen.getmaxyx()[1] - 4))
    if error:
        screen.addnstr(7, 2, 'Could not save: ' + error, max(1, screen.getmaxyx()[1] - 4))
    value = default
    selected = bool(default)
    while True:
        screen.move(5, 2)
        screen.clrtoeol()
        screen.addnstr(5, 2, value, max(1, screen.getmaxyx()[1] - 4), curses.A_REVERSE if selected else curses.A_NORMAL)
        screen.refresh()
        key = read_key(screen)
        if key in ('\n', '\r'):
            return value
        if key == '\x1b':
            return None
        if key == '\x01':  # Ctrl-A / Cmd-A selects the current name.
            selected = True
            continue
        if key == '\x15':
            value = ''; selected = False
            continue
        if key in ('\x7f', '\b', curses.KEY_BACKSPACE):
            value = '' if selected else value[:-1]
            selected = False
        elif isinstance(key, str) and key.isprintable():
            value = (( '' if selected else value) + key)[:80]
            selected = False

def cached_entries():
    with state() as data:
        return json.loads(json.dumps(data))


def bind_provider(pid, selector, owner_pid):
    observed = ensure_inventory()
    pane = os.environ.get('TMUX_PANE')
    selected = next((p for p in observed if p['pane'] == pane), None)
    if not selected:
        return  # providers running outside amux, and other tmux sessions, remain untouched
    if not any(p['id'] == pid for p in config()['providers']):
        return
    owner = process_table().get(owner_pid)
    if not owner:
        return
    with state() as data:
        work = data['work'][selected['name_id']]
        local = work.get('local_name') or {k: v for k, v in work.items() if k not in ('pane', 'space')}
        same_binding = (work.get('provider') == pid and work.get('selector') == selector
                        and work.get('owner') == {'pid': owner_pid, 'stamp': owner['stamp']})
        previous = work.copy() if same_binding else {}
        work.clear()
        work.update(id=selected['name_id'], provider=pid, selector=selector,
                    owner={'pid': owner_pid, 'stamp': owner['stamp']}, local_name=local,
                    fallback=effective(local), pane=pane, space=selected['space'])
        # A repeated bind during reconnect must not erase a known name when the
        # provider is temporarily unavailable. A different selector starts fresh.
        for field in ('ref', 'display_name', 'override', 'revision', 'state', 'location', 'location_name'):
            if field in previous:
                work[field] = previous[field]
    sync_remote()


def unbind_provider(owner_pid=None):
    table = process_table()
    with state() as data:
        for work in data['work'].values():
            owner = work.get('owner')
            if not owner:
                continue
            expired = table.get(owner['pid'], {}).get('stamp') != owner['stamp']
            if expired or owner_pid == owner['pid']:
                identity, pane, space = work['id'], work.get('pane'), work.get('space')
                saved = work.get('local_name', {})
                work.clear()
                work.update(saved, id=identity, provider='local', pane=pane, space=space)


def rename_ui(screen, scope='pane'):
    if scope == 'space':
        ensure_inventory()
        name = os.environ.get('AMUX_SESSION', 'amux')
        space = cached_entries()['spaces'].get(name, {})
        label = 'Rename space (max 80 characters; empty resets name)'
        default = space.get('override') or name
        save = lambda value: rename_space(name, value)
    else:
        identity = selected_work()
        if not identity:
            raise RuntimeError('No active pane to rename')
        sync_remote()
        work = cached_entries()['work'][identity]
        label = ('Rename local pane' if work['provider'] == 'local'
                 else 'Rename session (shared with ' + work['provider'] + ')')
        default = work.get('override') or effective(work)
        save = lambda value: rename_work(identity, value)
    error = ''
    while True:
        value = prompt(screen, label, default, error)
        if value is None:
            return
        try:
            screen.move(7, 2)
            screen.clrtoeol()
            screen.addnstr(7, 2, 'Saving name…', max(1, screen.getmaxyx()[1] - 4))
            screen.refresh()
            save(value)
            return
        except Exception as exc:
            default, error = value, str(exc)


def main(args):
    cmd = args[0] if args else 'sync'
    if cmd == 'agent-hook':
        return  # harmless compatibility for hooks cached by an older Claude process
    if cmd == 'bind':
        bind_provider(args[1], args[2], int(args[3])); return
    if cmd == 'unbind':
        unbind_provider(int(args[1])); render_titles(); return
    if cmd == 'inspect':
        print(json.dumps(cached_entries())); return
    if cmd == 'rename-space':
        if len(args) > 1:
            rename_space(os.environ.get('AMUX_SESSION', 'amux'), ' '.join(args[1:]))
        else:
            curses.wrapper(rename_ui, 'space')
        return
    if cmd == 'rename':
        if len(args) > 1:
            identity = selected_work()
            if identity:
                sync_remote(); rename_work(identity, ' '.join(args[1:]))
        else:
            curses.wrapper(rename_ui)
        return
    if cmd == 'sync':
        HOME.mkdir(parents=True, exist_ok=True)
        refresh = '--refresh' in args
        with (HOME / ('names-refresh.lock' if refresh else 'names-sync.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            unbind_provider()
            if not refresh:
                sync_local()
            sync_remote(refresh)
        return
    raise RuntimeError('Usage: amux-cli names sync | rename [NAME] | rename-space [NAME] | inspect')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception as exc:
        if sys.argv[1:2] != ['agent-hook']:
            print(str(exc), file=sys.stderr)
            sys.exit(1)
