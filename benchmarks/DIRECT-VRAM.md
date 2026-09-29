# Direct VRAM measurements — 2026-09-29

**The weights do fit in roughly 12 GB.** The exact all-layer GPU loading log reported **11,159.69 MiB of CUDA model buffers**, plus 388.38 MiB of CPU-mapped model buffers. File size (12,120,016,960 bytes) and GPU buffer size are different measurements.

The problem in the earlier test was the available budget on the live desktop. NVIDIA reported about **3,940 MiB already used**, leaving approximately **12,000 MiB free** after driver reservations. Loading the weights leaves little for KV cache, recurrent state, MTP, compute buffers, and CUDA runtime allocations. This is not evidence of an AMD-specific model or a clean 16 GB card's maximum.

## What was measured

Same exact model hash and CUDA b11146 / `7fe450e19` as the [original report](RTX-4080-SUPER.md). One slot, MTP2, flash attention, b256/u64, 16 CPU threads. Engine verbosity 4 records actual allocations and layer placement. `nvidia-smi` sampled both the model process's GPU usage and total GPU usage every 0.5 seconds. Measurements are sampled peaks, not guaranteed instantaneous maxima.

| Allocated context | KV | Fit margin | GPU layers | Model-process peak | Whole-GPU peak | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 65,536 | Q8 | 1,536 MiB | 38/66 | 9,998 MiB | 13,969 MiB | Short generation passed |
| 131,072 | Q8 | 1,536 MiB | 30/66 | 10,186 MiB | 14,176 MiB | Short generation passed |
| 262,144 | Q8 | 1,536 MiB | 18/66 | 9,900 MiB | 13,880 MiB | Short generation passed |
| 262,144 | Q4 | 1,536 MiB | 25/66 | 10,166 MiB | 14,147 MiB | Short generation passed |
| 8,192 | Q4 | Fitting disabled | 66/66 | 11,408 MiB | 15,357 MiB | Recurrent-state allocation failed |
| 65,536 | Q4 | 512 MiB | 49/66 | 11,258 MiB | 15,225 MiB | Short generation passed |

Successful rows processed 43 input tokens and generated 32 tokens. **128K and 262K were allocated and short-smoked, not filled.** The earlier 32K occupied-context result remains the validated filled-context test. Automatic fitting makes 262K load by moving much of the model and KV to CPU; it is not an all-GPU 262K result. Smaller fit margins increase GPU residency but also reduce desktop headroom. These single diagnostics are not a speed ranking.

[Machine-readable measurements and allocation logs](direct-vram-results.json) preserve each successful/failed profile's placement, model buffers, KV, recurrent state, compute buffers, process RSS and sampled GPU peaks. RSS includes mapped/shared pages and must not be interpreted as exclusive CPU weight allocation. Two accidentally overlapping early probe labels were excluded and repeated sequentially; the probe now uses an exclusive lock, checks port availability, and verifies actual context identity.

## Why the earlier 64K run was slow

Its allocation log shows:

- GPU model buffers: **7,173.37 MiB**; CPU-mapped model buffers: **4,374.70 MiB**.
- Main KV: **1,224 MiB GPU + 952 MiB CPU = 2,176 MiB**.
- Recurrent state: **252.49 MiB GPU + 196.38 MiB CPU**.
- Main GPU compute buffer: **440.88 MiB**.
- MTP GPU KV: **136 MiB**, plus **274.27 MiB** draft compute buffer.

Those figures explain the substantial CPU placement. They are engine allocation records, not estimates from the weight file. Do not add unrelated/overlapping buffer logs and call that an observed VRAM peak; the process/whole-device measurements above capture what the driver reported.

The all-layer 8K Q4 test loaded 11,159.69 MiB of CUDA model buffers and 144 MiB of main KV, then failed requesting another **448.88 MiB** of recurrent state. It never reached successful inference. Failed allocations and brief peaks may not appear in sampled driver usage.

## Measure the friend's actual RX 9070

The release now includes:

```bash
~/rx9070-qwen/RX9070-Qwen/qwen off
~/rx9070-qwen/RX9070-Qwen/qwen tune
# After a saved passing profile:
~/rx9070-qwen/RX9070-Qwen/qwen on
```

The tuner tests a descending context ladder from 262,144 to 8,192, Q8 then Q4 at each context. It keeps MTP2, requires all layers on GPU, disables automatic CPU fitting, and checks a near-full context plus 128 generated tokens. A profile must leave at least 512 MiB of sampled free VRAM. Successful settings are saved and Pi is configured when `on` starts the server.

VRAM comes from the [AMD kernel's documented `mem_info_vram_total` and `mem_info_vram_used` counters](https://docs.kernel.org/gpu/amdgpu/driver-misc.html), polled every 0.2 seconds. These are whole-GPU counters; desktop changes affect the baseline delta. Logs record the selected GPU, exact commands and allocations. This measures his machine instead of transferring a CUDA assumption to ROCm. It finds the largest passing context in its published ladder, not a token-by-token maximum. Q4 may affect quality, and later GPU workloads may consume reserved headroom.

Validation: 17 automated checks passed across the launcher/Pi/tuner, including near-full prompt construction, rejecting CPU offload or insufficient free memory, refusing ambiguous GPUs, and cleaning up test children. An additional real CUDA run through the new tuner verified allocation-failure detection and cleanup using live GPU counters. Actual RX 9070/ROCm inference remains untested here. All temporary test servers were stopped.
