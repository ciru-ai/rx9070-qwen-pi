# RTX 4080 SUPER capacity screen — 2026-09-29

**32K is the shipped default.** The exact GGUF completed a **31,672-token input plus 128 generated tokens** with MTP and Q8 KV enabled. **64K allocated successfully and completed a short request**, but a full 64K input was not tested. This is a useful tested range, not a measured maximum.

The test GPU was an **NVIDIA GeForce RTX 4080 SUPER, 16 GB**, driver 610.57.04, on a live Linux desktop. Existing applications occupied about **3,830–3,845 MiB** before model startup; they were left running. Automatic fitting was necessary under these conditions. Treat these as **CUDA capacity proxies**, not RX 9070/ROCm speed or memory guarantees. The actual RX 9070 has not been tested with this installer.

## Results

Each timing is one diagnostic request, not a repeated performance benchmark. Successful requests used a fixed seed of 42, temperature 0, no prompt-cache reuse, and forced 128-token generation. Reported generation speed is the server's decoded-token timing. Peak GPU use includes desktop applications, sampled every 0.5 seconds.

| Allocated context | KV | Placement | Actual input | Result | Generation | Peak total GPU |
| --- | --- | --- | ---: | --- | ---: | ---: |
| 16,384 | Q8 | All GPU | — | KV allocation failed | — | 15,287 MiB |
| 16,384 | Q4 | All GPU | — | Recurrent-state allocation failed | — | 15,295 MiB |
| 32,768 | Q8 | 60 GPU layers | — | Recurrent-state allocation failed | — | 14,403 MiB sampled |
| 32,768 | Q4 | 56 GPU layers | 43 | Passed | 2.54 tok/s | 15,364 MiB |
| 32,768 | Q8 | Automatic fit | 43 | Passed | 6.65 tok/s | 14,169 MiB |
| 32,768 | Q4 | All GPU, MTP 1 | — | Allocation failed | — | 15,282 MiB |
| 65,536 | Q8 | Automatic fit | 43 | Passed; short request only | 5.59 tok/s | 14,170 MiB |
| 32,768 | Q8 | Automatic fit | **31,672** | **Passed** | **4.49 tok/s** | **14,281 MiB during request** |

MTP drafted up to **2 tokens** unless the row explicitly says 1. The long run accepted **73 of 105 draft tokens**. It processed the input at **64.75 tok/s**, took **489.2 seconds to the first generated token**, and completed in about **517.5 seconds**. Long prompt ingestion can take minutes with CPU offload; the short-prompt speeds do not describe long-document latency.

The long input was repeated harmless record text followed by a question about hash-table collisions. This proves occupied-context allocation and generation, **not long-context retrieval quality or coding accuracy**. A sampled peak can miss brief allocation spikes. Failed full-GPU runs do not prove full-GPU inference is impossible on a cleaner desktop or another backend.

## Exact model and runtime

- Model: `Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf`, **12,120,016,960 bytes**.
- Model SHA-256: `58fd826723939933dc86f45b7fe04545cbc2de1c70f6fe2cdd3858c87a98c12f`.
- [Model repository](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF), revision `d562806dbafae37109975e970aae91b43e73b440`.
- CUDA test engine: upstream llama.cpp **b11146 / `7fe450e19`**, Ubuntu CUDA 12.8 binary and runtime.
- CUDA engine archive SHA-256: `c2ab9e19838513ff69d1af8d999ad717dd3c7ee4714ac04c7ed5ab9077c50e4e`.
- CUDA runtime archive SHA-256: `1466daea60aad1144819e151b2bae19d54556cf1da6c129c4f55a5ded2637c25`.
- Friend's shipped ROCm engine: [Lemonade b1334](https://github.com/lemonade-sdk/llamacpp-rocm/releases/tag/b1334), commit `680a036`, gfx120X. Its binary accepted the configured flags locally; full-model ROCm inference was not exercised.
- System RAM: approximately 60.5 GiB total, 18–20 GiB available before these tests.

The comparable test command, after configuring the downloaded CUDA runtime's library path, was:

```bash
llama-server --model /path/to/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf \
  --alias qwen3.8-27b --device CUDA0 --split-mode none \
  --gpu-layers auto --fit on --fit-target 1536 \
  --ctx-size 32768 --parallel 1 --batch-size 256 --ubatch-size 64 \
  --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 --cache-ram 0 \
  --host 127.0.0.1 --port 18089 --jinja --reasoning off --metrics --threads 16 \
  --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-min 1 \
  --spec-draft-type-k q8_0 --spec-draft-type-v q8_0 \
  --spec-draft-device CUDA0 --spec-draft-ngl 999
```

The probe originally repeated `--metrics` and `--fit-target 1536`; the engine kept the final identical value. The command above removes those duplicates. The product selects a real RX 9070 ROCm device instead of CUDA0 and leaves CPU thread count to the engine.

[Sanitized machine-readable timing and memory results](cuda-capacity-results.json) include the successful API measurements. Their `ctx` field is actual input tokens; allocated context is documented above. Raw logs, exact commands, and samples remain in the local benchmark ledger.

## Pi and launcher verification

Pi **v0.87.1** uses its isolated local-model profile, 32K context, 4096 maximum output tokens, and enabled auto-compaction with a 6144-token reserve and 8192 recent tokens retained. Model IDs and the local API endpoint were checked using the real Pi binary.

The release also passed **14 automated checks**, including resumable/checksummed downloads, device selection, subprocess cleanup, actual ROCm argument parsing, Pi default-provider/tool-loop integration, compaction budgets, and continue/new-session argument handling. A real systemd user-service lifecycle test with a lightweight HTTP stand-in passed start, duplicate-start protection, status, stop, restart, and cleanup. Package extraction was verified in a directory containing spaces.

Against the actual model, Pi successfully:

1. Used its `write` tool to create a verification file with exact requested contents.
2. Exited, restarted, resumed the same project session, and used `bash` to read the file.
3. Completed a tool-driven conversation totaling 17,013 context tokens.
4. Manually compacted it to an estimated 1,485 tokens, retaining the synthetic passphrase and file path.
5. Correctly answered `amber-river-9070` after compaction. The final response used 1,751 input tokens (1,725 cached) and 9 output tokens.

[Sanitized Pi continuity results](pi-continuity-results.json) record these checks. Auto-compaction was enabled and its model-specific settings validated; this test explicitly invoked manual compaction. This is a continuity smoke test, not a guarantee of indefinitely unattended operation or perfect summaries. Pi used the engine's default sampler (temperature 1, top-p 0.95); the capacity timing requests used temperature 0.

All test model/Pi processes were stopped afterward. No unrelated applications or model services were stopped.
