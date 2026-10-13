"""Stream a WAV file to the Phonon-2 WebSocket at real-time pace and record every server frame.

Usage: probe_stream.py WAV OUT_JSONL [--port 8765] [--chunk-ms 40] [--format pcm_f32le|pcm_s16le]

The local API key is read from spike/.local-key and sent as a Bearer header, never in the URL.
"""

import argparse
import asyncio
import json
import pathlib
import time

import numpy as np
import soundfile as sf
import websockets
from scipy.signal import resample_poly

HERE = pathlib.Path(__file__).resolve().parent


def load_16k_mono(path: str) -> np.ndarray:
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if rate != 16000:
        audio = resample_poly(audio, 16000, rate).astype(np.float32)
    return audio


async def run(args: argparse.Namespace) -> None:
    audio = load_16k_mono(args.wav)
    key = (HERE / ".local-key").read_text().strip()
    url = f"ws://127.0.0.1:{args.port}/v1/audio/stream"
    chunk = int(16000 * args.chunk_ms / 1000)
    records = []
    t0 = time.monotonic()

    def stamp() -> float:
        return round(time.monotonic() - t0, 4)

    async with websockets.connect(url, additional_headers={"Authorization": f"Bearer {key}"}, max_size=None) as ws:
        records.append({"t": stamp(), "dir": "connected"})
        await ws.send(json.dumps({"sample_rate": 16000, "format": args.format}))

        async def sender() -> None:
            start = time.monotonic()
            for i in range(0, len(audio), chunk):
                block = audio[i : i + chunk]
                if args.format == "pcm_s16le":
                    payload = (np.clip(block, -1, 1) * 32767).astype("<i2").tobytes()
                else:
                    payload = block.astype("<f4").tobytes()
                await ws.send(payload)
                # Pace to real time against the wall clock, not per-chunk sleeps, to avoid drift.
                target = start + (i + len(block)) / 16000
                await asyncio.sleep(max(0.0, target - time.monotonic()))
            records.append({"t": stamp(), "dir": "audio_end", "audio_s": round(len(audio) / 16000, 3)})
            if args.trailing_silence_s:
                silence = np.zeros(int(16000 * args.trailing_silence_s), dtype=np.float32)
                for i in range(0, len(silence), chunk):
                    block = silence[i : i + chunk]
                    payload = block.astype("<f4").tobytes() if args.format == "pcm_f32le" else (block * 0).astype("<i2").tobytes()
                    await ws.send(payload)
                    await asyncio.sleep(args.chunk_ms / 1000)
            await ws.send(json.dumps({"type": "end"}))
            records.append({"t": stamp(), "dir": "sent_end"})

        send_task = asyncio.create_task(sender())
        try:
            async for message in ws:
                rec = {"t": stamp(), "dir": "recv"}
                if isinstance(message, bytes):
                    rec["binary_len"] = len(message)
                else:
                    rec["frame"] = json.loads(message)
                records.append(rec)
        except websockets.ConnectionClosed as exc:
            records.append({"t": stamp(), "dir": "closed_exc", "code": exc.code, "reason": exc.reason})
        await send_task
        records.append({"t": stamp(), "dir": "closed", "code": ws.close_code, "reason": ws.close_reason})

    with open(args.out, "w") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")
    print(f"wrote {len(records)} records to {args.out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("wav")
    parser.add_argument("out")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--chunk-ms", type=int, default=40)
    parser.add_argument("--format", default="pcm_f32le", choices=["pcm_f32le", "pcm_s16le"])
    parser.add_argument("--trailing-silence-s", type=float, default=1.5)
    asyncio.run(run(parser.parse_args()))
