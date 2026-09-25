#!/usr/bin/env bash
#
# diagnose.sh — find which layer of the lp0 bridge is broken, in one run.
#
#   ./ssh/diagnose.sh
#
# Walks the path from your machine to the model, stops at the first layer
# that fails, and prints what to do about it. Reads ssh/lp0-bridge.env for
# the host, user, key and forward, and LP0_API_KEY from the environment.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${LP0_BRIDGE_ENV:-$SCRIPT_DIR/lp0-bridge.env}"

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
verdict() { printf '\n\033[1mVERDICT:\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '\033[1mFIX:\033[0m     %s\n' "$2"; exit 0; }

# --- config ---------------------------------------------------------------
[[ -f "$ENV_FILE" ]] || { bad "no config at $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a
: "${LP0_HOST:?}" "${LP0_USER:?}"
LP0_PORT="${LP0_PORT:-22}"
LP0_IDENTITY="${LP0_IDENTITY:-$HOME/.ssh/id_lp0}"
FWD="${LP0_LOCAL_FORWARDS%% *}"                  # first forward only
LOCAL_PORT="$(echo "$FWD" | awk -F: '{print (NF==4)?$2:$1}')"
REMOTE_HOST="$(echo "$FWD" | awk -F: '{print (NF==4)?$3:$2}')"
REMOTE_PORT="$(echo "$FWD" | awk -F: '{print $NF}')"
KEY="${LP0_API_KEY:-${OPENAI_API_KEY:-not-needed}}"
SSH=(ssh -i "$LP0_IDENTITY" -p "$LP0_PORT" -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes "$LP0_USER@$LP0_HOST")

TS="$(command -v tailscale || ls /Applications/Tailscale.app/Contents/MacOS/Tailscale 2>/dev/null || true)"

printf '\033[1mlp0 bridge diagnosis\033[0m  (%s → %s@%s, forward %s→%s:%s)\n\n' \
  "localhost:$LOCAL_PORT" "$LP0_USER" "$LP0_HOST" "$LOCAL_PORT" "$REMOTE_HOST" "$REMOTE_PORT"

# --- 1. the endpoint itself -----------------------------------------------
code="$(curl -s -m 6 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "http://localhost:$LOCAL_PORT/v1/models" 2>/dev/null || true)"
[[ "$code" =~ ^[0-9]{3}$ ]] || code=000
case "$code" in
  200) ok "model answers on localhost:$LOCAL_PORT"
       verdict "everything works. If an app says otherwise, it has the wrong URL, key, or model name." ;;
  401|403) bad "endpoint reachable but rejected the API key (HTTP $code)"
       verdict "tunnel and server are fine; the key is wrong or missing." "export LP0_API_KEY=<the key vLLM was started with>" ;;
  000) bad "nothing answering on localhost:$LOCAL_PORT" ;;
  *)   bad "endpoint returned HTTP $code"; note "server is up but unhealthy — check vLLM's logs on the box" ;;
esac

# --- 2. is the tunnel holding the local port? ------------------------------
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null | grep -q ssh; then
  ok "ssh is listening on localhost:$LOCAL_PORT (tunnel is up)"
  tunnel_up=1
else
  bad "no ssh listener on localhost:$LOCAL_PORT (tunnel is down or still connecting)"
  tunnel_up=0
fi

# --- 3. network reach ------------------------------------------------------
if [[ -n "$TS" ]]; then
  line="$("$TS" status 2>/dev/null | grep -F "$LP0_HOST" || true)"
  if [[ -z "$line" ]]; then
    bad "$LP0_HOST is not in your Tailscale device list"
    verdict "Tailscale is off, logged into the wrong account, or the share is gone." "open the Tailscale app, confirm it's on and signed into the same account as your other devices"
  elif echo "$line" | grep -q offline; then
    bad "Tailscale reports the server offline: $(echo "$line" | grep -o 'offline.*')"
    verdict "THE SERVER is off the network — powered off, asleep, rebooting, or its Tailscale stopped. Nothing on this machine can fix it." "power/network check on the box; once it's back the bridge reconnects by itself"
  else
    ok "Tailscale sees $LP0_HOST"
  fi
  if "$TS" ping -c 2 --timeout 4s "$LP0_HOST" >/dev/null 2>&1; then
    ok "tailscale ping answers"
  else
    bad "tailscale ping gets no reply"
    verdict "the server is on the list but not answering — usually mid-reboot or a cold relay path." "wait 30s and rerun; if it persists, the box itself needs attention"
  fi
fi

# --- 4. the ssh door -------------------------------------------------------
if nc -z -G 6 "$LP0_HOST" "$LP0_PORT" 2>/dev/null || nc -z -w 6 "$LP0_HOST" "$LP0_PORT" 2>/dev/null; then
  ok "port $LP0_PORT (ssh) is open"
else
  bad "port $LP0_PORT (ssh) does not answer"
  verdict "network reaches the box but sshd isn't answering — sshd stopped, or a firewall/ACL change." "on the box: sudo systemctl status ssh; or run 'tailscale ping $LP0_HOST' first to warm the path and rerun"
fi

# --- 5. authentication -----------------------------------------------------
if "${SSH[@]}" true 2>/dev/null; then
  ok "key authentication works"
else
  bad "ssh refused the key"
  verdict "reach is fine; your key is no longer accepted by $LP0_USER@$LP0_HOST." "check ~/.ssh/authorized_keys on the box; reinstall with ssh-copy-id if needed"
fi

# --- 6. the model service on the far side ----------------------------------
remote="$("${SSH[@]}" "curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $KEY' http://$REMOTE_HOST:$REMOTE_PORT/v1/models; echo; docker ps --filter status=running --format '{{.Names}}' 2>/dev/null | grep -c . ; ps aux | grep -c '[v]llm serve'" 2>/dev/null || true)"
rcode="$(echo "$remote" | sed -n 1p)"; containers="$(echo "$remote" | sed -n 2p)"; procs="$(echo "$remote" | sed -n 3p)"
case "$rcode" in
  200) ok "vLLM answers on the server at $REMOTE_HOST:$REMOTE_PORT"
       if (( tunnel_up )); then
         verdict "server and vLLM are healthy but the tunnel isn't delivering — stale ssh session." "restart the bridge service: launchctl kickstart -k gui/\$(id -u)/com.lp0.bridge   (Linux: systemctl --user restart lp0-bridge)"
       else
         verdict "server and vLLM are healthy; only the local tunnel is down." "launchctl kickstart -k gui/\$(id -u)/com.lp0.bridge   or   ./ssh/lp0-bridge.sh up"
       fi ;;
  401|403) ok "vLLM is up on the server (it rejected the key: HTTP $rcode)"
       verdict "vLLM requires an API key you haven't set." "export LP0_API_KEY=<key>" ;;
  *)   bad "vLLM is NOT answering on the server at $REMOTE_HOST:$REMOTE_PORT (running containers: ${containers:-?}, vllm processes: ${procs:-?})"
       verdict "THE MODEL SERVICE IS DOWN on the box — the container/process died and nothing restarted it. The tunnel is fine." "on the box: docker ps -a  — then restart the vLLM container. See server/README.md for making it restart itself." ;;
esac
