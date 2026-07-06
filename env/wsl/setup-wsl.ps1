<#
.SYNOPSIS
  One-time Windows-side setup for the DIY Genetics pipeline backend in WSL2.

.DESCRIPTION
  Runs on Windows (PowerShell). Ensures the WSL2 distro exists, enables systemd
  in it (so Docker runs as a persistent service), verifies the RTX GPU is visible
  inside WSL, then invokes env/wsl/bootstrap-wsl.sh to install the toolchain.

  Idempotent. The heavy work (Docker, CUDA toolkit, conda env) happens inside WSL.

.PARAMETER Distro
  WSL distro name to use. Default: Ubuntu-24.04 (already present on this box).

.PARAMETER RepoPath
  Path to the repo INSIDE the WSL distro. Default: ~/diy_genetics
  (clone or copy the repo there first, or pass -RepoPath).

.PARAMETER GpuTest
  Also run a `docker run --gpus all` smoke test during bootstrap.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File env\wsl\setup-wsl.ps1 -GpuTest
#>
[CmdletBinding()]
param(
  [string]$Distro   = "Ubuntu-24.04",
  [string]$RepoPath = "~/diy_genetics",
  [switch]$GpuTest
)

$ErrorActionPreference = "Stop"
function Info($m){ Write-Host "[setup-wsl] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[setup-wsl] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[setup-wsl] $m" -ForegroundColor Red; exit 1 }

# --- 1. WSL present? --------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Fail "wsl.exe not found. Install WSL2 first:  wsl --install"
}

# --- 2. distro present? -----------------------------------------------------
# wsl -l outputs UTF-16; normalize before matching.
$distros = (wsl.exe -l -q) -replace "`0","" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($distros -notcontains $Distro) {
  Warn "distro '$Distro' not found. Installed: $($distros -join ', ')"
  Info "installing $Distro (this downloads and provisions it)…"
  wsl.exe --install -d $Distro
  Fail "After $Distro finishes first-run setup (create a user), re-run this script."
}
Info "using distro: $Distro"

# --- 3. enable systemd in the distro (persistent Docker daemon) -------------
# Write /etc/wsl.conf [boot] systemd=true if not already set, then restart WSL.
$needRestart = $false
$hasSystemd = (wsl.exe -d $Distro -- bash -lc "grep -qi 'systemd=true' /etc/wsl.conf 2>/dev/null && echo yes || echo no").Trim()
if ($hasSystemd -ne "yes") {
  Info "enabling systemd in $Distro/etc/wsl.conf…"
  wsl.exe -d $Distro -u root -- bash -lc "printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf"
  $needRestart = $true
}
if ($needRestart) {
  Info "restarting WSL to apply systemd…"
  wsl.exe --shutdown
  Start-Sleep -Seconds 3
}

# --- 4. verify GPU passthrough into WSL -------------------------------------
Info "checking GPU visibility inside $Distro…"
$gpu = wsl.exe -d $Distro -- bash -lc "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null"
if ([string]::IsNullOrWhiteSpace($gpu)) {
  Warn "nvidia-smi returned nothing inside WSL. Ensure a recent NVIDIA *Windows* driver is"
  Warn "installed (do NOT install a Linux driver inside WSL). Continuing without GPU verify."
} else {
  Info "GPU in WSL: $($gpu.Trim())"
}

# --- 5. run the Linux bootstrap ---------------------------------------------
$bootArgs = ""
if ($GpuTest) { $bootArgs = "--gpu-test" }
Info "running bootstrap-wsl.sh in $RepoPath (installs Docker, CUDA toolkit, conda env)…"
$cmd = "cd $RepoPath && bash env/wsl/bootstrap-wsl.sh $bootArgs"
wsl.exe -d $Distro -- bash -lc "$cmd"
if ($LASTEXITCODE -ne 0) { Fail "bootstrap-wsl.sh failed (exit $LASTEXITCODE). See output above." }

Info "backend setup complete."
Info "Start the control panel service inside WSL, e.g.:"
Info "  wsl -d $Distro -- bash -lc 'cd $RepoPath && conda activate diy-genetics && bash webui/run-webui.sh'"
