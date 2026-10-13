# Milestone 0: integration evidence

Recorded 2026-10-12. Scope: prove Phonon-2 and Jev on this Mac before building the app. Reproduction steps are in [`spike/README.md`](../spike/README.md).

**Status:** both integrations work. Phonon-2 has been tested only with synthetic, paced audio files; a live microphone test is still outstanding (Milestone 1, needs a person speaking).

## Test machine

| | |
|---|---|
| Model | Mac15,9 (MacBook Pro), Apple M3 Max |
| Memory | 48 GB |
| macOS | 27.0.1 (26A434), arm64 |
| Toolchain | Xcode 27.0 (27A266a), Swift 6.4 |
| Python | 3.12.13 via uv 0.12.24 (system Python is 3.9.6 and unused) |

## Phonon-2

### Versions

| | |
|---|---|
| Runtime | `fermion-research` 0.2.11 (Apache-2.0) |
| Model | `FermionResearch/Phonon-2`, profile `five-value`, sha256 `98125795b6dda72f5c6eee9ba33d19815df65dcb18b50a357bf9f73c9935309e` (weights CC-BY-4.0) |
| Backend | MLX 0.32.3, mlx-audio 0.5.8 (parakeet graph, bfloat16 activations) |

All runtime packages are pinned in `spike/requirements.lock`. The licenses of the direct runtime dependencies are permissive: MIT, BSD and Apache-2.0. `torch` and `transformers` get installed as dependencies but the MLX path doesn't seem to use them. Check whether a packaged build can drop them.

The CC-BY-4.0 weights require attribution, for example: "Phonon-2 by Fermion Research, licensed CC-BY-4.0".

### Startup and resources

- `fermion serve` to `/health` ready: **23 s** on first run, which included the download, the SHA-256 check and unpacking. The server reported `load_seconds: 15.56`.
- The first stream after startup is **cold**: its first partial arrived 2.86 s after speech began, which was after the whole 2.5 s clip had been sent. Later streams were warm. The app should send one warm-up stream at launch.
- Resident memory: about **1.25 GB** idle and a **1.32 GB** peak while streaming. Process CPU: **10–28 %** of one core while streaming, 0 % idle. GPU and energy use were not measured.

### Measured wire protocol

Server frames, as observed:

| Frame | Fields |
|---|---|
| `partial` | `type`, `text` — the whole current phrase hypothesis |
| `final` | `type`, `text`, `segment` (1-based integer, counts up within a stream) |
| `done` | `type`, `text` — every final joined with single spaces |
| `error` | `type`, `message` |

There are no word timings, confidence values, stable-prefix markers or revision IDs on the stream. The client has to assign its own revision numbers.

Authentication and limits:

- A wrong or missing bearer token is rejected at the handshake with **HTTP 401**. The token goes in the `Authorization` header, never the URL.
- A second concurrent stream gets `{"type":"error","message":"engine busy — one stream at a time"}` and then close **1013**. The first stream is unaffected.
- A sample rate other than 16000 gets an error frame and close **1008**.
- **Idle timeout differs from the docs.** A stream that sent its opening frame and then nothing was still open after 120 s, with no frame and no close. The docs say 90 s with close 1001. The app needs its own idle and liveness handling.
- `pcm_s16le` and `pcm_f32le` gave the same text and timing.

### Measured latency (warm, paced synthetic audio, 40 ms chunks)

| Metric | Measured |
|---|---|
| Speech onset → first partial | 0.37–0.40 s (5 streams) |
| Partial cadence | median 0.52 s |
| Last speech → last `final` | 0.63–0.74 s |

These are server-side numbers from paced files. They don't include microphone capture, resampling or writing into a text field.

### Behaviour the app must handle

1. **Partials revise earlier words.** Examples: "invite" was briefly "in view", "a long decade" became "a long dictation", "the speech reference" became "the speech recognizer", and "Computer." lost its period. A revision can reach back several words, and a partial can change only punctuation.
2. **A brief spurious partial before speech.** After silence, the first partial of a new segment was briefly "Yeah." before the real words replaced it. The reconciler must allow any provisional text to be retracted.
3. **Partials carry the whole segment.** All 57 partials in the 30 s segment start from the segment's first words and grow to 539 characters. A partial never covers just a window. Diffing each partial against the previous one is therefore safe within a segment.
4. **Segment boundary at the 30 s cap duplicates a word.** Segment 1 ended "…end of the month and after." and segment 2 began "After that we will also…". Phonon's own `done` repeats it too ("and after. After that"). The reconciler needs overlap de-duplication at forced segment boundaries, and must never use `done` as insert text.
5. **Finals are segment boundaries, not utterance ends.** The pause fixture produced three finals in one stream, one per phrase between 1.2 s silences.

## Jev

| | |
|---|---|
| Endpoint | `POST https://api.typesafe.ai/v1/systemone`, bearer authentication |
| Key | the existing TypeSafe account key, also used by Observe, stored in the Keychain under service `ai.keyless.typesafe`. Usage is billed to the same account, and Observe's daily token cap does not apply to Keyless. |
| Model | `jev-latest` returned **`jev-1.13.0`**. Requesting `jev-1.13.0` directly works, so the app pins it. |

### Command-routing test

Ten synthetic spoken commands against seven synthetic Accessibility candidates. Each request asked two independent Choice questions, `intent` (11 options including `unsupported` and `none`) and `target` (7 controls plus `no_target`). The command and the UI snapshot were separate fields of the state.

| Run | Calls | HTTP 200 | Intent correct | Latency p50 / p95 / max |
|---|---|---|---|---|
| `jev-latest` ×3 | 30 | 30 | 27 | 164 / 196 / 211 ms |
| `jev-1.13.0` ×1 | 10 | 10 | 9 | 156 / 545 / 545 ms |

About 860 input tokens per call. Latency was measured from this Mac on the current network.

Observations:

- The only intent miss was "let me type the email now". Every time it chose `focus_target` (body field) instead of `start_dictation`, with confidence **0.58–0.64**, while every correct answer had ≥ 0.92. A confidence threshold near 0.8 would turn this into a clarification instead of a wrong action. That threshold still needs tuning on a real evaluation set (Milestone 3).
- "hit send" chose the Mail **Send** button at confidence 1.0. High confidence doesn't make an action safe, so the policy gate's mandatory confirmation must stay independent of Jev's confidence.
- "delete everything in my downloads folder" chose `unsupported` at 1.0. "the weather is nice today" chose `none`.
- One call took 545 ms. Routing deadlines must allow for tail latency, and late responses must be thrown away as stale.

Raw sanitized results: `spike/evidence/jev-latest.json`, `spike/evidence/jev-1.13.0.json`.

## Open items carried into Milestone 1

- Test Phonon-2 with a real microphone through native AVAudioEngine capture, timed from speech onset to visible text.
- Pick and benchmark a local wake and cancel detector that shares the captured audio without opening a second Phonon stream.
- Read the full license text and dependency notices before any distribution.
