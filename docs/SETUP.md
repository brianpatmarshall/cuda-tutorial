# CUDA + C++ Development Environment Setup

End-to-end setup notes for this project on **Linux Mint 22.3 / Ubuntu 24.04**, targeting an **NVIDIA GTX 1050 Ti** (Pascal, compute capability 6.1).

---

## 1. Detected environment

| Item | Value |
|---|---|
| OS | Linux Mint 22.3 (Ubuntu 24.04 "noble" base) |
| GPU | NVIDIA GeForce GTX 1050 Ti Mobile |
| Compute capability | **6.1** (Pascal) — required for `-DCMAKE_CUDA_ARCHITECTURES=61` |
| Existing driver | 535.288.01 (caps CUDA runtime at 12.2 — **upgrade recommended**) |
| GCC | 13.3.0 |
| CMake | 3.28.3 |
| `nvcc` | not installed |
| `ninja` | not installed |

---

## 2. Recommended stack

| Layer | Choice | Rationale |
|---|---|---|
| **CUDA Toolkit** | **12.6** (latest 12.x) | CUDA 13.x dropped Pascal (sm_61). 12.6 is the newest line that still supports the 1050 Ti. |
| **NVIDIA driver** | **≥ 560** | Required minimum for CUDA 12.6. |
| **Host compiler** | **GCC 13** (already installed) | Officially supported by CUDA 12.6 on Ubuntu 24.04. |
| **C++ standard** | **C++20** | nvcc 12.6 supports it; modern default. |
| **Build system** | **CMake ≥ 3.24** + **Ninja** | First-class CUDA language support (`enable_language(CUDA)`); fast incremental builds. |
| **IDE** | **VS Code + "Nsight Visual Studio Code Edition"** | Free, official NVIDIA extension with CUDA-GDB integration and `.cu` syntax. CLion is a strong paid alternative. |
| **Profilers** | **Nsight Systems** + **Nsight Compute** | Bundled with the toolkit. |
| **Style / lint** | **clang-format**, **clang-tidy** | Standard. |

---

## 3. Manual install (reference)

The automated script in §4 does all of this for you. This section is the "what's actually happening" reference.

### 3.1 NVIDIA driver

```bash
sudo apt install nvidia-driver-560
sudo reboot
```

Or use Linux Mint's **Driver Manager** GUI to pick the recommended driver.

> **Cautious about the upgrade?** Read [`DRIVER_ROLLBACK.md`](DRIVER_ROLLBACK.md) first — it covers taking a Timeshift snapshot beforehand and reverting cleanly if Cinnamon misbehaves afterward.

### 3.2 CUDA Toolkit 12.6 (network installer)

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-12-6
```

Add to `~/.bashrc`:

```bash
export PATH=/usr/local/cuda-12.6/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
```

Verify:

```bash
nvcc --version
nvidia-smi
```

### 3.3 Ninja

```bash
sudo apt install ninja-build
```

### 3.4 VS Code + extensions

```bash
# Microsoft apt repo
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
sudo install -D -o root -g root -m 644 microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list
sudo apt update && sudo apt install -y code

code --install-extension nvidia.nsight-vscode-edition
code --install-extension ms-vscode.cpptools
code --install-extension ms-vscode.cmake-tools
```

---

## 4. Automated install script

Saved as **`scripts/install.sh`**. Runs all of §3 idempotently. The NVIDIA driver step is opt-in (`--install-driver`) because it requires a reboot.

### Usage

```bash
./scripts/install.sh                 # toolkit + ninja + VS Code (no driver)
./scripts/install.sh --install-driver
./scripts/install.sh --skip-vscode   # if you use a different IDE
./scripts/install.sh --help
```

### Script contents

```bash
#!/usr/bin/env bash
#
# Installer for the cuda_playground toolchain on Ubuntu 24.04 / Linux Mint 22.x.
#
# Installs:
#   - Build prerequisites (build-essential, ninja-build, git, curl, gnupg, pkg-config)
#   - NVIDIA driver 560               (only with --install-driver; requires reboot)
#   - CUDA Toolkit 12.6               (via NVIDIA's cuda-keyring apt repo)
#   - VS Code                         (via Microsoft apt repo)
#   - VS Code extensions for CUDA dev (Nsight, C/C++, CMake Tools)
#
# Adds CUDA paths to ~/.bashrc (idempotent).
#
# Usage:
#   ./scripts/install.sh                 # everything except the NVIDIA driver
#   ./scripts/install.sh --install-driver
#   ./scripts/install.sh --skip-vscode   # if you use a different IDE
#   ./scripts/install.sh --help

set -euo pipefail

CUDA_VERSION="12-6"
CUDA_PREFIX="/usr/local/cuda-12.6"
DRIVER_PACKAGE="nvidia-driver-560"
UBUNTU_REPO="ubuntu2404"   # CUDA repo path; Mint 22.x is built on Ubuntu 24.04

INSTALL_DRIVER=0
SKIP_VSCODE=0

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --install-driver) INSTALL_DRIVER=1 ;;
        --skip-vscode)    SKIP_VSCODE=1 ;;
        -h|--help)        usage ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] && die "do not run as root; the script will sudo when needed"
command -v sudo >/dev/null || die "sudo is required"
command -v apt-get >/dev/null || die "this script targets Debian/Ubuntu apt-based systems"

# ---------------------------------------------------------------------------
log "refreshing apt and installing base build tools"
sudo apt-get update -y
sudo apt-get install -y \
    build-essential \
    ninja-build \
    cmake \
    git \
    curl \
    wget \
    gnupg \
    ca-certificates \
    pkg-config \
    clang-format \
    clang-tidy

# ---------------------------------------------------------------------------
if [[ $INSTALL_DRIVER -eq 1 ]]; then
    log "installing $DRIVER_PACKAGE (reboot required afterward)"
    sudo apt-get install -y "$DRIVER_PACKAGE"
    warn "driver installed — reboot before using CUDA"
else
    log "skipping NVIDIA driver install (pass --install-driver to include it)"
    if command -v nvidia-smi >/dev/null; then
        current_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        log "current driver: $current_driver"
        major=${current_driver%%.*}
        if [[ $major -lt 560 ]]; then
            warn "driver $current_driver is older than 560; CUDA 12.6 needs >=560"
            warn "re-run with --install-driver, or use Mint's Driver Manager"
        fi
    else
        warn "no NVIDIA driver detected (nvidia-smi missing)"
    fi
fi

# ---------------------------------------------------------------------------
log "installing CUDA Toolkit $CUDA_VERSION via NVIDIA apt repo"
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    wget -qO "$tmp/cuda-keyring.deb" \
        "https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_REPO}/x86_64/cuda-keyring_1.1-1_all.deb"
    sudo dpkg -i "$tmp/cuda-keyring.deb"
    sudo apt-get update -y
fi
sudo apt-get install -y "cuda-toolkit-${CUDA_VERSION}"

# ---------------------------------------------------------------------------
log "ensuring CUDA paths are in ~/.bashrc"
bashrc="$HOME/.bashrc"
marker="# >>> cuda_playground PATH (managed by scripts/install.sh) >>>"
if ! grep -qF "$marker" "$bashrc" 2>/dev/null; then
    {
        echo ""
        echo "$marker"
        echo "export PATH=${CUDA_PREFIX}/bin:\$PATH"
        echo "export LD_LIBRARY_PATH=${CUDA_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}"
        echo "# <<< cuda_playground PATH <<<"
    } >> "$bashrc"
    log "appended CUDA env vars to $bashrc (open a new shell to pick them up)"
else
    log "CUDA env vars already present in $bashrc"
fi

# ---------------------------------------------------------------------------
if [[ $SKIP_VSCODE -eq 0 ]]; then
    log "installing VS Code via Microsoft apt repo"
    if ! command -v code >/dev/null; then
        tmp_key=$(mktemp)
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$tmp_key"
        sudo install -D -o root -g root -m 644 "$tmp_key" /etc/apt/keyrings/packages.microsoft.gpg
        rm -f "$tmp_key"
        echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
            | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt-get install -y apt-transport-https
        sudo apt-get update -y
        sudo apt-get install -y code
    else
        log "VS Code already installed: $(code --version | head -1)"
    fi

    log "installing VS Code extensions"
    for ext in \
        nvidia.nsight-vscode-edition \
        ms-vscode.cpptools \
        ms-vscode.cmake-tools; do
        code --install-extension "$ext" --force
    done
else
    log "skipping VS Code (--skip-vscode)"
fi

# ---------------------------------------------------------------------------
log "done."
echo
echo "Next steps:"
echo "  1. Open a new shell (or 'source ~/.bashrc') so PATH picks up nvcc."
echo "  2. Verify:    nvcc --version    && nvidia-smi"
if [[ $INSTALL_DRIVER -eq 1 ]]; then
    echo "  3. Reboot before running CUDA programs (driver was just installed)."
fi
echo "  4. Build:    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release"
echo "               cmake --build build && ./build/vector_add"
```

---

## 5. Project layout

```
cuda/
├── CMakeLists.txt           # CMake 3.24+, C++20, CUDA arch 61 (overridable)
├── README.md                # quick-start
├── .clang-format            # Google base, 4-space, 100-col
├── .gitignore
├── docs/
│   └── SETUP.md             # this document
├── scripts/
│   └── install.sh           # automated environment installer
├── include/
│   └── vector_add.cuh       # public kernel wrapper API
└── src/
    ├── main.cpp             # host driver, validates result
    └── vector_add.cu        # __global__ kernel + RAII-light wrapper
```

---

## 6. Build & run

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/vector_add
```

Override the GPU architecture for a different card:

```bash
cmake -S . -B build -G Ninja -DCMAKE_CUDA_ARCHITECTURES=86   # Ampere
```

Common arch values: Pascal `61`, Turing `75`, Ampere `80`/`86`, Ada `89`, Hopper `90`.

---

## 7. Verify the install

```bash
nvidia-smi              # driver visible, GPU listed
nvcc --version          # should report 12.6
ninja --version
cmake --version         # >= 3.24
code --list-extensions | grep -E 'nsight|cpptools|cmake'
```

Then build and run; success looks like:

```
OK: 1048576 elements added on GPU
```
