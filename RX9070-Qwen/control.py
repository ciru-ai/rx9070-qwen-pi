#!/usr/bin/env python3
"""Start/stop the local Qwen server as an on-demand systemd user service."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
UNIT = 'qwen-rx9070-' + hashlib.sha256(str(ROOT).encode()).hexdigest()[:10] + '.service'


def state():
    return subprocess.run(['systemctl', '--user', 'show', UNIT, '-p', 'ActiveState', '--value'],
                          capture_output=True, text=True).stdout.strip()


def live_info():
    try:
        info = json.loads((ROOT / 'ready.json').read_text())
        os.kill(info['launcher_pid'], 0)
        cmdline = Path(f'/proc/{info["launcher_pid"]}/cmdline').read_bytes().split(b'\0')
        if str(ROOT / 'launch.py').encode() not in cmdline:
            return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f'http://127.0.0.1:{info["port"]}/health', timeout=2) as response:
            if json.load(response).get('status') == 'ok':
                return info
    except (OSError, ValueError, KeyError):
        pass
    return None


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'status'
    args = sys.argv[2:]
    if command in ('help', '--help', '-h'):
        print('Usage: qwen on [--ctx 32768] | off | restart [options] | status | logs | pi [Pi options]')
        return 0
    if command == 'pi':
        os.execv(sys.executable, [sys.executable, str(ROOT / 'launch.py'), '--pi'] + args)
    if command not in ('on', 'off', 'restart', 'status', 'logs'):
        raise RuntimeError('Unknown command. Run qwen help.')
    if not shutil.which('systemctl') or not shutil.which('systemd-run'):
        raise RuntimeError('On/off commands require a systemd user session (included with Pop!_OS).')
    if command == 'logs':
        os.execvp('journalctl', ['journalctl', '--user', '-u', UNIT, '-f', '-n', '60'])
    if command == 'status':
        status = state()
        info = live_info() if status in ('active', 'activating') else None
        if info:
            print(f'ON: http://127.0.0.1:{info["port"]} | context {info["context"]} | MTP {info["mtp"]}')
        else:
            print('STARTING' if status in ('active', 'activating') else 'OFF')
        return 0
    if command in ('off', 'restart'):
        if state() in ('active', 'activating', 'deactivating', 'failed'):
            subprocess.run(['systemctl', '--user', 'stop', UNIT], check=True)
        elif live_info():
            raise RuntimeError('A foreground launcher is running. Press Ctrl+C in its terminal first; then use qwen on.')
        print('OFF. Model GPU memory released; Pi sessions remain saved.')
        if command == 'off':
            return 0
    if state() in ('active', 'activating') or live_info():
        print('Qwen is already running. Use qwen status or qwen restart to change settings.')
        return 0
    saved = ROOT / 'server-options.json'
    if not args and saved.exists():
        args = json.loads(saved.read_text())
    # Dependencies/downloads run in this terminal so sudo and progress remain visible.
    subprocess.run(['bash', str(ROOT / 'RUN-LINUX.sh'), '--prepare-only'] + args, check=True)
    # The permissions helper exits after asking for a new login; do not background a broken setup.
    if not os.access('/dev/kfd', os.R_OK | os.W_OK):
        raise RuntimeError('Log out and back in for GPU permissions, then run qwen on again.')
    (ROOT / 'ready.json').unlink(missing_ok=True)
    saved.write_text(json.dumps(args) + '\n')
    subprocess.run(['systemd-run', '--user', '--quiet', '--collect', '--unit', UNIT,
                    '--description', 'Local Qwen MTP server for Pi',
                    '--property=KillMode=control-group', '--property=TimeoutStopSec=30',
                    sys.executable, str(ROOT / 'launch.py'), '--no-browser'] + args, check=True)
    print('Starting Qwen in the background. Waiting for READY...', flush=True)
    start = time.monotonic()
    while time.monotonic() - start < 900:
        status = state()
        info = live_info() if status in ('active', 'activating') else None
        if info:
            print(f'ON: http://127.0.0.1:{info["port"]} | context {info["context"]} | MTP {info["mtp"]}')
            print(f'In your project folder, run: {ROOT / "qwen"} pi')
            return 0
        if status not in ('active', 'activating'):
            subprocess.run(['journalctl', '--user', '-u', UNIT, '--no-pager', '-n', '30'])
            raise RuntimeError('Qwen failed to start. See the error above and logs/; use qwen on to retry.')
        time.sleep(1)
    raise RuntimeError('Still starting after 15 minutes. Use qwen logs or qwen off.')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nStopped waiting. Use qwen status or qwen off to control the background server.')
        sys.exit(130)
    except (RuntimeError, OSError, subprocess.CalledProcessError, ValueError) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
