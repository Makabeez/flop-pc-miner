<#
  flop-pc-miner - Windows installer / updater (https://github.com/Makabeez/flop-pc-miner, MIT)

  Copies flop-miner.sh and flop-dash.py into the "flop-miner" WSL distro and puts the
  Start / Stop / Status / Update / Dashboard / Widget shortcuts on your Desktop. Run it again any time to update.
  It does not download anything and does not need administrator rights.

  Run from the repo folder, in a normal PowerShell window:
    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
#>
$ErrorActionPreference = 'Stop'
$Distro = 'flop-miner'
$Root   = Split-Path -Parent $PSScriptRoot

function Fail($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# 1. WSL and the dedicated distro
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Fail 'WSL is not installed. Run "wsl --install" in an administrator PowerShell, reboot, then retry.' }
$names = (wsl.exe -l -q) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($names -notcontains $Distro) {
  Write-Host "The '$Distro' WSL distro does not exist yet. Create it first (it asks for a new Linux username and password):" -ForegroundColor Yellow
  Write-Host "  wsl --install Ubuntu-24.04 --name $Distro"
  Write-Host 'Then type "exit" and run this installer again.'
  exit 1
}

# 2. NVIDIA driver on Windows (WSL uses the Windows driver; never install a driver inside Linux)
if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
  nvidia-smi.exe --query-gpu=name,driver_version,memory.total --format=csv,noheader
} else {
  Write-Warning 'nvidia-smi.exe not found: install the latest NVIDIA Game Ready or Studio driver first.'
}

# 3. Copy the Linux scripts into the distro (stdin pipe: works even after "harden" hides C:\ from Linux)
function Copy-ToDistro([string]$Src, [string]$Dest, [string]$Mode) {
  if (-not (Test-Path $Src)) { Fail "missing $Src (run this from the repo folder)" }
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Src))
  $b64 | wsl.exe -d $Distro -- bash -c "tr -d '\r\n' | base64 -d > ~/$Dest && sed -i 's/\r`$//' ~/$Dest && chmod $Mode ~/$Dest && sha1sum ~/$Dest"
  if ($LASTEXITCODE -ne 0) { Fail "could not copy $Dest into $Distro" }
}
Write-Host "`nCopying scripts into $Distro (sha1 of what landed):"
Copy-ToDistro (Join-Path $Root 'flop-miner.sh') 'flop-miner.sh' '755'
Copy-ToDistro (Join-Path $Root 'flop-dash.py')  'flop-dash.py'  '644'

# 4. Desktop shortcuts
$desktop = [Environment]::GetFolderPath('Desktop')
Get-ChildItem (Join-Path $PSScriptRoot 'FLOP Miner - *.cmd') | ForEach-Object {
  Copy-Item $_.FullName (Join-Path $desktop $_.Name) -Force
  Unblock-File (Join-Path $desktop $_.Name)
  Write-Host "  Desktop\$($_.Name)"
}

Write-Host "`nDone. Next (first install only), in PowerShell:" -ForegroundColor Green
Write-Host '  wsl -d flop-miner --cd ~ -- ./flop-miner.sh prereqs'
Write-Host '  wsl --terminate flop-miner'
Write-Host '  wsl -d flop-miner --cd ~ -- ./flop-miner.sh setup'
Write-Host 'Then double-click "FLOP Miner - Start" on your Desktop. Full guide: README.md'
