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
    response_tokens = min(1024, ctx // 4)

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
        compaction.setdefault('enabled', True)
        compaction.setdefault('modelOverrides', {})[PI_PROVIDER + '/qwen3.8-27b'] = {
            'reserveTokens': response_tokens, 'keepRecentTokens': min(1024, ctx // 4),
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
        raise RuntimeError('Start START-POP-OS.sh first and wait for READY, then run PI.sh in another terminal.')
    models = json.loads(config.read_text(encoding='utf-8'))
    provider = models['providers'][PI_PROVIDER]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(provider['baseUrl'] + '/models', timeout=5) as response:
            available = json.load(response)['data']
        if not any(model.get('id') == 'qwen3.8-27b' for model in available):
            raise ValueError('Expected Qwen model is not served here.')
    except (OSError, ValueError, KeyError, urllib.error.URLError) as exc:
        raise RuntimeError('Qwen is not ready. Keep START-POP-OS.sh running and wait for READY.') from exc
    env = os.environ.copy()
    env['PI_CODING_AGENT_DIR'] = str(ROOT / 'pi-agent')
    env['PI_OFFLINE'] = '1'
    args = [str(exe), '--offline', '--no-skills', '--no-extensions', '--provider', PI_PROVIDER,
            '--model', 'qwen3.8-27b', '--thinking', 'off'] + pi_args
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


def arguments(exe, model, device, ctx, draft, port, no_mtp=False):
    args = [str(exe), '--model', str(model), '--alias', 'qwen3.8-27b',
            '--device', device, '--split-mode', 'none', '--gpu-layers', '999',
            '--fit', 'off', '--ctx-size', str(ctx), '--parallel', '1',
            '--batch-size', '256', '--ubatch-size', '64', '--flash-attn', 'on',
            '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0', '--cache-ram', '0',
            '--host', '127.0.0.1', '--port', str(port), '--jinja', '--reasoning', 'off']
    if no_mtp:
        args += ['--spec-type', 'none']
    else:
        args += ['--spec-type', 'draft-mtp', '--spec-draft-n-max', str(draft),
                 '--spec-draft-n-min', '1', '--spec-draft-type-k', 'q8_0',
                 '--spec-draft-type-v', 'q8_0', '--spec-draft-device', device,
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
    parser.add_argument('--low-memory', action='store_true', help='2048 context, one MTP draft token')
    parser.add_argument('--no-mtp', action='store_true', help='Explicit troubleshooting mode: disable MTP')
    parser.add_argument('--ctx', type=int, choices=[2048, 4096, 8192, 16384], help='Override context; larger values may not fit')
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
    port = choose_port(opts.port)
    ctx = opts.ctx or (2048 if opts.low_memory else 4096)
    draft = 1 if opts.low_memory else 2
    profiles = [(ctx, draft)]
    if not opts.low_memory and not opts.ctx:
        profiles.append((2048, 1))
    (ROOT / 'logs').mkdir(exist_ok=True)
    for index, (ctx, draft) in enumerate(profiles):
        log_path = ROOT / 'logs' / (time.strftime('%Y%m%d-%H%M%S') + f'-ctx{ctx}.log')
        print(f'Starting: context={ctx}, MTP={not opts.no_mtp}, draft={draft}, GPU={device}\nLog: {log_path}', flush=True)
        def pi_ready():
            configure_pi(port, ctx)
            print(f'Pi is installed and configured. In a second terminal, cd to your project and run:\n'
                  f'  bash "{ROOT / "PI.sh"}"\n', flush=True)
        code, oom = serve(arguments(exe, model, device, ctx, draft, port, opts.no_mtp),
                          env, log_path, port, not opts.no_browser, pi_ready)
        if code == 0:
            return 0
        if oom and index + 1 < len(profiles):
            print('\nVRAM allocation failed. Retrying with 2048 context / one MTP draft token.\n', flush=True)
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
cat > "$install_dir/START-HERE.txt" <<'__RX9070_EMBEDDED_FILE_5__'
RX 9070 16 GB - Qwen3.8 27B - Pop!_OS / Linux
=================================

QUICK START

Single-file installer: save Install-Qwen-PopOS.sh in a folder on your SSD,
open a terminal there, and run:

    bash Install-Qwen-PopOS.sh

It creates RX9070-Qwen beside itself. Keep that folder: it contains the engine
and model. Run the same installer again to launch, or use the folder's launcher.

If you downloaded the ZIP instead:

1. Extract RX9070-Qwen-PopOS.zip to a folder on your SSD.
2. Open a terminal in the extracted RX9070-Qwen folder.
3. Run:

       bash RUN-LINUX.sh

Do NOT use sudo in front of that command. The script asks for your password
only when it installs OS packages or fixes GPU group membership.

First run downloads about 13 GB, installs llama.cpp plus its ROCm/HIP runtime,
installs Pi, downloads the exact model, verifies SHA-256 checksums, and opens
the chat page. Pi's standalone binary needs no separate Node.js/npm install.
Keep the terminal open while chatting. Press Ctrl+C to stop. Next time, run
the same command; completed downloads are reused. Interrupted model downloads
resume. The server listens only on your computer, usually http://127.0.0.1:8080.
If that port is occupied, it chooses another and prints the actual address.

USE PI FOR CODING

Keep the server terminal open and wait for READY. Open a second terminal:

    cd /path/to/your/project
    bash /path/to/RX9070-Qwen/PI.sh

For example, if you ran the installer from ~/rx9070-qwen:

    mkdir -p ~/my-project
    cd ~/my-project
    bash ~/rx9070-qwen/RX9070-Qwen/PI.sh

Pi is already configured to use this local Qwen model. No /login, paid API key,
or manual model selection is needed. PI.sh keeps your current project directory.
Pi can read, edit, and write project files and execute shell commands.

The dedicated Pi profile lives in RX9070-Qwen/pi-agent/. It sets the provider
to rx9070-local, model to qwen3.8-27b, and uses the actual server port and context.
Your usual ~/.pi profile is not modified. There is no global pi command added;
use PI.sh to select this installation and profile. Pass extra Pi flags after it,
for example: bash /path/to/RX9070-Qwen/PI.sh --print "Explain this project"

For this small context, Pi uses a short system prompt, at most 1024 output
tokens (512 in the 2K fallback), and matching compaction/history limits.
It retains the standard read/bash/edit/write tools. PI.sh disables automatic
skills/extensions loading to keep the prompt small and uses Pi's offline mode
to disable automatic network activity; inference still calls your local server.
Existing project instructions and large tool outputs can still consume context.
Use small file sections/tasks; 2K is a troubleshooting profile, not a roomy
coding workspace. Restart Pi after restarting the server with a new context.

REQUIREMENTS

- RX 9070 16 GB; x86-64 Linux with a working AMD kernel driver and GPU firmware.
- Intended for up-to-date Pop!_OS (22.04/24.04 with a working RX 9070 driver).
  Use the normal Pop!_OS software updater to install kernel/firmware updates,
  and reboot before setup if updates are pending. Apt, dnf, and pacman installers
  are included. The prebuilt engine targets Ubuntu/glibc; compatibility with
  every distro is not guaranteed. Alpine/musl and NixOS are not automatic installs.
- Python 3.10+ (installed by the shell launcher if needed).
- 20 GB free SSD space; 32 GB system RAM recommended.
- Internet for the first setup. No model/API subscription is required.

The bundled runtime does not replace the AMD display/kernel driver. If /dev/kfd
is absent, update the distro kernel and AMD GPU firmware/driver, then reboot.
Pop!_OS includes the AMDGPU kernel driver. Do not install amdgpu-dkms or the
old Ubuntu ROCm package for this launcher; the modern runtime is bundled.
If GPU permissions need fixing, the script adds your account to the relevant
render/video groups and asks you to log out and back in. It never changes GPU
device permissions to world-writable or launches the model as root.

DEFAULT SETTINGS

- Exact model: Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
- Full GPU layer offload to the detected RX 9070; one chat slot.
- Context: 4096 tokens total, shared by prompt/history and generated answer.
- Flash Attention on; K and V caches q8_0 for main and MTP contexts.
- MTP on: --spec-type draft-mtp, at most 2 draft tokens.
- Prompt batch 256; physical microbatch 64; prompt RAM cache disabled.
- Engine's embedded web chat and model's embedded chat template.
- Thinking is off to conserve the small context and response budget; MTP stays on.
- Text chat only; no extra vision projector is downloaded.

The file is 12,120,016,960 bytes (12.12 decimal GB, about 11.29 GiB).
File size is not an exact measurement of GPU weight allocation. KV cache,
compute buffers, MTP/recurrent state, the display, and other applications
all need memory too. There is no guaranteed fixed 3.5 GB KV allowance.
These are conservative starting settings, not a hardware-validated fit promise.

If startup reports a memory allocation failure, the normal launcher retries
once at 2048 context and one MTP draft token. It keeps MTP enabled. The retry
is only for startup allocation errors, not arbitrary crashes or later errors.

LOW-MEMORY / TROUBLESHOOTING

Close games and other GPU-heavy apps first. Start directly in the smaller mode:

    bash LOW-MEMORY.sh

For a deliberate comparison or to diagnose MTP-specific errors:

    bash RUN-LINUX.sh --low-memory --no-mtp

That command disables MTP explicitly. Normal launch never silently disables it.
MTP speedup varies with hardware and prompts; no tokens/second claim is made.

If the small profile works reliably, you can try a larger context:

    bash RUN-LINUX.sh --ctx 8192

This may run out of VRAM. An explicitly requested context is not reduced
automatically. Use the normal or low-memory launcher to recover.

Already have this exact GGUF? Avoid another download:

    bash RUN-LINUX.sh --model "/absolute/path/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf"

That file is SHA-256 checked. A different model/quant is intentionally rejected.
After a successful verification, unchanged file size and timestamp let the
launcher skip rehashing on subsequent runs. Force rechecking with --verify.

No GPU found: update the AMD driver/firmware and reboot. Check that /dev/kfd
and your AMD /dev/dri/renderD* node are readable and writable by your account.
The launcher stops before downloading the model if the engine cannot see a 9070.

Missing shared library / GLIBC error: use a current supported distro, ensure
its package updates are installed, and review the error in the terminal.
On Arch, if pacman reports unavailable package versions, complete your normal
full system update first; this script does not do a partial database upgrade.

If a checksum fails, the error names the bad file. Move it aside (or delete
only that named download) and rerun. Do not disable checksum validation.

Logs are saved under logs/. Send the newest log with the distro/version if
you need help. A driver reset or crash after the chat is ready stops the server;
the launcher does not hide it or repeatedly restart the GPU workload.

OpenAI-compatible API: http://127.0.0.1:8080/v1 (use the printed port).
Model alias: qwen3.8-27b. No API key is configured; access is localhost only.

All model/engine/Pi/profile/download/log files stay in this extracted folder.
Pi may edit files in the project where you start it. Delete the installation
folder to remove the installed apps and profile; project edits, OS packages,
and added GPU group memberships remain.
No background service, startup task, firewall rule, or telemetry is installed
by this launcher. Subsequent normal runs use the pinned installed engine.

PINNED SOURCES AND VALIDATION (2026-09-29)

Engine: Lemonade's llama.cpp ROCm build b1334, gfx120X (includes gfx1201).
The engine reports commit 680a036. This is a community nightly, including a
ROCm nightly runtime, not an AMD production support guarantee.
https://github.com/lemonade-sdk/llamacpp-rocm/releases/tag/b1334
SHA-256: f37d79f0e81ccda27a7f1f12d6fdaf0669b2399ca9409a9b9dd5c25d126a6beb

Model repo/revision:
https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
d562806dbafae37109975e970aae91b43e73b440
SHA-256: 58fd826723939933dc86f45b7fe04545cbc2de1c70f6fe2cdd3858c87a98c12f

Pi: v0.87.1, official standalone Linux x64 release.
https://github.com/earendil-works/pi/releases/tag/v0.87.1
SHA-256: 80d78dd62d50049a006b981d994c61255bcc10e730b0c278d4ea0a755909764c
https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/models.md
https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/settings.md

AMD explains the bundled-runtime distribution here:
https://rocm.docs.amd.com/projects/ai-ecosystem/en/latest/inference/llamacpp.html
System76 documents using ROCm with Pop!_OS's built-in AMDGPU driver:
https://support.system76.com/support/rocm/
MTP and server options:
https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md
https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

Validation: the pinned Linux engine was downloaded, SHA-256 verified, and its
--version, --help, and --list-devices commands were executed. Launcher download
and process-management behavior was tested with local fixtures. The real Pi
binary loaded the saved local-model defaults and completed a streamed tool-call
round trip against a mock local OpenAI-compatible endpoint. The full 27B model
has NOT been run on an RX 9070 by the author of this package.

__RX9070_EMBEDDED_FILE_5__
chmod +x "$install_dir/RUN-LINUX.sh" "$install_dir/LOW-MEMORY.sh" "$install_dir/START-POP-OS.sh" "$install_dir/PI.sh"
if [[ "${1:-}" == --extract-only ]]; then
    echo "Files extracted to: $install_dir"
    exit 0
fi
exec bash "$install_dir/START-POP-OS.sh" "$@"
