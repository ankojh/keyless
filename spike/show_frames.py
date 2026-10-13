"""Print a recorded protocol JSONL file as a compact timeline."""

import json
import sys

for path in sys.argv[1:]:
    print("=====", path)
    for line in open(path):
        rec = json.loads(line)
        frame = rec.get("frame")
        if frame:
            seg = frame.get("segment", "")
            text = frame.get("text", "")
            print(f"{rec['t']:7.2f} {frame['type']:8} seg={seg!s:3} keys={sorted(frame)} | {text[-100:]}")
        else:
            print(f"{rec['t']:7.2f} -- {rec}")
