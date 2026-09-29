# Qwen + Pi on an RX 9070

Install **Qwen3.8 27B GGUF + MTP**, llama.cpp ROCm/HIP, and a configured **Pi coding agent** on Pop!_OS. The default context is now **32,768 tokens**, with **64K available as an option**. Simple on/off commands manage the model in the background.

## Install or update

Allow **20 GB free SSD space** and about **13 GB of downloads**. **32 GB system RAM is recommended.** Update Pop!_OS and reboot after pending kernel/firmware updates.

If updating, stop the old server first: use `qwen off` for this version, or **Ctrl+C in the server terminal** for the old foreground version. Downloaded weights and Pi sessions are reused.

```bash
mkdir -p ~/rx9070-qwen
cd ~/rx9070-qwen
curl -fL --retry 3 https://github.com/ciru-ai/rx9070-qwen-pi/releases/latest/download/Install-Qwen-PopOS.sh -o Install-Qwen-PopOS.sh
bash Install-Qwen-PopOS.sh
```

If `curl` is missing, run `sudo apt install curl`. Do not run the installer with sudo. It requests elevated access only for OS dependencies and GPU groups. If it asks for a logout/login, do that once and run the installer again.

The installer downloads and verifies the exact model, llama.cpp with its bundled ROCm runtime, and Pi's standalone binary. **No Node.js or npm is required.** It then starts the model in your systemd user session and returns after **READY**. Closing the terminal does not stop the background model. The service is not enabled at boot; run `on` after a new login/reboot.

## Turn it on and off

```bash
# Start; reuse the last selected settings.
~/rx9070-qwen/RX9070-Qwen/qwen on

# Stop and release the model's GPU memory.
~/rx9070-qwen/RX9070-Qwen/qwen off

# Show actual context and local URL.
~/rx9070-qwen/RX9070-Qwen/qwen status

# Follow logs (Ctrl+C leaves the server running).
~/rx9070-qwen/RX9070-Qwen/qwen logs
```

The browser chat/API is usually at `http://127.0.0.1:8080`; `status` prints the actual port. The endpoint is localhost only. Repeating `on` does not launch another model copy.

## Use Pi continuously

```bash
cd /path/to/your/project
~/rx9070-qwen/RX9070-Qwen/qwen pi
```

Pi automatically selects the local Qwen model and **continues the most recent session for that project directory**. No login or API key is needed. Exit Pi when finished; its session is saved. You can stop the model, start it later, and run the same Pi command to continue.

```bash
# Start a fresh conversation instead.
~/rx9070-qwen/RX9070-Qwen/qwen pi --new

# Run a one-off task from the current project.
~/rx9070-qwen/RX9070-Qwen/qwen pi --print "Explain this project briefly"
```

The original `PI.sh` entry point still works. The dedicated Pi profile and sessions live in `RX9070-Qwen/pi-agent`; your normal `~/.pi` configuration is preserved. Pi can read, write, edit, and run shell commands in its current project.

At 32K, Pi has a **4096-token maximum response**, starts auto-compaction with **6144 tokens reserved**, and retains **8192 recent tokens**. At 64K the compaction reserve becomes 8192 tokens. These limits track the actual server context. `/compact` summarizes manually. Compaction keeps a summary rather than every old detail verbatim; the session file retains the original history.

Restart Pi after changing server context. A short system prompt and disabled automatic skills/extensions loading keep prompt overhead predictable; standard read/bash/edit/write tools remain enabled. Pi's offline mode disables automatic network activity, while inference still connects to the local model. Large project instructions/files can still consume the context.

## Find the largest fully GPU context on his RX 9070

The weight file size is not total GPU memory use. Run the measurement on his actual desktop:

```bash
~/rx9070-qwen/RX9070-Qwen/qwen off
~/rx9070-qwen/RX9070-Qwen/qwen tune
~/rx9070-qwen/RX9070-Qwen/qwen on
```

Only run `on` after the tuner reports a saved passing profile. It tests contexts from 262,144 down through 131,072 / 98,304 / 65,536 / 49,152 / 32,768 / 24,576 / 16,384 / 8,192. At each context it tries Q8 KV, then Q4. **MTP2 stays on, all layers must be GPU-offloaded, and CPU fitting is disabled.** Q4 saves KV memory but can affect quality. The first passing context is the largest tested in this list, not an exact token-by-token maximum.

A passing profile must process a **near-full context and generate 128 tokens**, while leaving at least **512 MiB of sampled free VRAM**. The tuner reads the AMD kernel's actual VRAM counters every 0.2 seconds, checks the engine's GPU layer count, and saves measurements, commands, responses, and allocation logs under `RX9070-Qwen/measurements`. Global VRAM includes desktop apps; increase over baseline is not an exclusive per-process measurement. Brief spikes can fall between samples, and later desktop workloads can consume the remaining headroom.

It can take several minutes per fitting profile. Ctrl+C stops the test and cleans up its server. After success, `on` uses the measured profile, and Pi receives its context/compaction settings. Restart Pi to pick up the change. If no profile passes, existing settings remain unchanged; close GPU-heavy apps and retry. Existing automatic-fit settings may still use CPU memory until a fully GPU profile is successfully saved.

`qwen tune --max-ctx 65536` bounds the search. `--headroom 1024` leaves more measured headroom. `--quick` only tests short generation and explicitly does **not** validate a filled context. The current default `qwen on` remains 32K automatic fitting until tuning succeeds or explicit options replace it.

This tuner requires one identifiable AMD GPU with at least 14 GiB VRAM and a successful RX 9070 engine probe. It refuses ambiguous multi-GPU telemetry. Its lifecycle/selection logic and an actual CUDA allocation-failure path were tested here; full ROCm inference still needs the friend's hardware.

[Direct VRAM measurements and allocation breakdown](benchmarks/DIRECT-VRAM.md).

## Context and GPU memory

```bash
# Standard profile: 32K, Q8 KV, automatic GPU/CPU fitting.
~/rx9070-qwen/RX9070-Qwen/qwen restart --ctx 32768 --gpu-layers auto --kv-cache q8_0

# Larger context; may put more layers on CPU and reduce speed.
~/rx9070-qwen/RX9070-Qwen/qwen restart --ctx 65536

# Require all weights on the GPU; fail rather than offload to CPU.
~/rx9070-qwen/RX9070-Qwen/qwen restart --ctx 32768 --gpu-layers 999

# Smaller KV cache for experimentation; quantization may affect quality.
~/rx9070-qwen/RX9070-Qwen/qwen restart --ctx 65536 --kv-cache q4_0
```

Options are saved by the controller and reused by subsequent `on` commands. When supplying new options, supply all non-default options you want; a new option list replaces the saved list.

| Setting | Default |
| --- | --- |
| Context | 32,768 tokens, shared by prompt/history and response |
| GPU placement | Automatic fitting; CPU offload when needed |
| Fitting headroom target | 1536 MiB; not a hard memory cap |
| MTP | Enabled, 2 draft tokens, one slot |
| Main/draft KV | Q8 K and V |
| Flash Attention | On |
| Prompt batch / microbatch | 256 / 64 |
| Model thinking | Off; separate from MTP |
| Prompt RAM cache | Disabled |

**A larger context does not imply full GPU residency.** Closing GPU-heavy applications may reduce CPU offload and improve speed. The exact model file is 12.12 decimal GB / 11.29 GiB, but KV, compute buffers, MTP/recurrent state, and the desktop need additional memory.

If startup hits an allocation error, it retries with one MTP draft token at the same context, then stops with an error if it still cannot fit. **Context is never silently reduced.** `status` shows the actual context. `--low-memory` now selects 8K/one MTP draft token; `--no-mtp` disables MTP only when explicitly requested.

## RTX 4080 SUPER capacity test

See [the test report](benchmarks/RTX-4080-SUPER.md) for exact settings, occupied-context validation, Pi continuity checks, and measured memory/speed. The CUDA tests are **capacity proxies**, not guarantees for RX 9070/ROCm performance or fit. RX 9070 full-model inference has not been tested here.

## Driver, scope, and troubleshooting

The installer uses Pop!_OS's built-in AMDGPU kernel driver plus the bundled ROCm user-space runtime. It does not install `amdgpu-dkms` or add AMD package repositories. If `/dev/kfd` is missing, update the Pop!_OS kernel/AMD firmware and reboot. GPU group changes need a full logout/login. See [System76's ROCm guide](https://support.system76.com/support/rocm/).

Intended for updated x86-64 Pop!_OS 22.04/24.04 with a working RX 9070 driver, Python 3.10+, and a systemd user session. Apt/dnf/pacman dependency paths are included; other distributions are not guaranteed. Alpine/musl and NixOS are not automatic installations.

Downloads resume and have pinned SHA-256 checks. Logs live under `RX9070-Qwen/logs` and in `qwen logs`. If the server fails, it leaves an error; it does not repeatedly restart a failing GPU workload. There is one server slot, so browser/Pi requests share it.

The legacy `START-POP-OS.sh` is a foreground alternative. Stop it with Ctrl+C before switching to `qwen on`. `qwen off` does not kill unrelated processes or a legacy foreground server.

All model/runtime/download/log/profile files stay in the installation folder. Turn the model off before deleting it. OS packages, GPU group membership, and any project files Pi edited remain. No shell-profile change, global Pi install, firewall rule, or boot startup task is added.

[Full instructions and pinned hashes](RX9070-Qwen/START-HERE.txt).

## Versions and development

- [llama.cpp ROCm b1334](https://github.com/lemonade-sdk/llamacpp-rocm/releases/tag/b1334), gfx120X, commit `680a036`; community nightly runtime.
- [ISTA-DASLab model](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF), revision `d562806dbafae37109975e970aae91b43e73b440`.
- [Pi v0.87.1](https://github.com/earendil-works/pi/releases/tag/v0.87.1), standalone Linux x64.

```bash
python3 -m unittest discover -s tests -v
python3 scripts/package.py
bash -n Install-Qwen-PopOS.sh RX9070-Qwen/*.sh RX9070-Qwen/qwen
```

Set `LLAMA_TEST_BIN` and `PI_TEST_BIN` to include optional binary integration checks. Tests use temporary folders and a mock local endpoint. Packaging rebuilds the readable single-file installer and ZIP. Launcher code is MIT licensed; upstream software/model licenses remain separate.
