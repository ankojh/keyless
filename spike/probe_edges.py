"""Probe Phonon-2 WebSocket edge cases: bad auth, a second concurrent stream, and an idle stream.

Usage: probe_edges.py OUT_JSON [--port 8765] [--idle]
--idle waits for the documented 90 s no-input timeout, which takes about 95 s.
"""

import argparse
import asyncio
import json
import pathlib
import time

import websockets

HERE = pathlib.Path(__file__).resolve().parent


async def collect(ws, limit_s: float) -> list:
    frames = []
    try:
        async with asyncio.timeout(limit_s):
            async for message in ws:
                frames.append(message if isinstance(message, str) else f"<{len(message)} bytes>")
    except TimeoutError:
        frames.append("<timeout>")
    except websockets.ConnectionClosed as exc:
        frames.append(f"<closed {exc.code} {exc.reason!r}>")
    return frames


async def main(args: argparse.Namespace) -> None:
    key = (HERE / ".local-key").read_text().strip()
    url = f"ws://127.0.0.1:{args.port}/v1/audio/stream"
    good = {"Authorization": f"Bearer {key}"}
    results = {}

    try:
        async with websockets.connect(url, additional_headers={"Authorization": "Bearer wrong"}) as ws:
            results["bad_auth"] = await collect(ws, 3)
    except websockets.InvalidStatus as exc:
        results["bad_auth"] = f"handshake rejected HTTP {exc.response.status_code}"

    try:
        async with websockets.connect(url) as ws:
            results["no_auth"] = await collect(ws, 3)
    except websockets.InvalidStatus as exc:
        results["no_auth"] = f"handshake rejected HTTP {exc.response.status_code}"

    async with websockets.connect(url, additional_headers=good) as first:
        await first.send(json.dumps({"sample_rate": 16000, "format": "pcm_f32le"}))
        await first.send(b"\x00" * 6400)
        async with websockets.connect(url, additional_headers=good) as second:
            # The server may refuse before the opening frame is sent, so read first.
            results["second_stream"] = await collect(second, 3)
            results["second_stream_close_code"] = second.close_code
        await first.send(json.dumps({"type": "end"}))
        results["first_stream_after_second"] = await collect(first, 5)

    async with websockets.connect(url, additional_headers=good) as ws:
        await ws.send(json.dumps({"sample_rate": 22050}))
        results["bad_sample_rate"] = await collect(ws, 3)

    if args.idle:
        async with websockets.connect(url, additional_headers=good) as ws:
            await ws.send(json.dumps({"sample_rate": 16000, "format": "pcm_f32le"}))
            start = time.monotonic()
            frames = await collect(ws, 120)
            results["idle"] = {"frames": frames, "elapsed_s": round(time.monotonic() - start, 1), "close_code": ws.close_code}

    pathlib.Path(args.out).write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--idle", action="store_true")
    asyncio.run(main(parser.parse_args()))
