# lp0-bridge.ps1 -- Windows port of ssh/lp0-bridge.sh.
#
# Reads the same config file (ssh\lp0-bridge.env), builds the same ssh
# command, and holds the tunnel open with a retry loop. Runs until stopped.
#
#   powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1        start
#   powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1 check  test auth only
#
# Requires the built-in OpenSSH client (Windows 10/11: Settings ->
# Optional features -> OpenSSH Client if `ssh -V` says not found).

param([string]$Action = 'up')

$ErrorActionPreference = 'Stop'

function Log([string]$msg) {
    Write-Host ("{0} lp0-bridge: {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $msg)
}
function Die([string]$msg) { Log ("error: " + $msg); exit 1 }

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Die "ssh not found. Install it: Settings -> System -> Optional features -> Add -> OpenSSH Client"
}

# --- Load ssh\lp0-bridge.env (same file the bash script uses) -------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $repoRoot 'ssh\lp0-bridge.env'
if (-not (Test-Path $envFile)) {
    Die ("no config found. Copy ssh\lp0-bridge.env.example to ssh\lp0-bridge.env and fill it in.")
}
Log ("using config " + $envFile)

$cfg = @{}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $pair = $line -split '=', 2
    $val = $pair[1].Trim().Trim('"')
    $val = $val -replace '\$HOME', $env:USERPROFILE   # example file uses $HOME
    $cfg[$pair[0].Trim()] = $val
}

$lp0Host  = $cfg['LP0_HOST']
$user     = $cfg['LP0_USER']
$port     = if ($cfg['LP0_PORT'])     { $cfg['LP0_PORT'] }     else { '22' }
$identity = if ($cfg['LP0_IDENTITY']) { $cfg['LP0_IDENTITY'] } else { Join-Path $env:USERPROFILE '.ssh\id_lp0' }
$aliveInt = if ($cfg['LP0_ALIVE_INTERVAL'])  { $cfg['LP0_ALIVE_INTERVAL'] }  else { '30' }
$aliveMax = if ($cfg['LP0_ALIVE_COUNT_MAX']) { $cfg['LP0_ALIVE_COUNT_MAX'] } else { '3' }

if (-not $lp0Host) { Die "LP0_HOST must be set" }
if (-not $user)    { Die "LP0_USER must be set" }
if ($lp0Host -like '*example*') { Die ("LP0_HOST is still the placeholder (" + $lp0Host + "). Set it to lp0's real address.") }
if (-not (Test-Path $identity)) { Die ("identity file not found: " + $identity + " (generate one with: ssh-keygen -t ed25519 -f `"" + $identity + "`" -C lp0-bridge)") }

# --- Build the ssh argument list -----------------------------------------
$sshArgs = @(
    '-N', '-T',
    '-p', $port,
    '-i', $identity,
    '-o', 'IdentitiesOnly=yes',
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', ('ServerAliveInterval=' + $aliveInt),
    '-o', ('ServerAliveCountMax=' + $aliveMax),
    '-o', 'TCPKeepAlive=yes'
)
if ($cfg['LP0_JUMP']) { $sshArgs += @('-J', $cfg['LP0_JUMP']) }

$nForwards = 0
foreach ($f in (($cfg['LP0_LOCAL_FORWARDS'] -split '\s+') | Where-Object { $_ })) {
    $sshArgs += @('-L', $f); $nForwards++
}
foreach ($f in (($cfg['LP0_REMOTE_FORWARDS'] -split '\s+') | Where-Object { $_ })) {
    $sshArgs += @('-R', $f); $nForwards++
}
if ($cfg['LP0_SOCKS_PORT']) { $sshArgs += @('-D', $cfg['LP0_SOCKS_PORT']); $nForwards++ }

$target = $user + '@' + $lp0Host

if ($Action -eq 'check') {
    Log ("testing authentication to " + $target + ":" + $port)
    & ssh -p $port -i $identity -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 $target 'echo ok'
    if ($LASTEXITCODE -eq 0) { Log "ok -- key authentication to lp0 succeeded" }
    else { Die ("could not authenticate. Is the public key (" + $identity + ".pub) in the server's ~/.ssh/authorized_keys?") }
    exit 0
}

if ($nForwards -eq 0) {
    Die "no forwards configured -- set at least one of LP0_LOCAL_FORWARDS, LP0_REMOTE_FORWARDS, or LP0_SOCKS_PORT"
}
$sshArgs += $target

# --- Hold the tunnel open, retry with backoff ----------------------------
$delay = 2
while ($true) {
    Log ("connecting to " + $target + ":" + $port)
    $started = Get-Date
    & ssh @sshArgs
    $ran = [int]((Get-Date) - $started).TotalSeconds

    if ($ran -gt 60) {
        $delay = 2
        Log ("connection dropped after " + $ran + "s; reconnecting")
    } else {
        Log ("connection failed after " + $ran + "s; retrying in " + $delay + "s")
    }
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, 60)
}
