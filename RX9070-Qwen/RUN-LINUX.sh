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
