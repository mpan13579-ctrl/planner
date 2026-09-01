# Agent briefing: this repo and the model server it connects to

This repository is tooling for reaching a private, self-hosted LLM. If you
are an AI agent working on this machine, here is what you need to know.

## The model endpoint

An OpenAI-compatible LLM API is available at:

- **Base URL:** `http://localhost:8000/v1`
- **API key:** any non-empty string (no real auth; the tunnel is the access control)
- **Model name:** ask `GET /v1/models` for the current one rather than hardcoding

Properties of the served model: reasoning model (thinking streams in the
`reasoning` / `reasoning_content` delta field, the answer in `content`),
~512k-token context window, tool/function calling and streaming supported.

To use it as an LLM backend, most OpenAI-compatible tooling needs only:

    OPENAI_BASE_URL=http://localhost:8000/v1
    OPENAI_API_KEY=not-needed

## How the endpoint exists (and how to revive it)

`localhost:8000` is the local end of an SSH tunnel to a GPU server on a
private Tailscale network. vLLM on that server is bound to its own
loopback, so this tunnel is the only path. Health check:

    curl http://localhost:8000/v1/models

If that fails, the tunnel is down. Start it:

- macOS / Linux: `./ssh/lp0-bridge.sh up` (or the launchd/systemd service
  in `launchd/` / `systemd/`)
- Windows: `Start-ScheduledTask -TaskName lp0-bridge`, or
  `powershell -ExecutionPolicy Bypass -File windows\lp0-bridge.ps1`

Setup for a brand-new machine is in `ssh/README.md` (Windows:
`windows/README.md`).

## Rules

- The server's address and account live only in the machine-local,
  gitignored `ssh/lp0-bridge.env`. Never commit that file, never paste its
  contents into logs or code, and never hardcode the server's address in
  committed files.
- Never bind the forwarded port to anything but `127.0.0.1`, and do not
  expose port 8000 through any proxy, firewall rule, or public URL.
- Do not SSH to the server to run commands unless the user explicitly asks;
  this repo's job is the tunnel, not remote administration.
