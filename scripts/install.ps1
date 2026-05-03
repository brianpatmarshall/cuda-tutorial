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
