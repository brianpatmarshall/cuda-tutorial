# CUDA + C++ Development Environment Setup — Windows 11

End-to-end setup notes for this project on **Windows 11**, mirroring `SETUP.md` (Linux) but Windows-only. Every step here is what you actually need to type or click on a fresh Windows machine to go from nothing to a working CUDA build.

> The **project itself** (`CMakeLists.txt`, `src/`, `include/`, `.clang-format`, `.gitignore`) is identical across platforms — only the toolchain around it differs.

---

## 1. What you need to know first

| Question | Answer |
|---|---|
| Which GPU? | Run `nvidia-smi` (after driver install) or look in *Device Manager → Display adapters*. |
| Compute capability? | Look up your card at <https://developer.nvidia.com/cuda-gpus>. Common laptop values: Turing `75`, Ampere `86`, Ada `89`, Blackwell `120`. |
| Disk space? | ~10 GB total — VS Build Tools alone is ~6 GB; CUDA toolkit ~3 GB. |
| Admin? | Yes — installer needs to install drivers and put MSVC into Program Files. |
| Internet? | Yes — winget pulls everything from official sources. |

---

## 2. Recommended stack

| Layer | Choice | Rationale |
|---|---|---|
| **Host compiler** | **MSVC** (Visual Studio 2022 Build Tools) | The only host compiler nvcc officially supports on Windows. MinGW and Clang are not supported. |
| **CUDA Toolkit** | **Latest 12.x** that matches your GPU's arch and your driver | If you have a Pascal (10-series) card, stick to 12.x — CUDA 13.x dropped Pascal. Modern cards can use the latest. |
| **NVIDIA driver** | **Latest Game Ready or Studio** via the NVIDIA App | Higher than the toolkit's minimum. Windows handles forward compatibility well. |
| **C++ standard** | **C++20** | nvcc 12.6 supports it; modern default. |
| **Build system** | **CMake ≥ 3.24** + **Ninja** | First-class CUDA language support; faster incremental builds than VS multi-config. |
| **IDE** | **VS Code + "Nsight Visual Studio Code Edition"** | Free, official NVIDIA extension with CUDA-GDB integration. The full Visual Studio IDE also works (with Nsight Visual Studio Edition) if you prefer it. |
| **Profilers** | **Nsight Systems** + **Nsight Compute** | Bundled with the toolkit. Both have full Windows GUIs. |
| **Style / lint** | **clang-format** | Ships with VS Build Tools' LLVM components, or via winget `LLVM.LLVM`. |

---

## 3. Manual install (reference)

The automated script in §4 does all of this. This section is the "what's actually happening" reference.

### 3.1 NVIDIA driver

Easiest: install the **NVIDIA App**, which manages driver updates with one click.

```powershell
winget install --id Nvidia.NVIDIAApp
```

Open it, sign in (optional), pick **Drivers** tab, install the latest **Game Ready** (gaming/general) or **Studio** (creative/CUDA workloads) driver. **Reboot** afterward.

Alternative: download directly from <https://www.nvidia.com/Download/index.aspx>.

### 3.2 Visual Studio 2022 Build Tools (MSVC + Windows SDK)

You need MSVC's `cl.exe`. You **don't** need the full Visual Studio IDE — Build Tools is the lightweight option (~6 GB vs ~10 GB).

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override `
  "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools `
   --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
   --includeRecommended"
```

If you'd rather use the GUI: download from <https://visualstudio.microsoft.com/downloads/> → *Build Tools for Visual Studio 2022* → in the installer, check **Desktop development with C++**. Make sure the right pane includes the **MSVC v143** toolset and a **Windows 11 SDK**.

### 3.3 CUDA Toolkit

```powershell
winget install --id Nvidia.CUDA
```

Or grab a specific version's `.exe` from <https://developer.nvidia.com/cuda-downloads> (Windows → x86_64 → 11 → exe, local or network installer).

After install, verify in a new shell:
```cmd
nvcc --version
```

The installer adds `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.x\bin` to the system `PATH` automatically.

### 3.4 Build tools

```powershell
winget install --id Kitware.CMake
winget install --id Ninja-build.Ninja
winget install --id Git.Git
```

### 3.5 VS Code + CUDA extensions

```powershell
winget install --id Microsoft.VisualStudioCode
code --install-extension nvidia.nsight-vscode-edition
code --install-extension ms-vscode.cpptools
code --install-extension ms-vscode.cmake-tools
```

The `code` CLI may not be on `PATH` until you open a new shell after installing VS Code.

---

## 4. Automated install script

Saved as **`scripts/install.ps1`**. Runs all of §3 idempotently. Driver install is opt-in (`-InstallDriver`) since you'll usually pick the driver yourself in the NVIDIA App.

### Usage

Open an **elevated PowerShell** (Right-click PowerShell → *Run as Administrator*), then:

```powershell
# Allow this session to run a local script (the policy reverts when you close the shell)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# All defaults (no driver, includes VS Code)
.\scripts\install.ps1

# Also install the NVIDIA App for driver management
.\scripts\install.ps1 -InstallDriver

# Skip VS Code if you use a different IDE
.\scripts\install.ps1 -SkipVSCode

# Help
Get-Help .\scripts\install.ps1 -Detailed
```

### Script contents

```powershell
<#
.SYNOPSIS
    Installer for the cuda_playground toolchain on Windows 11.

.DESCRIPTION
    Installs:
      - Visual Studio 2022 Build Tools (MSVC + Windows 11 SDK)  -- required by nvcc on Windows
      - CUDA Toolkit                                             -- via winget
      - CMake, Ninja, Git                                        -- via winget
      - VS Code + CUDA extensions (Nsight, C/C++, CMake Tools)   -- via winget

    The NVIDIA driver itself is opt-in (-InstallDriver). On Windows, drivers
    are usually managed by the NVIDIA App or Windows Update; the script only
    installs the NVIDIA App and tells you to open it.

.PARAMETER InstallDriver
    Install the NVIDIA App so you can pick a Game Ready / Studio driver.

.PARAMETER SkipVSCode
    Skip VS Code if you use a different IDE.

.EXAMPLE
    .\scripts\install.ps1

.EXAMPLE
    .\scripts\install.ps1 -InstallDriver

.NOTES
    Run from an *elevated* PowerShell ("Run as Administrator").
    After install, build from the "x64 Native Tools Command Prompt for VS 2022".
#>

[CmdletBinding()]
param(
    [switch]$InstallDriver,
    [switch]$SkipVSCode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log  { param([string]$m) Write-Host "[install] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[warn]    $m" -ForegroundColor Yellow }
function Die        { param([string]$m) Write-Host "[error]   $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "Run from an elevated PowerShell prompt (Right-click PowerShell -> Run as Administrator)."
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

$wingetCommon = @('--accept-source-agreements', '--accept-package-agreements', '--silent')

function Install-Winget {
    param([string]$Id, [string]$Display = $Id)
    Write-Log "installing $Display ($Id)"
    & winget install --id $Id @wingetCommon
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # -1978335189 = APPINSTALLER_CLI_ERROR_NO_APPLICABLE_UPDATE_FOUND (already installed)
        Write-Warn "winget install for $Id returned exit $LASTEXITCODE (continuing)"
    }
}

# ---------------------------------------------------------------------------
# 1. Visual Studio Build Tools 2022 (MSVC + Windows 11 SDK)
# ---------------------------------------------------------------------------
Write-Log "installing Visual Studio 2022 Build Tools (MSVC + Windows 11 SDK)"
& winget install --id Microsoft.VisualStudio.2022.BuildTools `
    --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended" `
    @wingetCommon
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    Write-Warn "VS Build Tools install returned exit $LASTEXITCODE"
}

# ---------------------------------------------------------------------------
# 2. NVIDIA driver (opt-in)
# ---------------------------------------------------------------------------
if ($InstallDriver) {
    Install-Winget 'Nvidia.NVIDIAApp' 'NVIDIA App (driver manager)'
    Write-Warn "Open the NVIDIA App and install the latest Game Ready or Studio driver."
    Write-Warn "A reboot is required afterward."
} else {
    Write-Log "skipping NVIDIA driver step (pass -InstallDriver to include the NVIDIA App)"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $drv = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader | Select-Object -First 1).Trim()
        Write-Log "current driver: $drv"
    } else {
        Write-Warn "nvidia-smi not found -- a driver may not be installed yet"
    }
}

# ---------------------------------------------------------------------------
# 3. CUDA Toolkit
# ---------------------------------------------------------------------------
Install-Winget 'Nvidia.CUDA' 'CUDA Toolkit'

# ---------------------------------------------------------------------------
# 4. Build tools
# ---------------------------------------------------------------------------
Install-Winget 'Kitware.CMake'      'CMake'
Install-Winget 'Ninja-build.Ninja'  'Ninja'
Install-Winget 'Git.Git'            'Git'

# ---------------------------------------------------------------------------
# 5. VS Code + extensions
# ---------------------------------------------------------------------------
if (-not $SkipVSCode) {
    Install-Winget 'Microsoft.VisualStudioCode' 'VS Code'

    # Refresh PATH so 'code' becomes visible in this session
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('PATH', 'User')

    if (Get-Command code -ErrorAction SilentlyContinue) {
        Write-Log "installing VS Code extensions"
        foreach ($ext in @(
            'nvidia.nsight-vscode-edition',
            'ms-vscode.cpptools',
            'ms-vscode.cmake-tools')) {
            & code --install-extension $ext --force
        }
    } else {
        Write-Warn "'code' CLI not on PATH yet -- open a new shell, then run:"
        Write-Warn "  code --install-extension nvidia.nsight-vscode-edition"
        Write-Warn "  code --install-extension ms-vscode.cpptools"
        Write-Warn "  code --install-extension ms-vscode.cmake-tools"
    }
} else {
    Write-Log "skipping VS Code (-SkipVSCode)"
}

# ---------------------------------------------------------------------------
Write-Log "done."
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "  1. Open Start menu -> 'x64 Native Tools Command Prompt for VS 2022'"
Write-Host "     (a plain PowerShell will NOT have cl.exe on PATH)"
Write-Host "  2. cd to the project directory, then:"
Write-Host "       cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release"
Write-Host "       cmake --build build"
Write-Host "       build\vector_add.exe"
Write-Host "  3. Verify the toolchain:"
Write-Host "       nvcc --version"
Write-Host "       nvidia-smi"
if ($InstallDriver) {
    Write-Host "  4. Reboot before running CUDA programs (driver was just updated)."
}
```

---

## 5. Project layout

```
cuda\
├── CMakeLists.txt           # CMake 3.24+, C++20, CUDA arch 61 (override for your GPU)
├── README.md                # quick-start
├── .clang-format            # Google base, 4-space, 100-col
├── .gitignore
├── docs\
│   └── SETUP_WINDOWS.md     # this document
├── scripts\
│   └── install.ps1          # automated environment installer (PowerShell)
├── include\
│   └── vector_add.cuh       # public kernel wrapper API
└── src\
    ├── main.cpp             # host driver, validates result
    └── vector_add.cu        # __global__ kernel + RAII-light wrapper
```

---

## 6. Build & run

**Always use the "x64 Native Tools Command Prompt for VS 2022"** (Start menu → search). A plain PowerShell or `cmd` will not have `cl.exe` on `PATH` and CMake will fail to find a host compiler.

```cmd
cd C:\path\to\cuda
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
build\vector_add.exe
```

### Override the GPU architecture for your laptop card

The `CMakeLists.txt` in this repo defaults to `61` (Pascal, GTX 1050 Ti) since that's the desktop hardware it was scaffolded on. For a modern laptop GPU, override at configure time:

```cmd
cmake -S . -B build -G Ninja -DCMAKE_CUDA_ARCHITECTURES=86
```

Common values:

| Architecture | Compute capability | Example cards |
|---|---|---|
| Pascal | `61` | GTX 1050 Ti, 1080 |
| Turing | `75` | GTX 1660, RTX 2060 |
| Ampere | `80` / `86` | A100 (80) / RTX 30-series (86) |
| Ada | `89` | RTX 40-series |
| Hopper | `90` | H100 |
| Blackwell | `100` / `120` | RTX 50-series |

Find yours at <https://developer.nvidia.com/cuda-gpus>.

---

## 7. Verify the install

In an **x64 Native Tools** prompt:

```cmd
nvidia-smi              :: driver visible, GPU listed
nvcc --version          :: should report 12.x
ninja --version
cmake --version         :: >= 3.24
cl                      :: should print Microsoft C/C++ Compiler banner
code --list-extensions  :: should include nsight, cpptools, cmake-tools
```

Then build and run; success looks like:

```
OK: 1048576 elements added on GPU
```

---

## 8. Driver rollback on Windows

If a new driver causes problems, Windows gives you three escalating recovery options. They map roughly to the Linux *Timeshift / apt downgrade / nouveau* tiers.

### 8.1 Roll back via Device Manager (gentlest)

Best when Windows still boots and the new driver is the obvious culprit.

1. *Start menu → Device Manager*.
2. *Display adapters* → right-click your NVIDIA GPU → *Properties*.
3. *Driver* tab → **Roll Back Driver**.
4. Pick a reason, click OK, reboot.

This restores the **immediately previous** driver Windows kept staged. If the button is greyed out, no previous driver is available — try §8.2.

### 8.2 System Restore (medium)

Windows automatically takes a restore point before driver installs (if System Protection is enabled — check *Settings → System → About → Advanced system settings → System Protection*).

1. *Start menu → "Create a restore point"*.
2. *System Restore...* → pick a point dated *before* the driver install → *Next* → *Finish*.
3. Windows reboots into the restored state.

This reverts driver + registry changes without affecting your files.

### 8.3 DDU (Display Driver Uninstaller) — nuclear option

When the install is wedged badly enough that neither rollback method works:

1. Download **DDU** from <https://www.guru3d.com/files-categories/category/display-driver-uninstaller-ddu/>.
2. Boot Windows in **Safe Mode** (*Settings → System → Recovery → Advanced startup → Restart now → Troubleshoot → Advanced options → Startup Settings → Restart → 4*).
3. Run DDU → *Clean and shutdown*.
4. Boot normally; install a known-good driver (a specific version from <https://www.nvidia.com/Download/index.aspx>).

DDU removes every NVIDIA driver artifact — registry keys, files, scheduled tasks. Use only when you need to.

### 8.4 Pre-emptive caution

Before any driver upgrade:

- *Settings → System → About → Advanced system settings → System Protection* → confirm protection is **On** for `C:`.
- Note the current driver: `nvidia-smi --query-gpu=driver_version --format=csv,noheader > driver-before.txt`
- Manually create a restore point: *Start → "Create a restore point" → Create*.

---

## 9. WSL2 alternative

If you'd rather mirror the Linux setup exactly on this same Windows 11 machine:

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot, complete the Ubuntu setup, then **inside WSL**:

```bash
# Use the Linux install script
./scripts/install.sh
```

Important caveats:

- **Install the Windows-side NVIDIA driver only.** Do not install a Linux driver inside WSL — Microsoft's WSL kernel ships its own driver shim that talks to the Windows driver. Installing a Linux driver inside WSL will break GPU access.
- The Windows driver must be a recent version that supports the WSL CUDA shim — any modern Game Ready / Studio driver does.
- `nvidia-smi` works inside WSL once you've installed CUDA in WSL — the GPU shows up as if it were native.
- Compute performance is within a few percent of bare Linux.

| | Native Windows (this doc) | WSL2 |
|---|---|---|
| Toolchain | MSVC | GCC (same as Linux) |
| Build identical to Linux? | No | Yes |
| GUI debugging via Nsight VSCE | Smoother | Works, slightly more setup |
| GPU driver lives where? | Windows | Windows (WSL borrows it) |
| When to pick | Tight Visual Studio integration | Mirror of Linux setup, lower friction if you already know Linux |

---

## 10. Common Windows-specific pitfalls

1. **MSVC ↔ CUDA version pairing.** Each CUDA release supports a specific range of MSVC toolset versions. If you install the *latest* MSVC and an older CUDA toolkit, nvcc may bail with *"unsupported Microsoft Visual Studio version."* The CUDA release notes list the supported MSVC range — match them, or pin an older toolset via the VS Installer's *Individual components* tab.

2. **Wrong shell.** A plain PowerShell or `cmd.exe` will not have `cl.exe` on `PATH`. Always build from the **x64 Native Tools Command Prompt for VS 2022**, or run `vcvars64.bat` first in your shell:
   ```cmd
   "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
   ```

3. **Long paths.** Some CUDA include paths exceed Windows' classic 260-char limit. Either keep the project near the drive root (`C:\src\cuda` is good) or enable long paths via the registry:
   ```powershell
   New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
     -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
   ```

4. **Antivirus on the build directory.** Real-time scanning of `build\` can dramatically slow incremental builds. Add an exclusion for the project's `build` folder if compilation feels sluggish (*Windows Security → Virus & threat protection → Manage settings → Add or remove exclusions*).

5. **Execution policy blocks `install.ps1`.** PowerShell refuses to run unsigned local scripts by default. Use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` for the current shell only — no permanent system change.

6. **PATH not refreshed.** After installing CUDA or VS Code via winget, the new `PATH` only takes effect in **new** shells. Close and re-open the terminal, don't just retry in the same window.

7. **`compute-sanitizer` works on Windows too** — same syntax: `compute-sanitizer build\vector_add.exe`. Always your first move when a kernel misbehaves.

---

## 11. Where to go next

- **Tutorial**: see `docs/CUDA_TUTORIAL.md` — 19 sections, all examples are platform-neutral.
- **NVIDIA Programming Guide**: <https://docs.nvidia.com/cuda/cuda-c-programming-guide/>
- **Best Practices Guide**: <https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/>
- **CUDA samples**: <https://github.com/NVIDIA/cuda-samples>
- **Nsight Compute training**: <https://developer.nvidia.com/nsight-compute>
