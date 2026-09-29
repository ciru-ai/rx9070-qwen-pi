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
