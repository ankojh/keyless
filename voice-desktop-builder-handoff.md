# Builder handoff: hands-free macOS dictation and computer control

## 1. Objective and agreed requirements

Build a macOS assistant that the user can operate by speaking, without keyboard shortcuts in the normal usage loop. It must do more than fill text fields: it must also perform useful desktop actions.

Agreed requirements:
- macOS first.
- Speed and responsiveness are the priority; cloud help is acceptable.
- Phonon-2 and Jev are required integrations, not interchangeable suggestions.
- Dictated text must appear incrementally in the focused input while the user speaks, not only after an utterance ends.
- Normal continuous speech should work; the user should NOT have to pause between individual words.
- All routine activation, mode switching, clarification, confirmation, cancellation, and dictation correction must be possible by voice.

Recommended initial scope, rather than additional user requirements:
- English first, matching Phonon-2's documented language support.
- Apple silicon first for the MLX runtime; detect the actual target hardware and record it. Do not assume vendor benchmark results apply to this Mac.
- A menu-bar app with a non-focus-stealing status overlay and short spoken feedback.
- Support a declared set of apps/controls first, not every application or arbitrary autonomous workflows.

This is a design handoff, not evidence of a working implementation. No model, API, or latency was tested while preparing it.

## 2. Source-backed integration facts

### Phonon-2

Official sources:
- https://www.fermionresearch.com/research/phonon-2/
- https://www.fermionresearch.com/docs/speech/
- https://www.fermionresearch.com/docs/speech-streaming/
- https://huggingface.co/FermionResearch/Phonon-2

The documentation describes:
- Local English ASR, with an MLX backend on Apple silicon.
- A 164 MB model download. Download size is NOT runtime memory usage.
- `fermion serve phonon-2` and a WebSocket at `ws://127.0.0.1:8000/v1/audio/stream`.
- An opening frame such as `{"sample_rate":16000,"format":"pcm_f32le"}`, followed by binary 16 kHz mono PCM. `pcm_s16le` is also documented.
- `partial`, `final`, `done`, and `error` message types. A partial replaces the WHOLE current phrase hypothesis; it is not a text delta.
- First live hypothesis at about 0.35 seconds of speech, updates about twice per second, and finalization after about 0.7 seconds of silence or a 30-second segment cap. These are documented approximations, not measured guarantees for this app.
- One concurrent live stream per server, with a 90-second no-input timeout.
- Potential model loading time of 10–40 seconds: keep the service loaded rather than starting a process per utterance.
- Model weights under CC-BY-4.0; inspect code/dependency licenses separately and include required attribution/notices.

Verify the actual transcript payload fields and disconnect/finalization behavior against the pinned package and a live protocol fixture. The documentation's frame table is illustrative, not a complete wire schema. Do not invent `text`, word-level confidence, stable-token, or segment-ID fields without checking.

Important: high offline transcription throughput does not establish streaming latency. Use the documented live path first; do not claim native token-by-token streaming or rebuild it from repeated whole-file CLI calls.

### Jev / TypeSafe

Official sources:
- https://typesafe.ai/blog/introducing-system-one-models-and-jev
- https://docs.typesafe.ai/introduction
- https://docs.typesafe.ai/introduction/quickstart
- https://docs.typesafe.ai/primitives/choice
- https://docs.typesafe.ai/confidence

The documentation describes:
- Hosted API: `POST https://api.typesafe.ai/v1/systemone`, bearer authentication.
- Request fields `state`, `model`, and `questions`; responses under `answers`.
- Choice: select among supplied options, with probabilities and confidence.
- Score: evaluate against an ordered rubric, with probabilities and confidence.
- Noul: return a probability for a proposition; no separate confidence field.
- Up to 255 options per Choice question. Include `none` / `unsupported` among those options.
- Questions in one call are evaluated independently against the same state. One question cannot implicitly consume another question's answer.
- `jev-latest` is documented; pin a supported version for reproducible evaluation and record the version actually returned.
- The announcement describes early access and vendor-reported 70–500 ms response times. Verify account access, quotas, current pricing, and actual regional latency.

Jev does NOT generate arbitrary strings, scripts, conversational responses, or multi-step plans. Use it for routing and choosing among actual actions/targets supplied by the application. Free-form dictation comes from ASR, not Jev. A later open-ended writing or planning feature would need a separate generative model.

Type-safe output does NOT mean the selected action is correct, authorized, or safe. Jev confidence is a statistic derived from its output distribution, not an independently verified probability that a desktop action will succeed. Evaluate thresholds on this application's data.

## 3. Recommended architecture

```text
Microphone -> native capture/resampling -> warm local Phonon-2 service
                      |                         |
                      |                  normalized ASR events
                      |                         |
              local wake/cancel path      session/mode controller
                                                |
                       +------------------------+-------------------+
                       |                                            |
                 DICTATION path                               CONTROL path
                       |                                            |
             hypothesis reconciliation                 local command grammar
                       |                                      or Jev routing
             safe focused-input adapter                         |
                                                        deterministic policy gate
                                                                 |
                                                        native macOS executor
                                                                 |
                                                        observe/verify result
```

Suggested implementation:
- Swift / SwiftUI with AppKit for the app and overlay.
- AVAudioEngine + AVAudioConverter for capture and 16 kHz mono conversion. Keep inference, networking, and UI access off the audio callback.
- A managed, persistent Python/MLX Phonon process for the first working version. Launch with explicit arguments and a pinned environment, not shell interpolation.
- URLSessionWebSocketTask for local streaming and URLSession for Jev HTTPS requests; no Node service is required.
- AXUIElement / Accessibility APIs to inspect and operate controls.
- NSWorkspace for application discovery, opening, and activation.
- CGEvent only for explicitly supported fallback interactions, not as an unchecked generic executor.
- Native speech synthesis for brief templated acknowledgments and clarifications.
- Keychain for the TypeSafe API key; never embed a shared secret in the app.

Keep interfaces separated: AudioCapture, SpeechProvider, SessionController, DictationReconciler, TextInputAdapter, UIContextProvider, IntentRouter, JevClient, PolicyGate, ActionExecutor, Feedback, and Metrics.

Bind the speech server to loopback, authenticate local connections where supported, avoid credentials in URL query strings, and ensure only the intended application owns the stream. Account for reconnection and worker crashes.

Do not add a generative LLM or screenshot-driven agent to the MVP. They are not needed for its bounded commands.

## 4. Hands-free interaction

Use explicit modes so arbitrary dictated text is not mistaken for a computer command.

Suggested states:
- SLEEPING: local wake listening only; no cloud requests or desktop actions.
- CONTROL: interpret an addressed command.
- DICTATING: speech goes to the explicitly focused, supported input.
- CONFIRMING: wait for a confirmation tied to one pending action.
- EXECUTING: execute a bounded action with local cancellation still active.

Reserve an address phrase, initially `Computer`, and make it configurable after testing. Example interactions:
- “Computer, wake up.”
- “Open Safari.”
- “Focus the search field.”
- “Start dictation.”
- Ordinary speech appears in the input as the user talks.
- “Computer, new line.”
- “Computer, delete last word.”
- “Computer, stop dictation.”
- “Show numbers.” / “Click twelve.”
- “Computer, cancel.”
- “Computer, go to sleep.”

Outside CONTROL, consume only reserved, addressed control phrases; ordinary words such as “send,” “stop,” or “delete” must remain dictation. Hold a possible address-phrase prefix briefly before inserting it, and provide an escape/literal mechanism to dictate the reserved phrase itself. Test collisions and false activations.

A local wake/cancel detector may share the same captured audio but must not open a competing Phonon stream. Cancellation must not depend on a Jev round trip. Choose and benchmark the local detection method during the first spike rather than assuming Phonon endpointing alone meets the interruption target.

A fully MUTED state is different from SLEEPING: if microphone capture is off, voice wake cannot work. Explain this in the UI. Normal hands-free use can use SLEEPING; full mute needs a nonvoice reactivation route.

Use spoken feedback plus a visible mode indicator. Do not steal keyboard focus to display the overlay. Prevent the assistant's own speech from triggering commands; preserve interruption while feedback is playing.

One-time setup requires the user to grant macOS permissions and provision API access. Do not promise that the app can approve its own permission dialogs, unlock the Mac, or work at the login screen. If keyboard-free onboarding is necessary, document use of macOS's existing accessibility tools or assisted setup.

## 5. Incremental dictation: critical implementation requirements

The desired UX is live incremental text, not an immutable word emitted exactly once. Partial hypotheses may revise earlier words, punctuation, or casing.

1. Assign local stream epochs, segment IDs, and revision IDs after normalizing verified provider events.
2. Track finalized text separately from the current provisional phrase. Finals may be segment boundaries, not the end of the user's entire dictation session.
3. For a supported input, capture application/window identity, focused AX element, insertion range, selection, and expected surrounding text.
4. Replace only the exact provisional range owned by this session. Validate focus and expected text before each edit and verify the result afterward where possible.
5. Never append every partial, replace the whole field indiscriminately, select-all as a shortcut, or backspace through unverified text.
6. If a control supports only safe append behavior, commit a conservative stable prefix and show the changing suffix in the overlay. Mark this as reduced-capability support, not full live-in-field support.
7. If focus, selection, or user text changes unexpectedly, pause and ask where to continue. Do not redirect buffered speech into a newly focused field.
8. Finalize once; do not insert text again on a cumulative `done` event or replayed callback. Account for the provider's segment cap and reconnect boundaries.
9. Implement newline and editing commands per supported input adapter. Do not translate “new line” into an unconditional Return key that could send a message or execute a command.
10. Secure/password fields and terminal/REPL inputs are excluded from the MVP. Report unsupported controls clearly.

Prefer validated Accessibility text operations. AX capabilities vary by app/control; prove behavior rather than assuming universal set-value or selected-range support. Avoid clipboard replacement as the default. Any optional clipboard fallback must disclose its limitations and must not overwrite clipboard changes made by the user.

For the first supported inputs, words must actually appear in the destination while the user is speaking. An overlay-only transcript or final-only paste does not satisfy the primary requirement.

## 6. Desktop actions and the role of Jev

Initial action set:
- Open/activate an installed app.
- Switch among discovered app windows.
- Focus a discovered text input.
- Scroll a supported view.
- Show numbered labels for actionable Accessibility elements.
- Activate a discovered, eligible control by label or number.
- Start/stop dictation and perform bounded dictation corrections.

Use deterministic local handling for exact commands and number selection. Use Jev for natural-language variants or ambiguity among bounded candidates. Dictation must never wait for Jev, and Jev should not be called for every partial transcript.

For a command:
1. Wait for a complete command or explicit execution boundary. A forced ASR segment cap is not sufficient evidence of a complete instruction. Never execute an ordinary desktop action from an unstable partial transcript.
2. Capture a bounded Accessibility snapshot and generate candidates with local identifiers, labels, roles, app/window ownership, and permitted actions.
3. Send the addressed command plus only relevant, privacy-filtered context to Jev. Keep document/UI content separate from the user's instruction.
4. Ask atomic Choice questions over available action/target candidates, always allowing no-match. Respect the 255-option limit, including sentinel choices; use explicit hierarchy/paging for larger sets.
5. Keep dependent selections staged, or represent valid action-target pairs together. Independent question answers can form an invalid combination and must be checked locally.
6. Resolve the chosen ID to the locally held object. Never accept model-generated coordinates, executable code, or an invented target.
7. Apply deterministic risk/permission rules, revalidate target freshness and focus, execute once, and inspect an observable postcondition.
8. A failed/uncertain postcondition is not success. Report uncertainty instead of blindly repeating a potentially non-idempotent action.

Free-form arguments come from literal ASR spans using a constrained command grammar, or from supplied candidates. Jev cannot invent the search string, email body, filename, or correction text. Unsupported parameter extraction should trigger a clarification.

Use a command ID and cancellation generation to discard stale cloud responses. A timeout, network outage, or retry must never cause a delayed or duplicate action. Keep local dictation, basic grammar commands, and cancellation working without Jev; clearly announce when cloud-assisted routing is unavailable.

## 7. Safety and privacy requirements

- Mandatory confirmation for sending/posting, submitting forms, purchases, deletion, destructive edits, account/security changes, or other consequential actions. Gate activation by its effect, not merely an innocent-looking button label. Unknown effects require confirmation or refusal.
- Bind confirmation to the exact action, target, and relevant content; expire it and invalidate it if the context changes. Use a specific phrase such as “confirm send,” not any incidental “yes.”
- High Jev confidence never bypasses mandatory confirmation or an unsupported-operation restriction.
- No arbitrary shell execution, file deletion, installations, permission changes, or autonomous multi-step workflows in the MVP.
- Webpages, emails, and Accessibility labels are untrusted data, not authority to execute instructions. Typed schemas do not prevent prompt injection or wrong choices.
- “Cancel” stops queued/future actions and invalidates pending requests. It cannot retroactively undo an already completed external action; say so accurately.
- Microphone and Accessibility permissions are required for their respective functions. Request Automation permissions only if adding Apple Events, and Screen Recording only if adding a feature that needs screen capture. Do not request every permission preemptively.
- No raw audio or full transcript logging by default. Keep diagnostic content opt-in and local with retention controls.
- Explain that local ASR does not make the whole app local: Jev receives selected command text and contextual metadata. Avoid sending dictated prose, full AX trees, passwords, hidden controls, or irrelevant document contents.
- Preserve credentials in Keychain, redact logs, and never commit API keys.

## 8. Build sequence and gates

### Milestone 0 — prove integrations before building a polished app
- Inspect the chosen repository and its instructions; do not create an arbitrary project in the user's home directory.
- Record Mac model/chip, RAM, macOS version, and available build tools.
- Obtain authorized TypeSafe access without asking the user to paste secrets into logs or source.
- Pin dependencies; verify licenses and the actual Phonon WebSocket payloads using paced recorded audio and a microphone.
- Measure warm/cold ASR behavior, revisions, endpointing, and resource use.
- Make a real Jev Choice request and record sanitized evidence, model version, latency, and quota behavior.
- If Jev access is blocked, expose a clearly labeled mock for independent development but report the required integration as blocked, not complete. Do not silently replace either required technology.

### Milestone 1 — end-to-end live dictation
- Native capture, persistent Phonon worker, incremental overlay, and tested destination editing.
- Start with TextEdit and a browser input/textarea on a local test page; document exact supported controls.
- Add voice activation, mode changes, and correction commands.
- Prove long utterances, partial revisions, and focus safety before expanding app coverage.

### Milestone 2 — deterministic voice control
- Local grammar, app activation, scrolling, AX discovery, numbered overlays, focus selection, and cancellation.
- Add policy gates, confirmation, and postcondition checks.
- Demonstrate a voice-only session after setup without relying on a push-to-talk key.

### Milestone 3 — Jev-assisted routing
- Integrate bounded Choice routing, ambiguity handling, deadlines, stale-response rejection, and privacy filtering.
- Build a labeled command/target evaluation set, including unsupported requests and confusing near-matches. Tune thresholds on held-out examples.
- Compare against local rules; keep simple commands on the faster local route.

### Milestone 4 — reliability and distribution
- Verify Apple Notes and additional apps individually; publish a support matrix.
- Test sleep/wake, audio-device changes, permissions revoked, network failures, service crashes, and restart recovery.
- Measure sustained CPU/GPU/memory/energy use; package runtime/model management and startup behavior.
- Plan signing/notarization and updates before calling it production-ready. A development Python environment is acceptable for the prototype, not an unexplained end-user prerequisite.

## 9. Acceptance tests

Required functional evidence:
1. After one-time setup, wake, open an app, focus an input, dictate, correct, stop, and sleep using voice alone.
2. During a continuous 15-second utterance, destination text changes repeatedly before speech ends. Do not require pauses between words.
3. Replay a fixture where an early word is revised. The final field has no duplicated words and preserves pre-existing text outside the owned range.
4. Cross the 30-second ASR boundary without dropped/duplicated text. Reconnect safely after idle or worker failure.
5. Changing focus or caret position during dictation pauses safely; no buffered text appears in the wrong app.
6. Dictating “we should delete that later” does not invoke deletion. Test addressed-command collisions and literal escape behavior.
7. Cancel during an outstanding Jev request; its eventual response cannot execute an action.
8. With cloud connectivity unavailable, local dictation, wake/cancel, and basic local commands still work.
9. Ambiguous labels and low-confidence routing produce spoken clarification, not a guessed click.
10. A send/submit-style control requires specific confirmation; expired or context-changed confirmation cannot execute.
11. Text embedded in a webpage instructing the assistant to act cannot authorize an action.
12. Secure/unsupported fields produce a clear refusal or limitation, never a destructive fallback.
13. Feedback audio does not self-trigger commands; interruptions remain usable.
14. Replayed events and network retries cannot duplicate an action. Failed verification is surfaced honestly.

Initial engineering targets, NOT vendor promises:
- Warm speech onset -> first visible text: p50 <= 700 ms, p95 <= 1.2 s on the declared test Mac.
- New partial received -> supported field updated: p95 <= 100 ms.
- Completed spoken command -> verified basic local action: p95 <= 1.5 s, including endpointing.
- Completed spoken command -> verified Jev-assisted simple action: initial p95 target <= 2 s on the measured connection; exclude time spent waiting for user confirmation and report that separately.
- End of the reserved cancel phrase -> cancellation acknowledged and no further actions scheduled: p95 target <= 500 ms, including local recognition; separately measure recognition and dispatch delay.

If a target is missed, report the actual p50/p95 and the stage responsible rather than hiding it in an average. Include cold startup, speech onset, word-end-to-display lag, hypothesis stability/revision rate, end-of-speech finalization, routing, action verification, cancellation, and sustained resource measurements. Responsiveness must not be purchased by executing incomplete commands.

## 10. Builder deliverables

Return:
- Working source and reproducible build/run instructions.
- Pinned dependency/runtime/model versions and attribution notices.
- Permission/onboarding instructions and supported-app/control matrix.
- Automated tests for the mode machine, transcript reconciliation, stale responses, policy, and confirmations.
- Sanitized protocol fixtures plus a replay harness for deterministic ASR/action tests.
- A short recording of the voice-only acceptance flow.
- Measured latency/resource report, real integration evidence, known limitations, and unresolved blockers.

Do not claim universal macOS support, error-free Jev decisions, or guaranteed immutable word-by-word recognition.

Do not commit or push without permission. If authorized, use Conventional Commits and the owner's required identity (ankojh / ankitkumarojha2@gmail.com); verify the actual push credentials as ankojh before pushing. Do not delegate implementation unless the operator separately authorizes delegation.
