<#
============================================================
 AI Gateway Console  (new-api + LiteLLM)
------------------------------------------------------------
 A single menu to start / stop / restart / monitor BOTH
 gateways (new-api on :3000, LiteLLM on :4000) at once.

 WHAT THIS SCRIPT DOES      : manages the two gateway processes
 WHAT THIS SCRIPT DOES NOT  : contain or manage any API keys.
   Real keys live in litellm/config.yaml and your new-api
   database -- keep those OUT of Git (see scripts/.gitignore).

 USAGE
   pwsh -File gateway-console.ps1                 # interactive menu
   pwsh -File gateway-console.ps1 -Action status  # one-shot command
   Actions: status | start | stop | restart |
            startlit | stoplit | startapi | stopapi

 SETUP (edit the CONFIG block below to match your machine)
   1. Install PowerShell 7+ (pwsh). Update $PwshExe if needed.
   2. Put new-api.exe into ./newapi/  and litellm.exe into ./litellm/
   3. Adjust $ApiPort / $LitPort if you use different ports.
============================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('menu', 'status', 'start', 'stop', 'restart', 'startlit', 'stoplit', 'startapi', 'stopapi')]
    [string]$Action = 'menu',
    [switch]$Force,      # skip the confirm prompt on stop (for scripted calls)
    [switch]$NoBrowser   # do not auto-open the web UIs after start
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ==================== CONFIG (edit me) ====================
# Path to PowerShell 7+ executable. Leave as 'pwsh' if it is on PATH.
$PwshExe = 'pwsh'
# Directory that holds new-api.exe
$ApiDirName = 'newapi'
# Directory that holds litellm.exe
$LitDirName = 'litellm'
# Ports the gateways listen on
$ApiPort = 3000
$LitPort = 4000
# Optional: an HTML dashboard file inside the litellm dir to open on start
$LitUiName = '看板.html'
# ==========================================================

$root    = $PSScriptRoot
$litDir  = Join-Path $root $LitDirName
$apiDir  = Join-Path $root $ApiDirName
$litExe  = Join-Path $litDir 'python\Scripts\litellm.exe'
$apiExe  = Join-Path $apiDir 'new-api.exe'
$litUrl  = "http://127.0.0.1:$litPort"
$apiUrl  = "http://127.0.0.1:$apiPort"
$litUi   = Join-Path $litDir $LitUiName

function Test-Port([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); return $true }
    catch { return $false }
    finally { try { $c.Dispose() } catch {} }
}
function Get-PortPid([int]$p) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { return [int]$conn.OwningProcess }
    } catch {}
    return 0
}
function Get-Gw([int]$p) {
    $open = Test-Port $p
    $procId = Get-PortPid $p
    if ($open -and $procId -gt 0) {
        $pr = Get-Process -Id $procId -ErrorAction SilentlyContinue
        return @{ State = 'running'; Pid = $procId; Up = $(if ($pr) { (Get-Date) - $pr.StartTime } else { $null }) }
    }
    if ($open) { return @{ State = 'foreign'; Pid = 0; Up = $null } }
    return @{ State = 'stopped'; Pid = 0; Up = $null }
}
function Format-Up($span) {
    if ($null -eq $span) { return '-' }
    $t = [int]$span.TotalSeconds
    if ($t -lt 60) { return "$t s" }
    if ($t -lt 3600) { return ('{0}m {1}s' -f [int]($t / 60), ($t % 60)) }
    return ('{0}h {1}m' -f [int]($t / 3600), [int](($t % 3600) / 60))
}

# ---------------- new-api ----------------
function Start-Api {
    $st = Get-Gw $apiPort
    if ($st.State -eq 'running') { Write-Host '  new-api already running, skip' -ForegroundColor Yellow; return $true }
    if ($st.State -eq 'foreign') { Write-Host "  port $apiPort used by another program, skip new-api" -ForegroundColor Red; return $false }
    if (-not (Test-Path $apiExe)) { Write-Host "  new-api.exe not found: $apiExe" -ForegroundColor Red; return $false }
    $logDir = Join-Path $apiDir 'data'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Write-Host "  starting new-api (port $apiPort)..." -ForegroundColor Cyan
    Start-Process -FilePath $apiExe `
        -ArgumentList '--port', "$apiPort", '--log-dir', './data/logs' `
        -WorkingDirectory $apiDir -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDir 'stdout.log') `
        -RedirectStandardError (Join-Path $logDir 'stderr.log') | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Port $apiPort) { Write-Host '  [OK] new-api started' -ForegroundColor Green; return $true }
    }
    Write-Host '  [FAIL] new-api start timeout, see newapi\data\stderr.log' -ForegroundColor Red
    return $false
}
function Stop-Api {
    $st = Get-Gw $apiPort
    if ($st.State -eq 'stopped') { Write-Host '  new-api is not running' -ForegroundColor Gray; return }
    if ($st.State -eq 'foreign') { Write-Host "  port $apiPort is not new-api, leaving it alone" -ForegroundColor Red; return }
    & taskkill /F /T /PID $st.Pid 2>&1 | Out-Null
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 300; if (-not (Test-Port $apiPort)) { break } }
    Write-Host '  [OK] new-api stopped' -ForegroundColor Green
}

# ---------------- LiteLLM ----------------
function Start-Lit {
    $st = Get-Gw $litPort
    if ($st.State -eq 'running') { Write-Host '  LiteLLM already running, skip' -ForegroundColor Yellow; return $true }
    if ($st.State -eq 'foreign') { Write-Host "  port $litPort used by another program, skip LiteLLM" -ForegroundColor Red; return $false }
    if (-not (Test-Path $litExe)) { Write-Host "  litellm.exe not found: $litExe" -ForegroundColor Red; return $false }

    $data = Join-Path $litDir 'data'; $tmp = Join-Path $litDir '_tmp'
    foreach ($d in @($data, $tmp)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    $env:PATH          = "$litDir\python;$litDir\python\Scripts;$env:PATH"
    $env:PYTHONUTF8    = '1'
    $env:PIP_CACHE_DIR = "$litDir\_cache"
    $env:TEMP          = "$tmp"
    $env:TMP           = "$tmp"
    $env:NO_PROXY      = '127.0.0.1,localhost,::1'
    $env:no_proxy      = '127.0.0.1,localhost,::1'

    Write-Host "  starting LiteLLM (port $litPort, wait up to 90s)..." -ForegroundColor Cyan
    Start-Process -FilePath $litExe `
        -ArgumentList '--config', 'config.yaml', '--host', '127.0.0.1', '--port', "$litPort" `
        -WorkingDirectory $litDir -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $data 'stdout.log') `
        -RedirectStandardError (Join-Path $data 'stderr.log') | Out-Null
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Port $litPort) { Write-Host '  [OK] LiteLLM started' -ForegroundColor Green; return $true }
    }
    Write-Host '  [FAIL] LiteLLM start timeout, see litellm\data\stderr.log' -ForegroundColor Red
    return $false
}
function Stop-Lit {
    $st = Get-Gw $litPort
    if ($st.State -eq 'stopped') { Write-Host '  LiteLLM is not running' -ForegroundColor Gray; return }
    if ($st.State -eq 'foreign') { Write-Host "  port $litPort is not LiteLLM, leaving it alone" -ForegroundColor Red; return }
    & taskkill /F /T /PID $st.Pid 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 300; if (-not (Test-Port $litPort)) { break } }
    Write-Host '  [OK] LiteLLM stopped' -ForegroundColor Green
}

# ---------------- combined actions ----------------
function Start-All {
    Write-Host ''
    Write-Host '  -- start all gateways --' -ForegroundColor DarkCyan
    $okApi = Start-Api
    $okLit = Start-Lit            # new-api first: LiteLLM forwards to :3000
    Write-Host ''
    if ($okApi -and $okLit -and -not $NoBrowser) {
        if (Test-Path $litUi) { Start-Process $litUi }
        Start-Process $apiUrl
        Write-Host '  opened new-api console and LiteLLM dashboard' -ForegroundColor Green
    }
    Show-Status
}
function Stop-All {
    Write-Host ''
    Write-Host '  -- stop all gateways --' -ForegroundColor DarkCyan
    if (-not $Force) {
        Write-Host '  note: in-flight model requests will be interrupted.' -ForegroundColor DarkYellow
        $ans = Read-Host '  confirm stop all? type y + Enter'
        if ($ans -notmatch '^(y|Y|yes)$') { Write-Host '  cancelled, nothing changed' -ForegroundColor Gray; return }
    }
    Stop-Lit
    Stop-Api
    Write-Host ''
    Show-Status
}
function Restart-All { Stop-All; Start-Sleep -Seconds 1; Start-All }

function Show-Status {
    $a = Get-Gw $apiPort
    $l = Get-Gw $litPort
    $fmt = {
        param($name, $port, $st, $url)
        $txt = switch ($st.State) { 'running' { '* running ' } 'foreign' { '! port busy' } default { 'o stopped ' } }
        $col = switch ($st.State) { 'running' { 'Green' } 'foreign' { 'Red' } default { 'Gray' } }
        $extra = if ($st.State -eq 'running') { "pid=$($st.Pid)  up $(Format-Up $st.Up)" } else { '' }
        Write-Host ('   {0,-10} port {1,-5} {2}  {3}' -f $name, $port, $txt, $extra) -ForegroundColor $col
        Write-Host ("              url $url") -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  -- current status --' -ForegroundColor DarkCyan
    & $fmt 'new-api' $apiPort $a $apiUrl
    & $fmt 'LiteLLM' $litPort $l $litUrl
}

function Show-Logs {
    $pairs = @(
        @{ t = 'LiteLLM console.log (last 10)'; f = (Join-Path $litDir 'data\console.log'); n = 10 },
        @{ t = 'LiteLLM stderr.log (errors)';   f = (Join-Path $litDir 'data\stderr.log'); n = 12 },
        @{ t = 'new-api start.log (last 10)';   f = (Join-Path $apiDir 'data\start.log'); n = 10 },
        @{ t = 'new-api stderr.log';            f = (Join-Path $apiDir 'data\stderr.log'); n = 12 }
    )
    foreach ($p in $pairs) {
        Write-Host ''
        Write-Host ("  -- {0} --" -f $p.t) -ForegroundColor DarkCyan
        if ((Test-Path $p.f) -and (Get-Item $p.f).Length -gt 0) {
            Get-Content $p.f -Tail $p.n | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else { Write-Host '  (empty / not created yet)' -ForegroundColor DarkGray }
    }
}

function Invoke-Selftest {
    $py = Join-Path $litDir 'python\python.exe'
    $sc = Join-Path $litDir 'check.py'
    if (-not (Test-Path $sc)) { Write-Host '  check.py not found' -ForegroundColor Red; return }
    $env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'
    & $py $sc
    Write-Host ''
    Write-Host '  (selftest calls models for real; free models cost nothing)' -ForegroundColor DarkGray
}

function Open-Originals {
    Write-Host ''
    Write-Host '  [1] LiteLLM original console (start/stop/restart/dashboard/logs/selftest)' -ForegroundColor White
    Write-Host '  [2] new-api original launcher (foreground window, closes with window)' -ForegroundColor White
    Write-Host '  [3] new-api silent start (background, no window)' -ForegroundColor White
    Write-Host '  [0] back' -ForegroundColor DarkGray
    $c = Read-Host '  select'
    switch ($c) {
        '1' { $litCmd = Join-Path $litDir 'LiteLLM.cmd'; if (Test-Path $litCmd) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', "`"$litCmd`"" } }
        '2' { $apiCmd = Join-Path $apiDir '启动NewAPI.cmd'; if (Test-Path $apiCmd) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', "`"$apiCmd`"" } }
        '3' { $silent = Join-Path $apiDir 'start_silent.ps1'; if (Test-Path $silent) { & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $silent } }
    }
}

function Show-Menu {
    try { Clear-Host } catch {}
    Write-Host ''
    Write-Host '  ======  AI Gateway Console (new-api + LiteLLM)  ======' -ForegroundColor DarkCyan
    Show-Status
    Write-Host ''
    Write-Host '   [1] Start all (:3000 + :4000)' -ForegroundColor White
    Write-Host '   [2] Stop all' -ForegroundColor White
    Write-Host '   [3] Restart all' -ForegroundColor White
    Write-Host '   [4] Open both web UIs (console + dashboard)' -ForegroundColor White
    Write-Host '   [5] View logs (both)' -ForegroundColor White
    Write-Host '   [6] LiteLLM selftest (test models + rate)' -ForegroundColor White
    Write-Host '   [7] Original script entries (full legacy features)' -ForegroundColor White
    Write-Host '   [0] Exit menu (services keep running)' -ForegroundColor DarkGray
    Write-Host ''
}

if ($Action -ne 'menu') {
    switch ($Action) {
        'status'   { Show-Status }
        'start'    { Start-All }
        'stop'     { Stop-All }
        'restart'  { Restart-All }
        'startlit' { Start-Lit; Show-Status }
        'stoplit'  { Stop-Lit; Show-Status }
        'startapi' { Start-Api; Show-Status }
        'stopapi'  { Stop-Api; Show-Status }
    }
    exit 0
}

$quit = $false
while (-not $quit) {
    Show-Menu
    $choice = Read-Host '   select'
    switch ($choice) {
        '1' { Start-All }
        '2' { Stop-All }
        '3' { Restart-All }
        '4' {
            if (Test-Path $litUi) { Start-Process $litUi }
            Start-Process $apiUrl
            Write-Host '  opened' -ForegroundColor Green
        }
        '5' { Show-Logs }
        '6' { Invoke-Selftest }
        '7' { Open-Originals }
        '0' { $quit = $true }
        default { Write-Host '  no such option, enter 0-7' -ForegroundColor Yellow }
    }
    if (-not $quit) { Write-Host ''; Read-Host '  press Enter to return to menu' | Out-Null }
}
Write-Host ''
Write-Host '  menu closed. check the status lines above for whether gateways are up.' -ForegroundColor DarkGray
Start-Sleep -Seconds 2
