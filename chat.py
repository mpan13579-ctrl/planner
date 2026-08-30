#!/usr/bin/env python3
"""Minimal terminal chat for the model behind the lp0 bridge.

Standard library only — no installs. Run:

    python3 chat.py

Talks to http://localhost:8000/v1 (the bridge's local end), discovers the
served model automatically, streams answers as they generate, and keeps the
conversation going across turns. The model's thinking is shown dimmed;
pass -q to hide it.

Commands inside the chat:  /new  start a fresh conversation
                           /quit exit (Ctrl+C during an answer just stops
                                 that answer; Ctrl+C at the prompt exits)
"""
import json
import sys
import urllib.error
import urllib.request

BASE = "http://localhost:8000/v1"
DIM = "\033[2m"
RESET = "\033[0m"


def fetch_model():
    with urllib.request.urlopen(BASE + "/models", timeout=5) as r:
        models = json.load(r)["data"]
    if not models:
        sys.exit("The server is up but reports no models.")
    return models[0]["id"]


def stream_reply(model, messages, show_reasoning):
    """Send the conversation, stream the reply to stdout, return the answer text."""
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=json.dumps(
            {"model": model, "messages": messages, "stream": True}
        ).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer not-needed",
        },
    )
    answer = []
    in_reasoning = False
    with urllib.request.urlopen(req) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                break
            chunk = json.loads(payload)
            if not chunk.get("choices"):
                continue
            delta = chunk["choices"][0].get("delta") or {}
            # vLLM emits the thinking under reasoning_content (older) or
            # reasoning (newer); the answer itself is always content.
            thinking = delta.get("reasoning_content") or delta.get("reasoning")
            content = delta.get("content")
            if thinking and show_reasoning:
                if not in_reasoning:
                    sys.stdout.write(DIM + "thinking: ")
                    in_reasoning = True
                sys.stdout.write(thinking)
            if content:
                if in_reasoning:
                    sys.stdout.write(RESET + "\n\n")
                    in_reasoning = False
                sys.stdout.write(content)
                answer.append(content)
            sys.stdout.flush()
    if in_reasoning:
        sys.stdout.write(RESET)
    sys.stdout.write("\n")
    return "".join(answer)


def main():
    show_reasoning = "-q" not in sys.argv[1:]
    try:
        model = fetch_model()
    except (urllib.error.URLError, OSError):
        sys.exit(
            "Can't reach the model at " + BASE + ".\n"
            "Is the bridge up?  Start it with:  ./ssh/lp0-bridge.sh up"
        )

    print("Chatting with " + model + "  (/new resets, /quit exits)")
    messages = []
    while True:
        try:
            user = input("\nyou> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not user:
            continue
        if user == "/quit":
            return
        if user == "/new":
            messages = []
            print("(fresh conversation)")
            continue

        messages.append({"role": "user", "content": user})
        print()
        try:
            reply = stream_reply(model, messages, show_reasoning)
        except KeyboardInterrupt:
            print(RESET + "\n(answer interrupted)")
            messages.pop()
            continue
        except (urllib.error.URLError, OSError) as e:
            print(RESET + "\nConnection lost mid-chat (" + str(e) + ").")
            print("Check the bridge, then just ask again — history is kept.")
            messages.pop()
            continue
        messages.append({"role": "assistant", "content": reply})


if __name__ == "__main__":
    main()
