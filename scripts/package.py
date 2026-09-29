from pathlib import Path
import hashlib, shutil, zipfile
out=Path(__file__).resolve().parents[1]; src=out/'RX9070-Qwen'
shutil.rmtree(src/'__pycache__',ignore_errors=True)
files=['launch.py','RUN-LINUX.sh','LOW-MEMORY.sh','START-POP-OS.sh','PI.sh','START-HERE.txt']
installer='''#!/usr/bin/env bash
# RX 9070 / Qwen3.8 27B installer for Pop!_OS. All embedded code is readable below.
# Run: bash Install-Qwen-PopOS.sh
# Downloads verified engine/model on first run; reuses them on subsequent runs.
set -euo pipefail
install_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/RX9070-Qwen"
mkdir -p -- "$install_dir"
'''
for idx,name in enumerate(files):
    p=src/name
    if p.suffix=='.sh':p.chmod(0o755)
    tag=f'__RX9070_EMBEDDED_FILE_{idx}__'
    body=p.read_text()
    assert tag not in body
    installer+=f'cat > "$install_dir/{name}" <<\'{tag}\'\n{body}\n{tag}\n'
installer+='''chmod +x "$install_dir/RUN-LINUX.sh" "$install_dir/LOW-MEMORY.sh" "$install_dir/START-POP-OS.sh" "$install_dir/PI.sh"
if [[ "${1:-}" == --extract-only ]]; then
    echo "Files extracted to: $install_dir"
    exit 0
fi
exec bash "$install_dir/START-POP-OS.sh" "$@"
'''
p=out/'Install-Qwen-PopOS.sh';p.write_text(installer);p.chmod(0o755)
with zipfile.ZipFile(out/'RX9070-Qwen-PopOS.zip','w',zipfile.ZIP_DEFLATED) as z:
    for name in files:z.write(src/name,arcname='RX9070-Qwen/'+name)
for p in [out/'Install-Qwen-PopOS.sh',out/'RX9070-Qwen-PopOS.zip']:
    print(p,p.stat().st_size,'bytes',hashlib.sha256(p.read_bytes()).hexdigest())
