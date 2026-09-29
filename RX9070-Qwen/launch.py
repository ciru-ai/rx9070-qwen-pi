#!/usr/bin/env python3
"""Linux RX 9070 launcher; standard library only. See START-HERE.txt."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
import zipfile

ROOT = Path(__file__).resolve().parent
MODEL_NAME = 'Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf'
MODEL_SHA = '58fd826723939933dc86f45b7fe04545cbc2de1c70f6fe2cdd3858c87a98c12f'
MODEL_SIZE = 12120016960
MODEL_URL = ('https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF/resolve/'
             'd562806dbafae37109975e970aae91b43e73b440/' + MODEL_NAME)
RELEASE = 'b1334'
ENGINE_SHA = {'ubuntu': 'f37d79f0e81ccda27a7f1f12d6fdaf0669b2399ca9409a9b9dd5c25d126a6beb'}
PI_VERSION = '0.87.1'
PI_SHA = '80d78dd62d50049a006b981d994c61255bcc10e730b0c278d4ea0a755909764c'
PI_PROVIDER = 'rx9070-local'
OOM = re.compile(r'out of memory|hipErrorOutOfMemory|failed to allocate|unable to allocate|cannot allocate memory', re.I)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def verification_identity(path, digest):
    stat = path.stat()
    return {'sha256': digest, 'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns}


def save_verification(path, digest):
    path.with_name(path.name + '.verified.json').write_text(
        json.dumps(verification_identity(path, digest)), encoding='utf-8')


def verified(path, digest, force=False):
    if not path.is_file():
        return False
    stamp = path.with_name(path.name + '.verified.json')
    identity = verification_identity(path, digest)
    try:
        if not force and json.loads(stamp.read_text()) == identity:
            return True
    except (OSError, ValueError):
        pass
    print('Checking SHA-256:', path.name, flush=True)
    if sha256(path) != digest:
        return False
    save_verification(path, digest)
    return True


def download(url, dest, digest, size=None, force=False):
    """Resume into a .part; never replace an existing invalid file silently."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if verified(dest, digest, force):
        return
    if dest.exists():
        raise RuntimeError(f'Checksum mismatch: {dest}. Move this file aside and run again.')
    part = dest.with_name(dest.name + '.part')
    # An interrupted run may have finished the transfer but not renamed it.
    if part.exists() and (size is None or part.stat().st_size == size):
        if sha256(part) == digest:
            part.replace(dest)
            save_verification(dest, digest)
            return
        if size is not None and part.stat().st_size >= size:
            raise RuntimeError(f'Invalid completed download: {part}. Delete that .part file and retry.')
    for attempt in range(1, 5):
        try:
            offset = part.stat().st_size if part.exists() else 0
            headers = {'User-Agent': 'RX9070-Qwen-Launcher/1.0', 'Accept-Encoding': 'identity'}
            if offset:
                headers['Range'] = f'bytes={offset}-'
            print(f'Downloading {dest.name} (attempt {attempt}; resume {offset / 1e9:.2f} GB)', flush=True)
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
                if response.status == 206:
                    if not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                        raise RuntimeError('Server returned an unexpected download range.')
                elif response.status == 200:
                    offset = 0  # Server ignored Range: overwrite, never append duplicate bytes.
                else:
                    raise RuntimeError(f'Unexpected HTTP status: {response.status}')
                total = size or (offset + int(response.headers.get('Content-Length', 0)))
                received = offset
                last = 0.0
                with part.open('ab' if offset else 'wb') as f:
                    while True:
                        block = response.read(4 * 1024 * 1024)
                        if not block:
                            break
                        f.write(block)
                        received += len(block)
                        if time.monotonic() - last > 3:
                            print(f'  {received / 1e9:.2f} / {total / 1e9:.2f} GB', flush=True)
                            last = time.monotonic()
                if total and received != total:
                    raise OSError(f'Incomplete transfer: {received} of {total} bytes')
            break
        except (OSError, urllib.error.URLError) as exc:
            if attempt == 4:
                raise RuntimeError('Download interrupted; rerun to resume. ' + str(exc)) from exc
            time.sleep(attempt * 2)
    print('Verifying downloaded file...', flush=True)
    if sha256(part) != digest:
        raise RuntimeError(f'Checksum mismatch: {part}. Delete that .part file and retry.')
    part.replace(dest)
    save_verification(dest, digest)


def extract(archive, dest):
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        for member in z.infolist():
            target = (dest / member.filename).resolve()
            if dest.resolve() not in target.parents and target != dest.resolve():
                raise RuntimeError('Unsafe archive path: ' + member.filename)
        z.extractall(dest)
    if os.name != 'nt':
        for p in dest.rglob('llama-*'):
            if p.is_file() and not p.suffix:
                p.chmod(p.stat().st_mode | 0o755)


def install_engine(system):
    folder = ROOT / 'engine' / (RELEASE + '-' + system)
    exe_name = 'llama-server.exe' if system == 'windows' else 'llama-server'
    marker = folder / '.installed'
    matches = list(folder.rglob(exe_name)) if marker.exists() else []
    if not matches:
        name = f'llama-{RELEASE}-{system}-rocm-gfx120X-x64.zip'
        archive = ROOT / 'downloads' / name
        download(f'https://github.com/lemonade-sdk/llamacpp-rocm/releases/download/{RELEASE}/{name}',
                 archive, ENGINE_SHA[system])
        print('Unpacking llama.cpp and the bundled ROCm/HIP runtime...', flush=True)
        extract(archive, folder)
        matches = list(folder.rglob(exe_name))
        if len(matches) != 1:
            raise RuntimeError('Expected exactly one llama-server in the engine archive.')
        marker.write_text(ENGINE_SHA[system], encoding='utf-8')
    return matches[0].resolve()


def install_pi():
    folder = ROOT / 'pi-runtime' / PI_VERSION
    exe = folder / 'pi' / 'pi'
    if not (folder / '.installed').is_file() or not exe.is_file():
        archive = ROOT / 'downloads' / f'pi-{PI_VERSION}-linux-x64.tar.gz'
        download(f'https://github.com/earendil-works/pi/releases/download/v{PI_VERSION}/pi-linux-x64.tar.gz',
                 archive, PI_SHA)
        folder.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, 'r:gz') as tar:
            # Allow plain files/directories only; works on Python 3.10 too.
            for member in tar.getmembers():
                target = (folder / member.name).resolve()
                if (folder.resolve() not in target.parents and target != folder.resolve()) or not (
                        member.isfile() or member.isdir()):
                    raise RuntimeError('Unsafe Pi archive member: ' + member.name)
            tar.extractall(folder)
        exe.chmod(0o755)
        result = subprocess.run([str(exe), '--version'], capture_output=True, text=True, timeout=60)
        if result.returncode or result.stdout.strip() != PI_VERSION:
            raise RuntimeError('Pi could not start: ' + result.stdout + result.stderr)
        (folder / '.installed').write_text(PI_SHA, encoding='utf-8')
    return exe


def update_json(path, update):
    data = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    update(data)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def configure_pi(port, ctx):
    """Dedicated profile: preserve the user's usual ~/.pi configuration."""
    folder = ROOT / 'pi-agent'
    folder.mkdir(exist_ok=True)
    response_tokens = min(4096, ctx // 4)

    def models(data):
        data.setdefault('providers', {})[PI_PROVIDER] = {
            'baseUrl': f'http://127.0.0.1:{port}/v1',
            'api': 'openai-completions', 'apiKey': 'local-no-key-required',
            'models': [{
                'id': 'qwen3.8-27b', 'name': 'Qwen3.8 27B - RX 9070 (local)',
                'reasoning': False, 'input': ['text'], 'contextWindow': ctx,
                'maxTokens': response_tokens,
                'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
                'compat': {'supportsStore': False, 'supportsDeveloperRole': False,
                           'supportsReasoningEffort': False, 'maxTokensField': 'max_tokens'},
            }],
        }

    def settings(data):
        data.update(defaultProvider=PI_PROVIDER, defaultModel='qwen3.8-27b',
                    defaultThinkingLevel='off')
        data.setdefault('defaultTools', ['read', 'bash', 'edit', 'write'])
        compaction = data.setdefault('compaction', {})
        compaction['enabled'] = True
        compaction.setdefault('modelOverrides', {})[PI_PROVIDER + '/qwen3.8-27b'] = {
            'reserveTokens': min(ctx // 2, response_tokens + max(512, ctx // 16)),
            'keepRecentTokens': min(8192, ctx // 4),
        }
        data.setdefault('branchSummary', {})['reserveTokens'] = response_tokens

    update_json(folder / 'models.json', models)
    update_json(folder / 'settings.json', settings)
    system = folder / 'SYSTEM.md'
    if not system.exists():
        system.write_text(
            'You are a local coding assistant. Inspect relevant files before editing. '
            'Make focused changes, preserve unrelated work, and verify the result. '
            'Use read, write, edit, and bash tools when needed. Read short file sections '
            'and limit command output; your context is small. Keep replies concise. '
            'Ask before destructive operations. Never claim unperformed work.\n', encoding='utf-8')


def run_pi(pi_args):
    exe = ROOT / 'pi-runtime' / PI_VERSION / 'pi' / 'pi'
    config = ROOT / 'pi-agent' / 'models.json'
    if not exe.exists() or not config.exists():
        raise RuntimeError('Run qwen on first and wait for READY, then run qwen pi from your project.')
    models = json.loads(config.read_text(encoding='utf-8'))
    provider = models['providers'][PI_PROVIDER]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(provider['baseUrl'] + '/models', timeout=5) as response:
            available = json.load(response)['data']
        if not any(model.get('id') == 'qwen3.8-27b' for model in available):
            raise ValueError('Expected Qwen model is not served here.')
    except (OSError, ValueError, KeyError, urllib.error.URLError) as exc:
        raise RuntimeError('Qwen is not ready. Run qwen on and wait for READY.') from exc
    env = os.environ.copy()
    env['PI_CODING_AGENT_DIR'] = str(ROOT / 'pi-agent')
    env['PI_OFFLINE'] = '1'
    args = [str(exe), '--offline', '--no-skills', '--no-extensions', '--provider', PI_PROVIDER,
            '--model', 'qwen3.8-27b', '--thinking', 'off']
    new_session = '--new' in pi_args
    pi_args = [arg for arg in pi_args if arg != '--new']
    session_flags = ('--continue', '-c', '--resume', '-r', '--session', '--session-id',
                     '--fork', '--no-session', '--print', '-p', '--mode')
    if not new_session and not any(arg.split('=')[0] in session_flags for arg in pi_args):
        args.append('--continue')
    args += pi_args
    # Keep the calling terminal's working directory: that is Pi's project.
    os.execve(str(exe), args, env)


def engine_environment(exe):
    env = os.environ.copy()
    # Avoid unrelated llama.cpp settings, GPU masks, and HIP spoofing from other apps.
    for key in list(env):
        if key.startswith('LLAMA_ARG_') or key in (
            'HSA_OVERRIDE_GFX_VERSION', 'HIP_VISIBLE_DEVICES', 'ROCR_VISIBLE_DEVICES',
            'CUDA_VISIBLE_DEVICES', 'GGML_CUDA_VISIBLE_DEVICES', 'LLVM_PATH'):
            del env[key]
    key = 'PATH' if os.name == 'nt' else 'LD_LIBRARY_PATH'
    env[key] = str(exe.parent) + os.pathsep + env.get(key, '')
    return env


def probe(exe, env):
    def run(option):
        p = subprocess.run([str(exe), option], cwd=exe.parent, env=env,
                           capture_output=True, text=True, errors='replace', timeout=90)
        text = p.stdout + p.stderr
        if p.returncode:
            raise RuntimeError(f'Engine check failed ({p.returncode}).\n{text}\n'
                               'See START-HERE.txt for driver/runtime troubleshooting.')
        return text
    help_text = run('--help')
    required = ['draft-mtp', '--spec-draft-n-max', '--spec-draft-type-k',
                '--spec-draft-type-v', '--fit', '--cache-ram', '--flash-attn', '--jinja']
    if any(flag not in help_text for flag in required):
        raise RuntimeError('This engine does not expose the required MTP/memory flags.')
    devices = run('--list-devices')
    print(devices, flush=True)
    for line in devices.splitlines():
        match = re.match(r'\s*(ROCm\d+):\s+(.+)', line)
        if match and re.search(r'\b9070\b', match[2]):
            if re.search(r'\(0 MiB', line):
                raise RuntimeError('RX 9070 reports zero VRAM. Update the AMD driver and reboot.')
            return match[1]
    raise RuntimeError('No RX 9070 ROCm device detected. Install/update the AMD GPU driver and reboot.\n'
                       'On Linux also check /dev/kfd and render/video group membership.\n'
                       'The model has not been downloaded.')


def arguments(exe, model, device, ctx, draft, port, no_mtp=False, gpu_layers='auto', kv_cache='q8_0'):
    args = [str(exe), '--model', str(model), '--alias', 'qwen3.8-27b',
            '--device', device, '--split-mode', 'none', '--gpu-layers', str(gpu_layers),
            '--fit', 'on' if gpu_layers == 'auto' else 'off', '--fit-target', '1536',
            '--ctx-size', str(ctx), '--parallel', '1',
            '--batch-size', '256', '--ubatch-size', '64', '--flash-attn', 'on',
            '--cache-type-k', kv_cache, '--cache-type-v', kv_cache, '--cache-ram', '0',
            '--host', '127.0.0.1', '--port', str(port), '--jinja', '--reasoning', 'off', '--metrics']
    if no_mtp:
        args += ['--spec-type', 'none']
    else:
        args += ['--spec-type', 'draft-mtp', '--spec-draft-n-max', str(draft),
                 '--spec-draft-n-min', '1', '--spec-draft-type-k', kv_cache,
                 '--spec-draft-type-v', kv_cache, '--spec-draft-device', device,
                 '--spec-draft-ngl', '999']
    return args


def choose_port(preferred):
    for port in range(preferred, min(preferred + 20, 65536)):
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
                return port
            except OSError:
                pass
    raise RuntimeError('No free local port; stop another server or use --port NUMBER.')


def serve(args, env, log_path, port, browser, on_ready=None):
    """Return (exit code, allocation failure before ready); always reap our process."""
    ready = False
    memory_error = threading.Event()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with log_path.open('w', encoding='utf-8') as log:
        log.write(json.dumps(args) + '\n')
        log.flush()
        proc = subprocess.Popen(args, cwd=Path(args[0]).parent, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors='replace', bufsize=1)

        def output():
            for line in proc.stdout:
                log.write(line)
                log.flush()
                print(line, end='', flush=True)
                if OOM.search(line):
                    memory_error.set()

        reader = threading.Thread(target=output, daemon=True)
        reader.start()
        started = time.monotonic()
        try:
            while proc.poll() is None:
                if not ready:
                    try:
                        with opener.open(f'http://127.0.0.1:{port}/health', timeout=1) as r:
                            healthy = r.status == 200 and json.load(r).get('status') == 'ok'
                        if healthy:
                            ready = True
                            if on_ready:
                                on_ready()
                            print(f'\nREADY: http://127.0.0.1:{port}\nKeep this window open. Ctrl+C stops the model.\n', flush=True)
                            if browser:
                                try:
                                    webbrowser.open(f'http://127.0.0.1:{port}')
                                except Exception:
                                    pass
                    except (OSError, ValueError, urllib.error.URLError):
                        pass
                    if not ready and time.monotonic() - started > 900:
                        raise RuntimeError('Model was not ready after 15 minutes. See ' + str(log_path))
                time.sleep(1)
            reader.join(timeout=5)
            return proc.returncode, memory_error.is_set() and not ready
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            reader.join(timeout=5)
            proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--low-memory', action='store_true', help='8192 context, one MTP draft token')
    parser.add_argument('--no-mtp', action='store_true', help='Explicit troubleshooting mode: disable MTP')
    parser.add_argument('--ctx', type=int, choices=[8192, 16384, 24576, 32768, 49152, 65536, 98304, 131072, 262144], help='Override context; larger values may not fit')
    parser.add_argument('--prepare-only', action='store_true', help='Install and verify dependencies/model/Pi, then exit')
    parser.add_argument('--gpu-layers', default='auto', help='auto fits VRAM; 999 forces full GPU offload')
    parser.add_argument('--kv-cache', choices=['q8_0', 'q4_0'], default='q8_0')
    parser.add_argument('--port', type=int, default=8080)
    parser.add_argument('--model', type=Path, help='Use an existing copy of this exact GGUF (SHA checked)')
    parser.add_argument('--verify', action='store_true', help='Rehash the model even if unchanged')
    parser.add_argument('--no-browser', action='store_true')
    parser.add_argument('--pi', nargs=argparse.REMAINDER, default=None, help='Run the configured Pi agent; remaining flags go to Pi')
    opts = parser.parse_args()
    if not 1024 <= opts.port <= 65535:
        parser.error('--port must be between 1024 and 65535')
    if platform.machine().lower() not in ('amd64', 'x86_64'):
        raise RuntimeError('This package requires an x86-64 Windows/Linux PC.')
    if sys.platform != 'linux':
        raise RuntimeError('This package supports Linux only.')
    if sys.version_info < (3, 10):
        raise RuntimeError('Python 3.10 or newer is required.')
    if opts.pi is not None:
        run_pi(opts.pi)
        return 0
    if opts.gpu_layers != 'auto' and not opts.gpu_layers.isdigit():
        parser.error('--gpu-layers must be auto or a non-negative integer')
    # Held for this process's lifetime; never permit two copies of this installation.
    run_lock = (ROOT / '.launcher.lock').open('a')
    try:
        fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('This installation already has a running launcher. Use qwen status/off.')
    system = 'ubuntu'
    print('RX 9070 / Qwen3.8 27B / llama.cpp ROCm + MTP\n'
          'First run: about 13 GB to download. Allow 20 GB free disk space.\n'
          'Close games and other GPU-heavy applications. 32 GB system RAM recommended.\n', flush=True)
    exe = install_engine(system)
    env = engine_environment(exe)
    device = probe(exe, env)
    install_pi()
    model = opts.model.expanduser().resolve() if opts.model else ROOT / 'models' / MODEL_NAME
    if opts.model:
        if not verified(model, MODEL_SHA, opts.verify):
            raise RuntimeError('The --model file is missing or is not the exact expected GGUF.')
    else:
        partial = model.with_name(model.name + '.part')
        remaining = max(0, MODEL_SIZE - (partial.stat().st_size if partial.exists() else 0))
        if not model.exists() and shutil.disk_usage(ROOT).free < remaining + 1024**3:
            raise RuntimeError('Not enough free disk space for the model. Free at least 14 GB and rerun.')
        download(MODEL_URL, model, MODEL_SHA, MODEL_SIZE, opts.verify)
    if opts.prepare_only:
        print('Installation ready.')
        return 0
    port = choose_port(opts.port)
    ctx = opts.ctx or (8192 if opts.low_memory else 32768)
    draft = 1 if opts.low_memory else 2
    profiles = [(ctx, draft)]
    if not opts.low_memory and not opts.no_mtp:
        profiles.append((ctx, 1))
    (ROOT / 'logs').mkdir(exist_ok=True)
    for index, (ctx, draft) in enumerate(profiles):
        log_path = ROOT / 'logs' / (time.strftime('%Y%m%d-%H%M%S') + f'-ctx{ctx}.log')
        print(f'Starting: context={ctx}, MTP={not opts.no_mtp}, draft={draft}, GPU={device}, layers={opts.gpu_layers}\nLog: {log_path}', flush=True)
        if opts.gpu_layers == 'auto':
            print('Automatic VRAM fitting may keep some layers on the CPU to preserve context; this reduces speed.', flush=True)
        def pi_ready():
            configure_pi(port, ctx)
            update_json(ROOT / 'ready.json', lambda data: data.update(
                launcher_pid=os.getpid(), port=port, context=ctx, mtp=not opts.no_mtp))
            print(f'Pi is installed and configured. In a second terminal, cd to your project and run:\n'
                  f'  bash "{ROOT / "PI.sh"}"\n', flush=True)
        code, oom = serve(arguments(exe, model, device, ctx, draft, port, opts.no_mtp, opts.gpu_layers, opts.kv_cache),
                          env, log_path, port, not opts.no_browser, pi_ready)
        if code == 0:
            return 0
        if oom and index + 1 < len(profiles):
            print('\nVRAM allocation failed. Keeping the context and retrying with one MTP draft token.\n', flush=True)
            continue
        raise RuntimeError(f'Server exited ({code}). Read {log_path}.\n'
                           'Try the LOW-MEMORY launcher after closing GPU-heavy apps.\n'
                           'For diagnosis only, run with --no-mtp. MTP is never silently disabled.')
    return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nStopped.')
        sys.exit(0)
    except Exception as exc:
        print('\nERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
