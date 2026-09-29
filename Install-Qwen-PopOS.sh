#!/usr/bin/env bash
# RX 9070 / Qwen3.8 27B installer for Pop!_OS. All embedded code is readable below.
# Run: bash Install-Qwen-PopOS.sh
# Downloads verified engine/model on first run; reuses them on subsequent runs.
set -euo pipefail
install_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/RX9070-Qwen"
mkdir -p -- "$install_dir"
cat > "$install_dir/launch.py" <<'__RX9070_EMBEDDED_FILE_0__'
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

__RX9070_EMBEDDED_FILE_0__
cat > "$install_dir/RUN-LINUX.sh" <<'__RX9070_EMBEDDED_FILE_1__'
#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if (( EUID == 0 )); then
    echo 'Run this as your normal desktop user, without sudo.'
    echo 'It asks for sudo only if OS packages or GPU permissions need fixing.'
    exit 1
fi
if [[ "$(uname -m)" != x86_64 ]]; then
    echo 'This launcher requires an x86-64 PC with an RX 9070.'
    exit 1
fi

# Install small OS dependencies once. The launcher downloads ROCm itself locally.
if [[ ! -f .linux-dependencies-ready ]]; then
    echo 'Installing Python, CA certificates, OpenMP, curl runtime, and browser-opening support.'
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        curl_package=libcurl4
        if apt-cache show libcurl4t64 >/dev/null 2>&1; then
            curl_package=libcurl4t64
        fi
        sudo apt-get install -y python3 ca-certificates libgomp1 "$curl_package" xdg-utils
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 ca-certificates libgomp libcurl xdg-utils
    elif command -v pacman >/dev/null 2>&1; then
        # No database refresh here: avoid creating an Arch partial-upgrade state.
        sudo pacman -S --needed --noconfirm python ca-certificates gcc-libs curl xdg-utils
    else
        echo 'Automatic OS dependency installation supports apt, dnf, and pacman.'
        echo 'Install Python 3.10+, CA certificates, OpenMP, libcurl, and xdg-utils with your package manager.'
        echo 'Then run: python3 launch.py'
        exit 1
    fi
    touch .linux-dependencies-ready
fi

if [[ ! -e /dev/kfd ]]; then
    echo
    echo 'The AMD compute device /dev/kfd is missing.'
    echo 'Update your distro kernel and AMD GPU firmware/driver, reboot, and run this again.'
    echo 'RX 9070 requires a recent driver with RDNA4 support.'
    echo 'This launcher installs the user-space ROCm engine, not a replacement kernel/graphics driver.'
    echo 'AMD guide: https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/'
    exit 1
fi

gpu_nodes=(/dev/kfd)
shopt -s nullglob
for node in /dev/dri/renderD*; do
    # Check only AMD render devices, so an unrelated Intel GPU cannot block setup.
    vendor="/sys/class/drm/${node##*/}/device/vendor"
    if [[ -r "$vendor" ]] && [[ "$(cat "$vendor")" == 0x1002 ]]; then
        gpu_nodes+=("$node")
    fi
done
groups_to_add=()
for node in "${gpu_nodes[@]}"; do
    if [[ ! -r "$node" || ! -w "$node" ]]; then
        group="$(stat -c %G "$node")"
        if [[ "$group" == render || "$group" == video ]]; then
            groups_to_add+=("$group")
        else
            echo "No read/write access to $node (group: $group). Ask your distro admin to fix GPU access."
            exit 1
        fi
    fi
done
if (( ${#groups_to_add[@]} )); then
    group_list="$(IFS=,; echo "${groups_to_add[*]}")"
    echo "Adding your account to GPU access groups: $group_list"
    sudo usermod -aG "$group_list" "$(id -un)"
    echo 'GPU access configured. Log out of the desktop completely, log back in, and run this again.'
    exit 0
fi

exec python3 launch.py "$@"

__RX9070_EMBEDDED_FILE_1__
cat > "$install_dir/LOW-MEMORY.sh" <<'__RX9070_EMBEDDED_FILE_2__'
#!/usr/bin/env bash
set -euo pipefail
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/RUN-LINUX.sh" --low-memory "$@"

__RX9070_EMBEDDED_FILE_2__
cat > "$install_dir/START-POP-OS.sh" <<'__RX9070_EMBEDDED_FILE_3__'
#!/usr/bin/env bash
set -euo pipefail
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/RUN-LINUX.sh" "$@"

__RX9070_EMBEDDED_FILE_3__
cat > "$install_dir/PI.sh" <<'__RX9070_EMBEDDED_FILE_4__'
#!/usr/bin/env bash
# Run this from the project directory where Pi should work.
set -euo pipefail
launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$launcher_dir/launch.py" --pi "$@"

__RX9070_EMBEDDED_FILE_4__
cat > "$install_dir/qwen" <<'__RX9070_EMBEDDED_FILE_5__'
#!/usr/bin/env bash
set -euo pipefail
launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    bash "$launcher_dir/RUN-LINUX.sh" --prepare-only
fi
exec python3 "$launcher_dir/control.py" "$@"

__RX9070_EMBEDDED_FILE_5__
cat > "$install_dir/control.py" <<'__RX9070_EMBEDDED_FILE_6__'
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
        print('Usage: qwen on [--ctx 32768] | off | restart [options] | status | logs | tune [--max-ctx 262144] | pi [Pi options]')
        return 0
    if command == 'pi':
        os.execv(sys.executable, [sys.executable, str(ROOT / 'launch.py'), '--pi'] + args)
    if command == 'tune':
        if state() in ('active', 'activating') or live_info():
            raise RuntimeError('Run qwen off before tuning; the tuner launches temporary measured servers.')
        subprocess.run(['bash', str(ROOT / 'RUN-LINUX.sh'), '--prepare-only'], check=True)
        os.execv(sys.executable, [sys.executable, str(ROOT / 'tune.py')] + args)
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

__RX9070_EMBEDDED_FILE_6__
cat > "$install_dir/tune.py" <<'__RX9070_EMBEDDED_FILE_7__'
#!/usr/bin/env python3
"""Measure the RX 9070 directly and select the largest tested all-GPU profile."""
import argparse
import fcntl
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.request
import launch as L

MIB = 1024 ** 2
CONTEXTS = [262144, 131072, 98304, 65536, 49152, 32768, 24576, 16384, 8192]


def find_gpu(root=Path('/sys/class/drm')):
    devices = {}
    for card in root.glob('card[0-9]*'):
        if not re.fullmatch(r'card\d+', card.name):
            continue
        dev = (card / 'device').resolve()
        try:
            if (dev / 'vendor').read_text().strip() == '0x1002' and int((dev / 'mem_info_vram_total').read_text()) >= 14 * 1024 ** 3:
                devices[str(dev)] = dev
        except (OSError, ValueError):
            pass
    if len(devices) != 1:
        raise RuntimeError('Measurement needs exactly one AMD GPU with at least 14 GiB VRAM; cannot safely identify it on this system.')
    return next(iter(devices.values()))


def memory(dev):
    total = int((dev / 'mem_info_vram_total').read_text())
    used = int((dev / 'mem_info_vram_used').read_text())
    return {'total_mib': total / MIB, 'used_mib': used / MIB, 'free_mib': (total - used) / MIB}


def placement(log):
    matches = re.findall(r'offloaded (\d+)/(\d+) layers to GPU', log)
    return tuple(map(int, matches[-1])) if matches else None


def acceptable(row, headroom):
    layers = row.get('layers')
    return bool(row.get('completed') and layers and layers[0] == layers[1]
                and row.get('minimum_free_mib', -1) >= headroom)


def probe(exe, model, device, dev, ctx, cache, headroom, folder, full=True):
    port = L.choose_port(18090)
    cmd = L.arguments(exe, model, device, ctx, 2, port, gpu_layers='999', kv_cache=cache) + ['--verbosity', '4']
    baseline = memory(dev)
    samples = [baseline]
    stop = threading.Event()
    errors = []
    def sample():
        last_update = time.monotonic()
        while not stop.wait(0.2):
            try:
                samples.append(memory(dev))
                if time.monotonic() - last_update >= 30:
                    print(f"  measuring: {samples[-1]['used_mib']:.0f} MiB used, {samples[-1]['free_mib']:.0f} MiB free", flush=True)
                    last_update = time.monotonic()
            except (OSError, ValueError) as exc:
                errors.append(str(exc)); return
    thread = threading.Thread(target=sample, daemon=True)
    row = {'context': ctx, 'kv_cache': cache, 'command': cmd, 'baseline': baseline, 'completed': False}
    log_path = folder / f'ctx{ctx}-{cache}.log'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(path, body=None, timeout=3):
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if body is None else json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
        with opener.open(req, timeout=timeout) as response:
            return json.load(response)
    proc = None
    try:
        with log_path.open('w') as log:
            thread.start()
            proc = subprocess.Popen(cmd, cwd=exe.parent, env=L.engine_environment(exe), stdout=log, stderr=subprocess.STDOUT)
            start = time.monotonic()
            healthy = False
            while proc.poll() is None and time.monotonic() - start < 180:
                try:
                    if request('/health').get('status') == 'ok':
                        props = request('/props')
                        if props['default_generation_settings']['n_ctx'] != ctx:
                            raise RuntimeError('Server context did not match the requested context.')
                        healthy = True; break
                except (OSError, ValueError):
                    pass
                time.sleep(0.5)
            if healthy:
                text = 'Explain how a hash table resolves collisions, with a short example.'
                if full:
                    target = ctx - 1024
                    count = max(1, target // 20)
                    for _ in range(8):
                        text = ('Record: amber river cedar valley. This record is padding for a context capacity test.\n' * count) + '\nExplain hash table collision handling briefly.'
                        tokens = len(request('/tokenize', {'content': text, 'add_special': True}, timeout=30)['tokens'])
                        if target - 256 <= tokens <= target:
                            break
                        count = max(1, int(count * (target - 128) / tokens))
                    if not target - 256 <= tokens <= target:
                        raise RuntimeError('Could not construct a near-full context test.')
                    row['input_tokens'] = tokens
                row['validation'] = 'near-full context plus generation' if full else 'short generation only'
                answer = request('/completion', {'prompt': text, 'n_predict': 128, 'temperature': 0, 'seed': 42, 'ignore_eos': True, 'cache_prompt': False}, timeout=3600 if full else 300)
                row['timings'] = answer.get('timings')
                row['response'] = answer.get('content', '')
                row['completed'] = bool(row['response'].strip() and answer.get('timings', {}).get('predicted_n', 0) > 0 and proc.poll() is None)
            else:
                row['error'] = 'Server failed or timed out before readiness.'
    except (OSError, ValueError, RuntimeError) as exc:
        row['error'] = str(exc)
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
        stop.set()
        if thread.ident is not None:
            thread.join(timeout=3)
        row['process_exit'] = proc.returncode if proc else None
    log = log_path.read_text(errors='replace')
    row['layers'] = placement(log)
    row['allocation_failure'] = bool(L.OOM.search(log))
    row['peak_total_vram_mib'] = max(x['used_mib'] for x in samples)
    row['minimum_free_mib'] = min(x['free_mib'] for x in samples)
    row['increase_over_baseline_mib'] = row['peak_total_vram_mib'] - baseline['used_mib']
    row['samples'] = samples
    if errors:
        row['completed'] = False; row['error'] = 'VRAM sampling failed: ' + errors[0]
    row['qualified'] = acceptable(row, headroom)
    (folder / f'ctx{ctx}-{cache}.json').write_text(json.dumps(row, indent=2) + '\n')
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-ctx', type=int, choices=CONTEXTS, default=262144)
    parser.add_argument('--headroom', type=int, default=512, help='Minimum sampled free VRAM in MiB (default 512)')
    parser.add_argument('--quick', action='store_true', help='Only short generation; does not validate a filled context')
    opts = parser.parse_args()
    if opts.headroom < 0:
        parser.error('--headroom must be non-negative')
    lock = (L.ROOT / '.launcher.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Stop this installation with qwen off before tuning.')
    exe = L.install_engine('ubuntu')
    device = L.probe(exe, L.engine_environment(exe))
    dev = find_gpu()
    model = L.ROOT / 'models' / L.MODEL_NAME
    if not L.verified(model, L.MODEL_SHA):
        raise RuntimeError('Run the installer first to download the verified model.')
    folder = L.ROOT / 'measurements' / time.strftime('%Y%m%d-%H%M%S')
    folder.mkdir(parents=True)
    print('Measuring this GPU with MTP2 and all model layers on GPU. CPU fitting is disabled.', flush=True)
    print('Testing ' + ('short generation only.' if opts.quick else 'near-full context plus 128 generated tokens; this may take several minutes per fitting profile.'), flush=True)
    print('Q8 is preferred at a given context; Q4 is also tested and may affect quality.', flush=True)
    print('Initial VRAM:', json.dumps(memory(dev)), flush=True)
    chosen = None
    rows = []
    for ctx in CONTEXTS:
        if ctx > opts.max_ctx:
            continue
        for cache in ['q8_0', 'q4_0']:
            print(f'Testing context {ctx}, {cache} ...', flush=True)
            row = probe(exe, model, device, dev, ctx, cache, opts.headroom, folder, full=not opts.quick)
            rows.append({k: v for k, v in row.items() if k not in ('samples', 'response')})
            print(f"  passed={row['qualified']} | peak {row['peak_total_vram_mib']:.0f} MiB | free {row['minimum_free_mib']:.0f} MiB | GPU layers {row['layers']}", flush=True)
            if row['qualified']:
                chosen = row; break
            if not row['completed'] and not row['allocation_failure']:
                raise RuntimeError(f'Non-allocation failure; see {folder}. Existing settings remain unchanged.')
        if chosen:
            break
    report = {'measurement': 'AMD kernel sysfs total VRAM, sampled every 0.2 seconds', 'device': str(dev), 'headroom_mib': opts.headroom, 'model_sha256': L.MODEL_SHA, 'tests': rows, 'selected': None}
    if chosen:
        args = ['--ctx', str(chosen['context']), '--gpu-layers', '999', '--kv-cache', chosen['kv_cache']]
        L.update_json(L.ROOT / 'measured-profile.json', lambda d: d.update(context=chosen['context'], kv_cache=chosen['kv_cache'], report=str(folder)))
        # The controller reads this array on the next qwen on.
        temp = L.ROOT / 'server-options.json.tmp'
        temp.write_text(json.dumps(args) + '\n'); temp.replace(L.ROOT / 'server-options.json')
        report['selected'] = args
        print(f"Saved largest passing tested profile: {chosen['context']} context, {chosen['kv_cache']}, full GPU + MTP2. Run qwen on, then restart Pi.", flush=True)
    else:
        print('No tested all-GPU profile fit. Existing settings remain unchanged. Close GPU-heavy applications and rerun.', flush=True)
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Measurements and engine logs:', folder, flush=True)
    return 0 if chosen else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nMeasurement stopped; its test server was cleaned up.'); sys.exit(130)
    except (OSError, ValueError, RuntimeError) as exc:
        print('ERROR:', exc, file=sys.stderr); sys.exit(1)

__RX9070_EMBEDDED_FILE_7__
cat > "$install_dir/START-HERE.txt" <<'__RX9070_EMBEDDED_FILE_8__'
RX 9070 16 GB - Qwen3.8 27B MTP + Pi - Pop!_OS
================================================

INSTALL OR UPDATE

Save Install-Qwen-PopOS.sh in a folder on your SSD and run it with bash.
It creates RX9070-Qwen beside itself, downloads verified engine/model/Pi files,
then starts Qwen as a background systemd user service. Existing downloads and
Pi sessions are preserved. Before upgrading an old foreground installation,
press Ctrl+C in its server terminal; before updating a managed installation,
run qwen off. Do not run the installer with sudo.

Typical installation:

    mkdir -p ~/rx9070-qwen
    cd ~/rx9070-qwen
    curl -fL https://github.com/ciru-ai/rx9070-qwen-pi/releases/latest/download/Install-Qwen-PopOS.sh -o Install-Qwen-PopOS.sh
    bash Install-Qwen-PopOS.sh

CONTROLS

    ~/rx9070-qwen/RX9070-Qwen/qwen on
    ~/rx9070-qwen/RX9070-Qwen/qwen off
    ~/rx9070-qwen/RX9070-Qwen/qwen status
    ~/rx9070-qwen/RX9070-Qwen/qwen logs
    ~/rx9070-qwen/RX9070-Qwen/qwen restart --ctx 65536

The on command returns after READY. You can then close that terminal. The
service lives in your desktop login session; it is not enabled at boot.
Off stops the service and its model process, releasing their GPU memory.
Explicit options are saved, so a later on uses the same settings. To reset
back to the standard profile, use qwen restart --ctx 32768 --gpu-layers auto
--kv-cache q8_0. This installation has its own service name.

The browser/API address is printed by on/status, usually http://127.0.0.1:8080.
The API is localhost only; no firewall change or remote access is configured.
Use the old START-POP-OS.sh only if you want a foreground server. Stop that
foreground server with Ctrl+C before switching to the on/off controller.

PI FOR CONTINUOUS CODING

    cd /path/to/your/project
    ~/rx9070-qwen/RX9070-Qwen/qwen pi

Pi uses the local Qwen model, with no login or paid API key. It automatically
continues the most recent session for your current project directory. To start
a fresh conversation, use qwen pi --new. The original PI.sh entry point still
works. Print/RPC/session-selection arguments can be passed through to Pi.

Pi's saved profile is RX9070-Qwen/pi-agent; your normal ~/.pi is untouched.
Sessions persist across exiting Pi, turning off Qwen, and restarting the PC.
Run qwen on again and qwen pi from the same project to continue.

At 32K context, Pi allows up to 4096 output tokens, starts auto-compaction with
6144 tokens reserved, and retains up to 8192 recent tokens. At 64K, it reserves
8192 tokens and keeps 8192 recent tokens. These limits are recalculated for
the actual context when the server becomes ready. Restart Pi after changing
server context. /compact can summarize manually; compaction preserves a summary,
not every old detail verbatim. Your session file retains the original history.

The standard read/bash/edit/write tools remain enabled. Pi can modify files and
run commands in its current project. It uses a concise prompt; automatic
skills/extensions loading is disabled to keep context predictable. Pi offline
mode disables automatic network activity while inference calls your local model.
Large files/project instructions can still fill context; read relevant sections.

MEASURE THE LARGEST FULLY GPU CONTEXT

    ~/rx9070-qwen/RX9070-Qwen/qwen off
    ~/rx9070-qwen/RX9070-Qwen/qwen tune
    ~/rx9070-qwen/RX9070-Qwen/qwen on

Run on only after tune reports a saved passing profile. Tune tests the actual
RX 9070, from 262144 context down through 131072, 98304, 65536, 49152, 32768,
24576, 16384, and 8192. At each context it tries Q8 KV then Q4; Q4 can affect
quality. MTP2 stays enabled and all layers must be on GPU. CPU fitting is off.

By default it processes a near-full context plus 128 generated tokens and
requires 512 MiB sampled free VRAM. This can take several minutes. It reads
actual AMD kernel VRAM counters every 0.2 seconds and saves logs/measurements
under measurements/. These are whole-GPU measurements including the desktop.
The largest passing tested profile is saved for qwen on; restart Pi afterward.

Use tune --max-ctx 65536 to bound the search, --headroom 1024 for more margin,
or --quick for allocation/short-generation only (no filled-context validation).
Ctrl+C cleans up the temporary server. If nothing passes, settings are unchanged;
close GPU-heavy apps and retry. Later desktop usage can consume free headroom.
The untuned default remains 32K automatic GPU/CPU fitting.

MEMORY AND MODEL SETTINGS

Default context is 32768 tokens, shared by prompt/history and response: 8 times
the original 4K. MTP stays enabled, with 2 draft tokens and one server slot.
Main and draft KV use Q8; flash attention is on; prompt batch/microbatch 256/64.
Thinking is off to conserve the output/context budget; this is separate from MTP.
The model is text-only here; no vision projector is downloaded.

Automatic VRAM fitting keeps the requested context and places some layers on
CPU when GPU memory is tight. CPU offload reduces speed. Closing GPU-heavy apps
can improve how much fits on the GPU. The 1536 MiB fitting margin is a target,
not an enforced VRAM cap. CUDA fit results do not guarantee ROCm memory behavior.

If startup still fails to allocate memory, it retries with one MTP draft token
at the same context. Context is never silently reduced. If that also fails,
it stops with an error. Low-memory mode explicitly selects 8K, not 2K.

    qwen restart --ctx 65536                  # larger context, potentially slower
    qwen restart --ctx 32768 --gpu-layers 999  # force all weights on GPU; may OOM
    qwen restart --ctx 65536 --kv-cache q4_0   # smaller KV; quality may differ
    qwen restart --low-memory                # 8K, one MTP draft token
    qwen restart --ctx 32768 --no-mtp          # explicit MTP troubleshooting only

Use the full qwen path above unless you created a shell alias.
The exact model is Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf: 12,120,016,960 bytes,
about 11.29 GiB. Weight file size is not total VRAM use; KV, compute buffers,
MTP/recurrent state and desktop applications also need memory.

PREREQUISITES AND TROUBLESHOOTING

- RX 9070 16 GB, x86-64 Pop!_OS with working AMDGPU kernel driver/firmware.
- 20 GB free SSD space, about 13 GB initial download, 32 GB system RAM recommended.
- Python 3.10+ and systemd user sessions. The launcher installs OS dependencies.
- Pi's pinned standalone binary needs no Node.js or npm installation.
- Intended for updated Pop!_OS 22.04/24.04; other apt/dnf/pacman distros may work.

If /dev/kfd is missing, update Pop!_OS kernel/AMD firmware, reboot, and retry.
The script uses the built-in AMDGPU driver with a bundled ROCm user-space runtime.
Do not install amdgpu-dkms or the old distro ROCm package for this setup.
GPU group changes require a full logout/login once, then rerun qwen on.

If a download is interrupted, rerun to resume. SHA-256 mismatches name the bad
file: move it aside and retry. --verify forces rehashing of a cached model.
To reuse the exact GGUF already on disk, add --model /absolute/path/model.gguf.

Logs are in RX9070-Qwen/logs and qwen logs. Runtime failures stop with an error;
the installer does not repeatedly restart a failing GPU workload. There is one
server slot, so simultaneous browser/Pi requests share that slot.

Turn qwen off before deleting the installation folder. That folder contains the
model, runtimes, logs and Pi profile/sessions. OS packages, GPU groups and any
files Pi edited in your project remain. No shell profile or global Pi is changed.

PINNED SOURCES

Engine: Lemonade b1334 / gfx120X, llama.cpp commit 680a036, community ROCm nightly.
https://github.com/lemonade-sdk/llamacpp-rocm/releases/tag/b1334
SHA256 f37d79f0e81ccda27a7f1f12d6fdaf0669b2399ca9409a9b9dd5c25d126a6beb

Model: ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
Revision d562806dbafae37109975e970aae91b43e73b440
https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
SHA256 58fd826723939933dc86f45b7fe04545cbc2de1c70f6fe2cdd3858c87a98c12f

Pi: official standalone v0.87.1, Linux x64.
https://github.com/earendil-works/pi/releases/tag/v0.87.1
SHA256 80d78dd62d50049a006b981d994c61255bcc10e730b0c278d4ea0a755909764c

https://support.system76.com/support/rocm/
https://rocm.docs.amd.com/projects/ai-ecosystem/en/latest/inference/llamacpp.html

See the repository README and benchmark report for the RTX 4080 SUPER capacity
screen and its limitations. RX 9070/ROCm full-model inference is still untested.

__RX9070_EMBEDDED_FILE_8__
chmod +x "$install_dir/RUN-LINUX.sh" "$install_dir/LOW-MEMORY.sh" "$install_dir/START-POP-OS.sh" "$install_dir/PI.sh" "$install_dir/qwen"
if [[ "${1:-}" == --extract-only ]]; then
    echo "Files extracted to: $install_dir"
    exit 0
fi
exec bash "$install_dir/qwen" on "$@"
