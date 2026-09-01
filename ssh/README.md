# SSH bridge to lp0

Holds a persistent SSH connection to `lp0` and forwards ports across it,
reconnecting on its own when the link drops.

Everything host-specific lives in `lp0-bridge.env`, which is gitignored.
No hostname, username, or key material is committed.

## Setup

**1. Fill in your settings**

```sh
cp ssh/lp0-bridge.env.example ssh/lp0-bridge.env
$EDITOR ssh/lp0-bridge.env          # set LP0_HOST, LP0_USER, forwards
```

**2. Create a key and install it on lp0**

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_lp0 -C lp0-bridge
ssh-copy-id -i ~/.ssh/id_lp0.pub -p 22 your-username@lp0.example.internal
```

Leave the passphrase empty, or the unattended service cannot use the key.
If you want a passphrase, add the key to an agent (`ssh-add ~/.ssh/id_lp0`)
and drop `BatchMode=yes` from `lp0-bridge.sh` — the bridge will then depend
on that agent being unlocked.

**3. Accept lp0's host key once, by hand**

```sh
ssh -i ~/.ssh/id_lp0 -p 22 your-username@lp0.example.internal true
```

This matters. The bridge runs with `BatchMode=yes`, which means ssh will
*refuse* to connect to a host whose key is not already in `known_hosts`
rather than prompting. Skipping this step produces a bridge that retries
forever with `Host key verification failed`. Verify the fingerprint against
lp0 itself the first time — that check is the whole point of the prompt.

**4. Test the configuration**

```sh
./ssh/lp0-bridge.sh check     # proves config + key auth, then exits
./ssh/lp0-bridge.sh args      # prints the exact ssh command it will run
```

**5. Run it**

Foreground, to watch it work:

```sh
./ssh/lp0-bridge.sh up
```

As a background service, see the header comments in
`../systemd/lp0-bridge.service` (Linux) or `../launchd/com.lp0.bridge.plist`
(macOS). Both take `%REPO%` substitution for this checkout's path.

Install `autossh` if you can (`apt install autossh` / `brew install autossh`).
The script uses it automatically and falls back to its own retry loop with
exponential backoff otherwise.

## Configuring forwards

`LP0_LOCAL_FORWARDS` reaches services **on lp0** from this machine. With
`127.0.0.1:8022:localhost:22`, `ssh -p 8022 localhost` lands on lp0's own
SSH daemon.

`LP0_REMOTE_FORWARDS` exposes services on **this** machine to lp0. With
`9000:localhost:3000`, lp0 reaches your local port 3000 via its own port
9000. Note that lp0's `sshd` binds these to its loopback unless
`GatewayPorts` is enabled in its `sshd_config`.

`LP0_SOCKS_PORT` opens a SOCKS5 proxy, letting a browser route traffic
through lp0's network without per-port forwards.

Keep the `127.0.0.1:` prefix on local forwards unless you deliberately want
other machines on your LAN to reach the forwarded port — without it, ssh
binds the port on all interfaces.

## Reaching the vLLM server on lp0

lp0 serves its model through vLLM's OpenAI-compatible server (`vllm serve`),
which listens on port 8000 unless started with `--port`. The example forward
`127.0.0.1:8000:localhost:8000` carries it across the bridge, so clients on
this machine use `http://localhost:8000/v1` exactly as if vLLM were running
locally:

```sh
curl http://localhost:8000/v1/models     # sanity check: lists the loaded model
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "<id from /v1/models>",
       "messages": [{"role": "user", "content": "hello"}]}'
```

Any OpenAI-compatible client works the same way — set its base URL to
`http://localhost:8000/v1`. Unless vLLM was started with `--api-key`, it
accepts any key (or none) — so once vLLM is bound to loopback (below), the
tunnel is the only access control.

Two things on lp0's side:

- vLLM binds all interfaces by default, which exposes an unauthenticated
  model server to lp0's whole network. Start it with `--host 127.0.0.1` so
  the bridge is the only way in — the forward still reaches it, because the
  `localhost:8000` half of the `-L` spec is resolved on lp0 itself, not
  here.
- If vLLM runs on a non-default port, change **both** port numbers in the
  forward to match (or only the right-hand one, if you want the local port
  to stay 8000).

## Windows

On a Windows machine, use the PowerShell port in `../windows/` instead of
the bash script — same config file, same behavior, Task Scheduler as the
background service. Full walkthrough: `../windows/README.md`.

## Interactive access

`config.lp0.example` is a separate `~/.ssh/config` entry giving you
`ssh lp0`, `scp`, and `rsync` against the same host, with connection
multiplexing so repeat sessions are instant. The bridge daemon does not
read it — it builds its arguments from `lp0-bridge.env` — so the two cannot
silently drift apart.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Host key verification failed` | Step 3 was skipped. |
| `Permission denied (publickey)` | Public key is not in lp0's `~/.ssh/authorized_keys`, or that file's permissions are too open (needs `600`, and `700` on `~/.ssh`). |
| `bind: Address already in use` | Something already holds the local port. `ExitOnForwardFailure=yes` makes this fail loudly rather than leaving a bridge up with no working forward. |
| Bridge is up but the port is dead | The service on lp0 is not listening, or is bound to an interface the forward's `remote_host` does not name. |
| Reconnects every few minutes | A firewall is dropping idle flows; lower `LP0_ALIVE_INTERVAL`. |
