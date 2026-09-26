# diagnose.ps1 -- Windows port of ssh/diagnose.sh.
#
#   powershell -ExecutionPolicy Bypass -File windows\diagnose.ps1
#
# Walks the path from this machine to the model, stops at the first layer
# that fails, and prints what to do about it. Reads ssh\lp0-bridge.env for
# host, user, key and forward, and LP0_API_KEY from the environment.

$ErrorActionPreference = 'SilentlyContinue'

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }
function Verdict($what, $fix) {
    Write-Host ""
    Write-Host "VERDICT: $what" -ForegroundColor White
    if ($fix) { Write-Host "FIX:     $fix" -ForegroundColor Yellow }
    exit 0
}

# --- config ---------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $repoRoot 'ssh\lp0-bridge.env'
if (-not (Test-Path $envFile)) { Bad "no config at $envFile"; exit 1 }
$cfg = @{}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $pair = $line -split '=', 2
    $cfg[$pair[0].Trim()] = ($pair[1].Trim().Trim('"') -replace '\$HOME', $env:USERPROFILE)
}
$lp0Host  = $cfg['LP0_HOST']
$user     = $cfg['LP0_USER']
$port     = if ($cfg['LP0_PORT']) { $cfg['LP0_PORT'] } else { '22' }
$identity = if ($cfg['LP0_IDENTITY']) { $cfg['LP0_IDENTITY'] } else { Join-Path $env:USERPROFILE '.ssh\id_lp0' }
$fwd      = ($cfg['LP0_LOCAL_FORWARDS'] -split '\s+')[0]
$parts    = $fwd -split ':'
if ($parts.Count -eq 4) { $localPort = $parts[1]; $remoteHost = $parts[2] } else { $localPort = $parts[0]; $remoteHost = $parts[1] }
$remotePort = $parts[-1]
$key = if ($env:LP0_API_KEY) { $env:LP0_API_KEY } elseif ($env:OPENAI_API_KEY) { $env:OPENAI_API_KEY } else { 'not-needed' }
$sshBase = @('-i', $identity, '-p', $port, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'IdentitiesOnly=yes', "$user@$lp0Host")

$ts = (Get-Command tailscale).Source
if (-not $ts -and (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) { $ts = 'C:\Program Files\Tailscale\tailscale.exe' }

Write-Host "lp0 bridge diagnosis  (localhost:$localPort -> $user@$lp0Host, forward $localPort -> ${remoteHost}:$remotePort)" -ForegroundColor White
Write-Host ""

# --- 1. the endpoint itself -----------------------------------------------
$code = 0
try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 -Headers @{ Authorization = "Bearer $key" } "http://localhost:$localPort/v1/models"
    $code = [int]$r.StatusCode
} catch {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
}
switch ($code) {
    200 { Ok "model answers on localhost:$localPort"
          Verdict "everything works. If an app says otherwise, it has the wrong URL, key, or model name." $null }
    { $_ -eq 401 -or $_ -eq 403 } {
          Bad "endpoint reachable but rejected the API key (HTTP $code)"
          Verdict "tunnel and server are fine; the key is wrong or missing." '$env:LP0_API_KEY = "<the key vLLM was started with>"' }
    0   { Bad "nothing answering on localhost:$localPort" }
    default { Bad "endpoint returned HTTP $code"; Note "server is up but unhealthy -- check vLLM's logs on the box" }
}

# --- 2. is the tunnel holding the local port? ------------------------------
$listener = Get-NetTCPConnection -LocalPort $localPort -State Listen | Select-Object -First 1
$tunnelUp = $false
if ($listener -and (Get-Process -Id $listener.OwningProcess).ProcessName -match 'ssh') {
    Ok "ssh is listening on localhost:$localPort (tunnel is up)"; $tunnelUp = $true
} else {
    Bad "no ssh listener on localhost:$localPort (tunnel is down or still connecting)"
    $task = Get-ScheduledTask -TaskName lp0-bridge
    if ($task) { Note "scheduled task 'lp0-bridge' state: $($task.State)" } else { Note "scheduled task 'lp0-bridge' is not installed (windows\install-task.ps1)" }
}

# --- 3. network reach ------------------------------------------------------
if ($ts) {
    $line = (& $ts status 2>$null) | Select-String -SimpleMatch $lp0Host | Select-Object -First 1
    if (-not $line) {
        Bad "$lp0Host is not in your Tailscale device list"
        Verdict "Tailscale is off, signed into the wrong account, or the share is gone." "open the Tailscale tray icon; confirm it's connected and signed into the same account as your other devices"
    } elseif ("$line" -match 'offline') {
        Bad "Tailscale reports the server offline: $(("$line" -split 'offline')[1].Trim())"
        Verdict "THE SERVER is off the network -- powered off, asleep, rebooting, or its Tailscale stopped. Nothing on this machine can fix it." "power/network check on the box; once it's back the bridge reconnects by itself"
    } else { Ok "Tailscale sees $lp0Host" }
    & $ts ping -c 2 --timeout 4s $lp0Host *> $null
    if ($LASTEXITCODE -eq 0) { Ok "tailscale ping answers" }
    else {
        Bad "tailscale ping gets no reply"
        Verdict "the server is on the list but not answering -- usually mid-reboot or a cold relay path." "wait 30s and rerun; if it persists, the box itself needs attention"
    }
}

# --- 4. the ssh door -------------------------------------------------------
if (Test-NetConnection -ComputerName $lp0Host -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) {
    Ok "port $port (ssh) is open"
} else {
    Bad "port $port (ssh) does not answer"
    Verdict "network reaches the box but sshd isn't answering -- sshd stopped, or a firewall/ACL change." "on the box: sudo systemctl status ssh; or run 'tailscale ping $lp0Host' first to warm the path and rerun"
}

# --- 5. authentication -----------------------------------------------------
& ssh @sshBase true *> $null
if ($LASTEXITCODE -eq 0) { Ok "key authentication works" }
else {
    Bad "ssh refused the key"
    Verdict "reach is fine; your key is no longer accepted by $user@$lp0Host." "check ~/.ssh/authorized_keys on the box; reinstall the key if needed (see windows\README.md)"
}

# --- 6. the model service on the far side ----------------------------------
$remoteCmd = "curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $key' http://${remoteHost}:$remotePort/v1/models; echo; docker ps --filter status=running --format '{{.Names}}' 2>/dev/null | grep -c . ; docker ps --filter status=running --format '{{.Names}}' 2>/dev/null | tr '\n' ' '"
$remote = & ssh @sshBase $remoteCmd 2>$null
$rcode = "$($remote | Select-Object -Index 0)".Trim()
$containers = "$($remote | Select-Object -Index 1)".Trim()
$names = "$($remote | Select-Object -Index 2)".Trim()
switch ($rcode) {
    '200' { Ok "vLLM answers on the server at ${remoteHost}:$remotePort"
            if ($tunnelUp) { Verdict "server and vLLM are healthy but the tunnel isn't delivering -- stale ssh session." "Restart-ScheduledTask -TaskName lp0-bridge" }
            else { Verdict "server and vLLM are healthy; only the local tunnel is down." "Start-ScheduledTask -TaskName lp0-bridge   (or: powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1)" } }
    { $_ -eq '401' -or $_ -eq '403' } {
            Ok "vLLM is up on the server (it rejected the key: HTTP $rcode)"
            Verdict "vLLM requires an API key you haven't set." '$env:LP0_API_KEY = "<key>"' }
    default {
            Bad "vLLM is NOT answering on the server at ${remoteHost}:$remotePort (running containers: ${containers}: $names)"
            Verdict "THE MODEL SERVICE IS DOWN on the box -- the container/process died and nothing restarted it. The tunnel is fine." "on the box: docker ps -a  -- then restart the vLLM container. See server\README.md for making it restart itself." }
}
