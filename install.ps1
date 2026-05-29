# install.ps1 — Spotify Widget installer
# Run from the project folder: powershell -ExecutionPolicy Bypass -File install.ps1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile   = Join-Path $ScriptDir "install.log"

function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    $line | Out-File $LogFile -Append -Encoding UTF8
}

function Check-Command($cmd) {
    try { Get-Command $cmd -EA Stop | Out-Null; return $true } catch { return $false }
}

function Step($n, $text) {
    Write-Host ""
    Write-Host "  [$n] $text" -ForegroundColor Cyan
    Write-Host "  $('─' * 48)" -ForegroundColor DarkGray
}

Clear-Host
Write-Host ""
Write-Host "  ╔════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║      Spotify OBS Widget — Installer    ║" -ForegroundColor Green
Write-Host "  ╚════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Log "Install started. Dir=$ScriptDir"

# ── 1. Node.js ────────────────────────────────────────────────────────────────
Step 1 "Checking Node.js"
if (Check-Command "node") {
    $v = node --version 2>&1
    Write-Host "  OK: Node.js $v" -ForegroundColor Green
    Log "Node.js: $v"
} else {
    Write-Host "  ERROR: Node.js not found" -ForegroundColor Red
    Write-Host "  Download: https://nodejs.org" -ForegroundColor Yellow
    Start-Process "https://nodejs.org"
    Read-Host "  Install Node.js then press Enter"
    if (-not (Check-Command "node")) { Log "Node.js missing, abort"; exit 1 }
}

# ── 2. Python ─────────────────────────────────────────────────────────────────
Step 2 "Checking Python"
$PY = @("python","python3") | Where-Object { Check-Command $_ } | Select-Object -First 1
if ($PY) {
    $v = & $PY --version 2>&1
    Write-Host "  OK: $v" -ForegroundColor Green
    Log "Python: $v ($PY)"
} else {
    Write-Host "  ERROR: Python not found" -ForegroundColor Red
    Write-Host "  Download: https://python.org/downloads" -ForegroundColor Yellow
    Start-Process "https://python.org/downloads"
    Read-Host "  Install Python (check 'Add to PATH') then press Enter"
    $PY = @("python","python3") | Where-Object { Check-Command $_ } | Select-Object -First 1
    if (-not $PY) { Log "Python missing, abort"; exit 1 }
}

# ── 3. npm install ────────────────────────────────────────────────────────────
Step 3 "Installing Node.js dependencies (ws)"
Push-Location $ScriptDir
npm install --silent 2>&1 | Out-File $LogFile -Append
Pop-Location
Write-Host "  OK: npm packages installed" -ForegroundColor Green
Log "npm install done"

# ── 4. pip install ────────────────────────────────────────────────────────────
Step 4 "Installing Python dependencies"
$pips = @(
    "pyaudiowpatch",
    "numpy",
    "websocket-client",
    "winrt-Windows.Media.Control",
    "winrt-Windows.Storage.Streams",
    "winrt-Windows.Foundation",
    "winrt-Windows.Foundation.Collections"
)
foreach ($pkg in $pips) {
    Write-Host "  Installing $pkg..." -NoNewline
    & $PY -m pip install $pkg --quiet 2>&1 | Out-File $LogFile -Append
    Write-Host " OK" -ForegroundColor Green
    Log "pip: $pkg"
}

# ── 5. Startup shortcut ───────────────────────────────────────────────────────
Step 5 "Adding to Windows startup"
$vbsSrc  = Join-Path $ScriptDir "run-tray.vbs"
$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$vbsDst  = Join-Path $startup "spotify-widget.vbs"

if (Test-Path $vbsSrc) {
    $vbs = Get-Content $vbsSrc -Raw
    $vbs = $vbs -replace 'ps = ".*"', "ps = `"$(Join-Path $ScriptDir 'widget-tray.ps1')`""
    $vbs | Set-Content $vbsDst -Encoding UTF8
    Write-Host "  OK: Startup shortcut created" -ForegroundColor Green
    Log "Startup: $vbsDst"
} else {
    Write-Host "  SKIP: run-tray.vbs not found" -ForegroundColor DarkGray
}

# ── 6. VB-Audio check ─────────────────────────────────────────────────────────
Step 6 "Checking VB-Audio Virtual Cable (optional, for equalizer)"
$vbResult = & $PY -c "
import sys
try:
    import pyaudiowpatch as pa
    p = pa.PyAudio()
    found = any('CABLE' in p.get_device_info_by_index(i).get('name','') for i in range(p.get_device_count()))
    p.terminate()
    print('found' if found else 'missing')
except: print('error')
" 2>$null

if ($vbResult -eq "found") {
    Write-Host "  OK: VB-Audio Virtual Cable detected" -ForegroundColor Green
    Log "VB-Audio: found"
} else {
    Write-Host "  NOT FOUND: VB-Audio Virtual Cable" -ForegroundColor Yellow
    Write-Host "  Required for equalizer feature" -ForegroundColor DarkGray
    Write-Host "  Download: https://vb-audio.com/Cable/" -ForegroundColor Yellow
    Log "VB-Audio: missing"
    $open = Read-Host "  Open download page? (Y/n)"
    if ($open -ne "n" -and $open -ne "N") {
        Start-Process "https://vb-audio.com/Cable/"
        Write-Host ""
        Write-Host "  After installing VB-Audio:" -ForegroundColor Cyan
        Write-Host "  1. Set CABLE Input as default output in Windows Sound settings" -ForegroundColor White
        Write-Host "  2. In CABLE Output properties -> Listen tab -> Listen to this device -> your headphones" -ForegroundColor White
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║        Installation complete!          ║" -ForegroundColor Green
Write-Host "  ╚════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "  1. Double-click run-tray.vbs  (or reboot — it auto-starts)" -ForegroundColor White
Write-Host "  2. Right-click tray icon -> Start Widget" -ForegroundColor White
Write-Host "  3. In OBS: Browser Source -> http://localhost:8765/widget" -ForegroundColor White
Write-Host "  4. Right-click tray icon -> Start Equalizer  (needs VB-Audio)" -ForegroundColor White
Write-Host ""
Log "Install complete"
Read-Host "  Press Enter to exit"
