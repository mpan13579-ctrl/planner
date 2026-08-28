#!/usr/bin/env bash
#
# lp0-bridge.sh — open an SSH bridge to lp0 and hold it open.
#
# Runs in the foreground and does not return until stopped, so it can be
# supervised directly by systemd or launchd. If autossh is installed it is
# used; otherwise the script retries ssh itself with exponential backoff.
#
#   ./lp0-bridge.sh up       start the bridge (default)
#   ./lp0-bridge.sh check    verify config and authentication, then exit
#   ./lp0-bridge.sh args     print the ssh command that would run
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s lp0-bridge: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- Configuration -------------------------------------------------------

load_config() {
  local env_file="${LP0_BRIDGE_ENV:-}"

  if [[ -z "$env_file" ]]; then
    for candidate in "$SCRIPT_DIR/lp0-bridge.env" "$HOME/.config/lp0-bridge/env"; do
      [[ -f "$candidate" ]] && { env_file="$candidate"; break; }
    done
  fi

  [[ -n "$env_file" ]] || die "no config found. Copy $SCRIPT_DIR/lp0-bridge.env.example to $SCRIPT_DIR/lp0-bridge.env and fill it in."
  [[ -f "$env_file" ]] || die "config file not found: $env_file"

  log "using config $env_file"
  # shellcheck disable=SC1090
  set -a; source "$env_file"; set +a

  : "${LP0_HOST:?LP0_HOST must be set}"
  : "${LP0_USER:?LP0_USER must be set}"
  LP0_PORT="${LP0_PORT:-22}"
  LP0_IDENTITY="${LP0_IDENTITY:-$HOME/.ssh/id_lp0}"
  LP0_JUMP="${LP0_JUMP:-}"
  LP0_LOCAL_FORWARDS="${LP0_LOCAL_FORWARDS:-}"
  LP0_REMOTE_FORWARDS="${LP0_REMOTE_FORWARDS:-}"
  LP0_SOCKS_PORT="${LP0_SOCKS_PORT:-}"
  LP0_ALIVE_INTERVAL="${LP0_ALIVE_INTERVAL:-30}"
  LP0_ALIVE_COUNT_MAX="${LP0_ALIVE_COUNT_MAX:-3}"
  LP0_RETRY_MIN="${LP0_RETRY_MIN:-2}"
  LP0_RETRY_MAX="${LP0_RETRY_MAX:-60}"

  if [[ "$LP0_HOST" == *example* ]]; then
    die "LP0_HOST is still the placeholder ($LP0_HOST). Set it to lp0's real address."
  fi

  [[ -r "$LP0_IDENTITY" ]] || die "identity file not readable: $LP0_IDENTITY (generate one with: ssh-keygen -t ed25519 -f '$LP0_IDENTITY' -C lp0-bridge)"
}

# --- Command construction ------------------------------------------------

# Populates the SSH_ARGS array with everything after the ssh binary itself.
build_ssh_args() {
  SSH_ARGS=(
    -N                                  # no remote command; forwarding only
    -T                                  # no pty, so a hung shell cannot wedge us
    -p "$LP0_PORT"
    -i "$LP0_IDENTITY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes                    # never block waiting on a passphrase prompt
    -o ExitOnForwardFailure=yes         # a taken port fails loudly, not silently
    -o ServerAliveInterval="$LP0_ALIVE_INTERVAL"
    -o ServerAliveCountMax="$LP0_ALIVE_COUNT_MAX"
    -o TCPKeepAlive=yes
    -o ControlMaster=no                 # do not join or create a shared connection
    -o ControlPath=none                 # ...so a dead master cannot take the bridge down
  )

  [[ -n "$LP0_JUMP" ]] && SSH_ARGS+=(-J "$LP0_JUMP")

  local fwd
  for fwd in $LP0_LOCAL_FORWARDS;  do SSH_ARGS+=(-L "$fwd"); done
  for fwd in $LP0_REMOTE_FORWARDS; do SSH_ARGS+=(-R "$fwd"); done
  [[ -n "$LP0_SOCKS_PORT" ]] && SSH_ARGS+=(-D "$LP0_SOCKS_PORT")

  if [[ -z "$LP0_LOCAL_FORWARDS$LP0_REMOTE_FORWARDS$LP0_SOCKS_PORT" ]]; then
    die "no forwards configured — set at least one of LP0_LOCAL_FORWARDS, LP0_REMOTE_FORWARDS, or LP0_SOCKS_PORT"
  fi

  SSH_ARGS+=("${LP0_USER}@${LP0_HOST}")
}

# --- Actions -------------------------------------------------------------

action_args() {
  build_ssh_args
  printf 'ssh'; printf ' %q' "${SSH_ARGS[@]}"; printf '\n'
}

action_check() {
  build_ssh_args
  log "testing authentication to ${LP0_USER}@${LP0_HOST}:${LP0_PORT}"
  # Same auth path as the bridge, but runs a trivial command and exits.
  local probe=()
  local arg
  for arg in "${SSH_ARGS[@]}"; do
    case "$arg" in
      -N|-T) continue ;;
    esac
    probe+=("$arg")
  done
  # Drop the forward flags and their values; we only want to prove auth works.
  local filtered=() skip=0
  for arg in "${probe[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$arg" in
      -L|-R|-D) skip=1; continue ;;
    esac
    filtered+=("$arg")
  done
  if ssh "${filtered[@]}" -o ConnectTimeout=10 true; then
    log "ok — key authentication to lp0 succeeded"
  else
    die "could not authenticate to lp0. Install the public key with: ssh-copy-id -i '${LP0_IDENTITY}.pub' -p '$LP0_PORT' '${LP0_USER}@${LP0_HOST}'"
  fi
}

action_up() {
  build_ssh_args

  if command -v autossh >/dev/null 2>&1; then
    log "starting bridge to ${LP0_USER}@${LP0_HOST}:${LP0_PORT} via autossh"
    # -M 0 disables autossh's own monitoring port; the ServerAlive options
    # above are what detect a dead link. GATETIME=0 keeps it retrying even
    # when the very first connection fails (lp0 still booting, VPN not up).
    export AUTOSSH_GATETIME=0
    exec autossh -M 0 "${SSH_ARGS[@]}"
  fi

  log "autossh not found; using ssh with a retry loop"
  local delay="$LP0_RETRY_MIN"
  while true; do
    log "connecting to ${LP0_USER}@${LP0_HOST}:${LP0_PORT}"
    local start; start=$SECONDS
    ssh "${SSH_ARGS[@]}" || true
    local ran=$(( SECONDS - start ))

    # A connection that held for a while is a transient drop, so reset the
    # backoff. One that died immediately is likely a real fault: back off.
    if (( ran > 60 )); then
      delay="$LP0_RETRY_MIN"
      log "connection dropped after ${ran}s; reconnecting"
    else
      log "connection failed after ${ran}s; retrying in ${delay}s"
    fi

    sleep "$delay"
    delay=$(( delay * 2 ))
    (( delay > LP0_RETRY_MAX )) && delay="$LP0_RETRY_MAX"
  done
}

# --- Entry point ---------------------------------------------------------

main() {
  local action="${1:-up}"
  command -v ssh >/dev/null 2>&1 || die "ssh is not installed"
  load_config
  case "$action" in
    up)    action_up ;;
    check) action_check ;;
    args)  action_args ;;
    *)     die "unknown action '$action' (expected: up, check, args)" ;;
  esac
}

main "$@"
