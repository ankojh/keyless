"""Compare sherpa-onnx speaker-embedding models for Keyless's "only my voice" filter.

Usage: bench_speaker.py OUT_JSON

Speakers are macOS `say` voices: each gets a ~20 s enrollment passage and short test commands,
mixed with background noise at 15 dB SNR. Synthetic voices are far more consistent than a real
person, so absolute scores here are optimistic; the useful outputs are the speed of each model and
how cleanly it separates similar-sounding voices. Real thresholds come from the user's enrollment.
"""

import json
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

import numpy as np
import sherpa_onnx
import soundfile as sf

HERE = pathlib.Path(__file__).resolve().parent
MODELS = HERE / "models" / "speaker"

# Only voices verified to produce distinct audio: many names (Eddy, Flo, Reed, "… (English (US))")
# silently fall back to Samantha or Daniel when the voice isn't downloaded.
VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Fred", "Albert", "Kathy", "Ralph", "Aman", "Junior", "Tessa"]

ENROLL = (
    "The quick brown fox jumps over the lazy dog. I'm setting up my computer so it only listens to me. "
    "Please open my calendar for next Tuesday and remind me about the design review. "
    "We should plan the quarterly review next week and invite everyone from the team. "
    "Numbers like seventeen, forty two, and ninety nine should all sound clear."
)
TESTS = [
    "Computer, wake up.", "Open Safari.", "Start dictation.", "Computer, new line.",
    "Click twelve.", "Computer, stop dictation.", "Go to sleep.",
    "Dear Sam, thanks for the update on the launch plan.",
]


def synth(text: str, voice: str, path: pathlib.Path) -> np.ndarray:
    subprocess.run(["say", "-v", voice, "-o", str(path), "--data-format=LEF32@16000", text], check=True)
    audio, rate = sf.read(path, dtype="float32")
    assert rate == 16000
    return audio


def add_noise(audio: np.ndarray, snr_db: float, rng: np.random.Generator) -> np.ndarray:
    # Pink-ish noise: white noise through a one-pole low-pass, scaled to the target SNR.
    white = rng.standard_normal(len(audio)).astype(np.float32)
    pink = np.empty_like(white)
    acc = 0.0
    for i, w in enumerate(white):
        acc = 0.97 * acc + 0.03 * w
        pink[i] = acc
    p_sig = float(np.mean(audio**2)) + 1e-12
    p_noise = float(np.mean(pink**2)) + 1e-12
    return audio + pink * np.sqrt(p_sig / (p_noise * 10 ** (snr_db / 10)))


def embed(extractor, audio: np.ndarray) -> np.ndarray:
    stream = extractor.create_stream()
    stream.accept_waveform(sample_rate=16000, waveform=audio)
    stream.input_finished()
    v = np.array(extractor.compute(stream), dtype=np.float32)
    return v / (np.linalg.norm(v) + 1e-12)


def main(out: str) -> None:
    rng = np.random.default_rng(7)
    data = {}
    with tempfile.TemporaryDirectory() as tmp:
        for voice in VOICES:
            enroll = synth(ENROLL, voice, pathlib.Path(tmp) / "e.wav")
            tests = [add_noise(synth(t, voice, pathlib.Path(tmp) / f"t{i}.wav"), 15, rng) for i, t in enumerate(TESTS)]
            data[voice] = (enroll, tests)
    print(f"synthesized {len(VOICES)} voices")

    results = {}
    for model in sorted(MODELS.glob("*.onnx")):
        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=2)
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        # Enrollment centroid from 3 s windows, like the app will do.
        centroids = {}
        for voice, (enroll, _) in data.items():
            windows = [enroll[i : i + 48000] for i in range(0, len(enroll) - 24000, 24000)]
            c = np.mean([embed(extractor, w) for w in windows], axis=0)
            centroids[voice] = c / np.linalg.norm(c)

        genuine, impostor, timings = [], [], []
        hardest = []
        for voice, (_, tests) in data.items():
            for audio in tests:
                start = time.perf_counter()
                e = embed(extractor, audio)
                timings.append((time.perf_counter() - start) * 1000)
                for other, c in centroids.items():
                    score = float(np.dot(e, c))
                    if other == voice:
                        genuine.append(score)
                    else:
                        impostor.append(score)
                        hardest.append((score, voice, other))

        # Equal error rate over a threshold sweep.
        best = None
        for th in np.linspace(-0.2, 1.0, 1201):
            far = np.mean(np.array(impostor) >= th)
            frr = np.mean(np.array(genuine) < th)
            if best is None or abs(far - frr) < abs(best[1] - best[2]):
                best = (float(th), float(far), float(frr))
        hardest.sort(reverse=True)
        results[model.stem] = {
            "dim": int(extractor.dim),
            "embed_ms_p50": round(statistics.median(timings), 1),
            "embed_ms_max": round(max(timings), 1),
            "genuine_min": round(min(genuine), 3),
            "genuine_p10": round(float(np.percentile(genuine, 10)), 3),
            "impostor_max": round(max(impostor), 3),
            "impostor_p99": round(float(np.percentile(impostor, 99)), 3),
            "margin": round(min(genuine) - max(impostor), 3),
            "eer_threshold": round(best[0], 3),
            "eer": round((best[1] + best[2]) / 2, 4),
            "hardest_impostors": [(round(s, 3), a, b) for s, a, b in hardest[:3]],
        }
        print(model.stem, json.dumps(results[model.stem]))

    pathlib.Path(out).write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
