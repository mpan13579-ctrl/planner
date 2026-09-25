# Keeping vLLM up on lp0ai

Why the model "goes offline": vLLM on the box runs as a Docker container
started by hand with `--rm`. `--rm` means *delete the container when it
exits*, and it carries no restart policy. So whenever vLLM stops for any
reason — CUDA/OOM crash, a host reboot, someone Ctrl-C'ing the terminal it
was started from — it is simply gone until a human retypes the command.
Every "offline" incident that wasn't the box itself dropping off Tailscale
was this.

Fix it once, on the box, as the `lp0` user.

## 1. Capture the exact current launch command

Don't retype it from memory; read it off the running (or last) container:

```sh
docker inspect lp0-qwen38flash-prod --format '{{json .Config.Cmd}}'
docker inspect lp0-qwen38flash-prod --format '{{json .HostConfig.Binds}}'
docker inspect lp0-qwen38flash-prod --format '{{json .Config.Env}}'
```

(If the container is gone because `--rm` already removed it, the command is
in shell history: `grep 'docker run' ~/.bash_history`.)

## 2. Move the API key out of the command line

Anything on the command line is visible to every user via `ps`. vLLM reads
`VLLM_API_KEY` from the environment instead, so put it in a root-only file:

```sh
sudo install -d -m 700 /etc/lp0
echo 'VLLM_API_KEY=<your key>' | sudo tee /etc/lp0/vllm.env >/dev/null
sudo chmod 600 /etc/lp0/vllm.env
```

and drop `--api-key <key>` from the vLLM arguments.

## 3. Relaunch with a restart policy

Same command as before, with two changes: **`--rm` removed, `--restart
unless-stopped` added**, plus `--env-file` for the key.

```sh
docker stop lp0-qwen38flash-prod 2>/dev/null; docker rm lp0-qwen38flash-prod 2>/dev/null

docker run -d --name lp0-qwen38flash-prod \
  --restart unless-stopped \
  --env-file /etc/lp0/vllm.env \
  --network host --ipc host --gpus all \
  -e VLLM_PLE_CPU_OFFLOAD=1 -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e NCCL_P2P_DISABLE=1 -e NCCL_CUMEM_ENABLE=0 \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  -e VLLM_NO_USAGE_STATS=1 -e DO_NOT_TRACK=1 \
  <the same -v mounts as step 1> \
  <the same image@sha256 as step 1> \
  /model --host 127.0.0.1 --port 8001 \
  <the same vLLM arguments as step 1, minus --api-key>
```

`-d` runs it detached so it no longer depends on a terminal staying open.

What `--restart unless-stopped` buys you:

| Event | Before (`--rm`) | After |
| --- | --- | --- |
| vLLM crashes (OOM, CUDA error) | gone until someone notices | Docker restarts it in seconds |
| Box reboots | gone until someone logs in and relaunches | Docker brings it up on boot |
| `docker stop` on purpose | gone | stays stopped (that's the "unless-stopped") |

## 4. Verify

```sh
docker ps --format '{{.Names}}  {{.Status}}  restart={{.HostConfig.RestartPolicy.Name}}'
curl -s -H "Authorization: Bearer $(sudo awk -F= '/VLLM_API_KEY/{print $2}' /etc/lp0/vllm.env)" http://127.0.0.1:8001/v1/models
```

Then from your laptop, `./ssh/diagnose.sh` should end in "everything works".

## The other cause: the box leaving Tailscale

Once the container restarts itself, the remaining way to go "offline" is
the machine itself dropping off the tailnet (`tailscale status` on your
laptop shows it `offline, last seen …`). That's power, sleep, or the
network, not vLLM. On the box, make sure Tailscale starts on boot and the
machine never sleeps:

```sh
sudo systemctl enable --now tailscaled
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

`tailscale ping` from your laptop showing only `via DERP(...)` and never a
direct connection means traffic is relayed — it works, but it's slower and
a little more fragile. Opening UDP 41641 inbound on the box's router lets
Tailscale connect directly.
