# Qwen + Pi on an RX 9070

A small installer for **Pop!_OS, AMD RX 9070 16 GB, llama.cpp ROCm/HIP, and Pi**. It downloads the exact `Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf`, enables MTP, and configures Pi to use the local model.

## 1. Install and start the model

Keep Pop!_OS updated, reboot after kernel/firmware updates, and close games or other GPU-heavy programs. Allow **20 GB free SSD space** and about **13 GB of downloads**. **32 GB system RAM is recommended.**

Open a terminal and run:

```bash
mkdir -p ~/rx9070-qwen
cd ~/rx9070-qwen
curl -fL --retry 3 https://raw.githubusercontent.com/ciru-ai/rx9070-qwen-pi/main/Install-Qwen-PopOS.sh -o Install-Qwen-PopOS.sh
bash Install-Qwen-PopOS.sh
```

If `curl` is missing, install it with `sudo apt install curl`. Alternatively, download [Install-Qwen-PopOS.sh](https://github.com/ciru-ai/rx9070-qwen-pi/releases/latest/download/Install-Qwen-PopOS.sh) through your browser and run it with `bash` from its saved folder.

Run the installer as your normal desktop user. It requests `sudo` only for OS dependencies and, if necessary, GPU group access. If it asks you to log out and back in, do that once and run the same command again.

The installer creates `RX9070-Qwen` beside itself. It downloads and verifies llama.cpp, the bundled ROCm runtime, Pi's standalone Linux binary, and the model. **No separate Node.js or npm installation is needed.** Downloads resume after interruption.

Wait for **READY**. The browser chat opens automatically. Keep this terminal open; **Ctrl+C stops the model**. The default address is `http://127.0.0.1:8080`; a different free port is selected if needed.

## 2. Start Pi in your project

Open a **second terminal**, change to the folder where you want Pi to work, and start the configured agent:

```bash
mkdir -p ~/my-project
cd ~/my-project
bash ~/rx9070-qwen/RX9070-Qwen/PI.sh
```

For an existing project, replace `~/my-project` with its path. Pi starts in the current working directory and can read, edit, and write files and execute shell commands there. No login or paid API key is needed.

Pi uses the local `rx9070-local/qwen3.8-27b` model automatically. Its dedicated profile is in `RX9070-Qwen/pi-agent`; your normal `~/.pi` configuration is preserved. Use `PI.sh`, not an unrelated globally installed `pi` command, for this profile.

## Next time

Terminal 1:

```bash
bash ~/rx9070-qwen/RX9070-Qwen/START-POP-OS.sh
```

Wait for READY, then run `PI.sh` from your project in terminal 2. The installed downloads are reused. Restart Pi if you restart the server with different context settings.

## Memory settings

| Setting | Default | Startup allocation-error fallback |
| --- | --- | --- |
| Context | 4096 tokens | 2048 tokens |
| MTP | Enabled, 2 draft tokens | Enabled, 1 draft token |
| Main and draft KV | Q8 K and V | Q8 K and V |
| Parallel chats | 1 | 1 |
| GPU layers | All | All |
| Flash Attention | On | On |
| Prompt batch / microbatch | 256 / 64 | 256 / 64 |
| Pi maximum response | 1024 tokens | 512 tokens |

**MTP and model thinking are separate.** MTP stays enabled; thinking is off to conserve the small context budget. Pi uses a concise system prompt, its standard read/bash/edit/write tools, and compaction settings sized for the active context. Its wrapper disables automatic skills/extensions loading and automatic network activity; inference still connects to the local server.

A 4K context is small for coding: use focused tasks and short file sections. Large project instructions or tool output can still overflow it. The 2K mode is primarily for troubleshooting. If 4K is stable and VRAM allows, try `START-POP-OS.sh --ctx 8192`; there is no guarantee that this larger profile will fit.

The model file is **12.12 decimal GB / 11.29 GiB**. That is not a measurement of total GPU allocation. KV, MTP/recurrent state, compute buffers, the desktop, and other applications also consume VRAM. The launcher does not assume there is a fixed 3.5 GB KV allowance.

## Useful commands

```bash
# Start with lower memory usage.
bash ~/rx9070-qwen/RX9070-Qwen/LOW-MEMORY.sh

# Explicit diagnostic run with MTP disabled.
bash ~/rx9070-qwen/RX9070-Qwen/START-POP-OS.sh --low-memory --no-mtp

# Reuse an existing copy of the exact model; its checksum is verified.
bash ~/rx9070-qwen/RX9070-Qwen/START-POP-OS.sh --model /path/to/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf

# Run a single Pi task from your current project directory.
bash ~/rx9070-qwen/RX9070-Qwen/PI.sh --print "Explain this project briefly"
```

The automatic retry only handles an allocation error before READY. Other failures stop and leave an error/log. MTP is never silently disabled. Logs are under `RX9070-Qwen/logs`.

## Driver and installation scope

Pop!_OS already includes an AMDGPU kernel driver. The installer uses it and bundles the ROCm user-space runtime. It does not install a replacement graphics/kernel driver, add an AMD apt repository, or install `amdgpu-dkms`. If `/dev/kfd` is missing, update the Pop!_OS kernel/AMD firmware, reboot, and retry. See [System76's ROCm guide](https://support.system76.com/support/rocm/).

Intended for current Pop!_OS 22.04/24.04 installations with a working RX 9070 driver. Apt, dnf, and pacman dependency paths are included; compatibility across every Linux distribution is not guaranteed. Alpine/musl and NixOS are not automatic installations.

All app binaries, model files, downloads, logs, and the dedicated Pi profile live inside `RX9070-Qwen`. There is no background service, firewall change, global Pi install, or startup task. Delete that folder to remove those files. OS packages, GPU group membership, and any files Pi edits in your project remain.

## Versions and checks

- [llama.cpp ROCm b1334](https://github.com/lemonade-sdk/llamacpp-rocm/releases/tag/b1334), gfx120X, engine commit `680a036`. This is a community nightly with a ROCm nightly runtime.
- [Exact GSQ-RCO model](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF), pinned revision `d562806dbafae37109975e970aae91b43e73b440`.
- [Pi v0.87.1](https://github.com/earendil-works/pi/releases/tag/v0.87.1), official standalone Linux x64 binary.

Download SHA-256 values and detailed troubleshooting are in [START-HERE.txt](RX9070-Qwen/START-HERE.txt).

The pinned engine's version, help, device enumeration, and CLI flags were checked. Automated tests cover download integrity/resume, GPU selection, process cleanup, Pi settings, and a real Pi binary exchanging streamed tool calls with a mock local endpoint. **The full model has not been tested on an RX 9070; fit, tool reliability, and speed on that card remain unverified.**

## Development

```bash
python3 -m unittest discover -s tests -v
python3 scripts/package.py
bash -n Install-Qwen-PopOS.sh RX9070-Qwen/*.sh
```

Set `LLAMA_TEST_BIN` and `PI_TEST_BIN` to downloaded executables to include the optional integration tests. Tests use temporary folders and a mock local server; they do not download model weights or modify your Pi profile. `scripts/package.py` rebuilds the readable single-file installer and ZIP from `RX9070-Qwen/`.

Launcher code is MIT licensed. Downloaded upstream software and model weights retain their own licenses.
