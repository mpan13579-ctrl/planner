# lp0 bridge on Windows

Windows port of the bridge: same `ssh/lp0-bridge.env` config file, same
behavior, but PowerShell instead of bash and Task Scheduler instead of
launchd/systemd. Uses Windows' built-in OpenSSH client — nothing to
install besides Tailscale (and git to clone this repo).

All commands below run in **PowerShell** (Start menu → type "powershell").

## Setup

**1. Prerequisites**

- Tailscale for Windows (tailscale.com/download), signed in to the same
  account as your other devices, toggled on.
- SSH: run `ssh -V`. If not found: Settings → System → Optional features →
  Add a feature → **OpenSSH Client**.

**2. Key**

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_lp0 -C lp0-bridge-minipc
```

Enter twice for an empty passphrase. Windows has no `ssh-copy-id`; install
the key with one line (answer `yes` to the fingerprint, then type the
account password — replace USER and HOST):

```powershell
type $env:USERPROFILE\.ssh\id_lp0.pub | ssh USER@HOST "cat >> ~/.ssh/authorized_keys"
```

Prove it worked (no password prompt this time):

```powershell
ssh -i $env:USERPROFILE\.ssh\id_lp0 USER@HOST echo ok
```

**3. Configure** — from the repo root:

```powershell
copy ssh\lp0-bridge.env.example ssh\lp0-bridge.env
notepad ssh\lp0-bridge.env
```

Set `LP0_HOST`, `LP0_USER`, and the forwards, exactly as on any other OS.
The `$HOME` in `LP0_IDENTITY` is translated to your Windows profile folder
automatically.

**4. Run**

```powershell
powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1 check
powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1
```

Test from a second PowerShell window (`curl.exe`, not plain `curl`, which
Windows aliases to something else):

```powershell
curl.exe http://localhost:8000/v1/models
```

**5. Background service** — starts at logon, restarts on failure, no window:

```powershell
powershell -ExecutionPolicy Bypass -File windows\install-task.ps1
```

Remove later with
`Unregister-ScheduledTask -TaskName lp0-bridge -Confirm:$false`.

## Notes

- `-ExecutionPolicy Bypass` is needed because Windows blocks unsigned
  PowerShell scripts by default; passing it per-command avoids changing
  the machine-wide policy.
- The forwarded port binds to `127.0.0.1`, so a Windows Firewall prompt
  should not appear; if one does, it concerns ssh.exe listening locally —
  allowing it on private networks is fine.
