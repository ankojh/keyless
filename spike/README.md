# Milestone 0 integration spike

Scripts that prove the two required integrations, Phonon-2 and Jev, before the app is built. Results are in [`docs/milestone-0.md`](../docs/milestone-0.md).

## Setup

```sh
cd spike
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.lock
```

`requirements.lock` pins every package, including `fermion-research==0.2.11`.

## Phonon-2 server

```sh
umask 077; python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > .local-key
.venv/bin/fermion serve phonon-2 --host 127.0.0.1 --port 8765 --api-key "$(cat .local-key)"
```

The first run downloads the 164 MB model to `~/.cache/fermion/speech/` and verifies its SHA-256.

## Probes

| Script | What it does |
|---|---|
| `probe_stream.py WAV OUT.jsonl` | Streams a WAV at real-time pace and records every server frame with timestamps. |
| `show_frames.py OUT.jsonl` | Prints a recorded stream as a timeline. |
| `probe_edges.py OUT.json [--idle]` | Bad auth, second concurrent stream, bad sample rate, and (with `--idle`) the idle timeout. |
| `probe_jev.py OUT.json [--model M]` | Real Jev Choice requests over synthetic commands and UI candidates. Reads the key from the Keychain. |

The Jev key lives in the Keychain under service `ai.keyless.typesafe`, account `default`. Scripts never print it.

## Fixtures

- `fixtures/audio/` — synthetic speech made with macOS `say` (16 kHz mono PCM). No real user audio.
- `fixtures/protocol/` — recorded server frames for each fixture. These seed the replay harness.
- `evidence/` — Jev responses with latency, model version and token usage.
