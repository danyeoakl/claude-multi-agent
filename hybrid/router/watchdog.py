#!/usr/bin/env python3
"""Hybrid router watchdog and settings switch. Standard library only.

check (default; the timer runs it every 15 s): when the router's /healthz fails twice in a row and the settings
file routes through this router, remove HTTPS_PROXY, NO_PROXY and NODE_EXTRA_CA_CERTS from its env and keep their
values in a marker file; once /healthz answers again, put them back and delete the marker.
enable / disable: set or remove the three keys (install.sh, uninstall.sh). health: exit 0 when the router is up.
The settings file is rewritten atomically with indent 2; no other key is touched."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.request

KEYS = ('HTTPS_PROXY', 'NO_PROXY', 'NODE_EXTRA_CA_CERTS')
HOME = Path.home()


def say(*words, level=5):
    """One log line; under systemd the <level> prefix sets its priority (the unit keeps notice and above)."""
    prefix = f'<{level}>' if os.environ.get('JOURNAL_STREAM') else ''
    print(prefix + ' '.join(map(str, words)), file=sys.stderr if level < 5 else sys.stdout, flush=True)


def healthy(port):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never through a proxy
    try:
        with opener.open(f'http://127.0.0.1:{port}/healthz', timeout=5) as response:
            return json.load(response).get('ok') is True
    except Exception:
        return False


def ours(env, port):
    return str(env.get('HTTPS_PROXY', '')).rstrip('/') in (f'http://127.0.0.1:{port}', f'http://localhost:{port}')


def load(path):
    data = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    if not isinstance(data, dict) or not isinstance(data.get('env', {}), dict):
        raise ValueError(f'{path}: not a settings object')
    return data


def save(path, data, mode=None):
    """Atomic replacement that keeps the file's mode, and a symlinked file's link."""
    path = Path(os.path.realpath(path))
    if mode is None:
        mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    path.parent.mkdir(parents=True, mode=0o700 if mode == 0o600 else 0o777, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def check(args):
    if healthy(args.port) or (time.sleep(4) or healthy(args.port)):  # a crash-restart takes about 2 s
        if args.marker.exists():
            marker = json.loads(args.marker.read_text())
            saved, data = marker['env'], load(args.settings)
            env = data.setdefault('env', {})
            if 'HTTPS_PROXY' not in env:  # unless someone pointed the file elsewhere meanwhile
                merged = {**saved, **env}
                order = [key for key in marker.get('order', []) if key in merged]  # back in their old places
                data['env'] = {key: merged[key] for key in order + [key for key in merged if key not in order]}
                save(args.settings, data)
                say('router healthy again: restored', ', '.join(saved), 'in', args.settings)
            args.marker.unlink()
        return
    data = load(args.settings)
    env = data.get('env', {})
    if not ours(env, args.port):
        return  # the router isn't enabled in this file, or the keys are out already
    order = list(env)
    saved = {key: env.pop(key) for key in KEYS if key in env}
    save(args.marker, {'settings': str(args.settings), 'env': saved, 'order': order}, 0o600)  # first: values survive a crash
    save(args.settings, data)
    say('router down twice in a row: removed', ', '.join(saved), 'from', args.settings, level=4)


def enable(args):
    data = load(args.settings)
    env = data.setdefault('env', {})
    want = {'HTTPS_PROXY': f'http://127.0.0.1:{args.port}', 'NO_PROXY': 'localhost,127.0.0.1,::1',
            'NODE_EXTRA_CA_CERTS': str(args.ca_dir / 'ca-cert.pem')}
    if not ours(env, args.port) and any(env.get(key, want[key]) != want[key] for key in KEYS):
        raise ValueError(f'{args.settings} already sets {", ".join(key for key in KEYS if key in env)} '
                         'for something else; the router does not chain proxies, so remove them first')
    env.update(want)
    save(args.settings, data)
    args.marker.unlink(missing_ok=True)
    say('router enabled in', args.settings)


def disable(args):
    data = load(args.settings)
    env = data.get('env', {})
    if ours(env, args.port):
        for key in KEYS:
            env.pop(key, None)
        if not env:
            del data['env']
        save(args.settings, data)
        say('router disabled in', args.settings)
    args.marker.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('command', nargs='?', default='check', choices=('check', 'enable', 'disable', 'health'))
    parser.add_argument('--settings', type=Path,
                        default=os.environ.get('TJ_HYBRID_SETTINGS', HOME / '.claude/settings.json'))
    parser.add_argument('--port', type=int, default=int(os.environ.get('TJ_HYBRID_ROUTER_PORT', 4110)))
    parser.add_argument('--ca-dir', type=Path, default=HOME / '.config/tj-hybrid/router')
    parser.add_argument('--marker', type=Path, help='default: <ca-dir>/disabled-by-watchdog')
    args = parser.parse_args()
    args.settings = Path(args.settings).expanduser().absolute()
    args.ca_dir = args.ca_dir.expanduser().absolute()
    args.marker = (args.marker or args.ca_dir / 'disabled-by-watchdog').expanduser().absolute()
    if args.command == 'health':
        return 0 if healthy(args.port) else 1
    try:
        {'check': check, 'enable': enable, 'disable': disable}[args.command](args)
    except Exception as error:
        say('watchdog:', error, level=3)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
