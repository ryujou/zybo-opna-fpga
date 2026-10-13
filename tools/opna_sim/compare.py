import argparse
import csv
import json
from itertools import zip_longest
from pathlib import Path
import sys


def observations(path):
    with path.open(encoding="utf-8") as src:
        reader = csv.DictReader(src)
        if reader.fieldnames != ["tick", "kind", "index", "value"]:
            raise ValueError(f"invalid observation header: {path}")
        records = [(int(r["tick"]), r["kind"], int(r["index"]), int(r["value"]))
                   for r in reader]
    if not records:
        raise ValueError(f"empty observations: {path}")
    records.sort(key=lambda r: r[:3])
    for previous, current in zip(records, records[1:]):
        if previous[:3] == current[:3]:
            raise ValueError(f"duplicate observation: {path}: {current[:3]}")
    return records


def compare(expected, actual, stimulus):
    want, got = observations(expected), observations(actual)
    for index, (left, right) in enumerate(zip_longest(want, got)):
        if left != right:
            tick = min(r[0] for r in (left, right) if r is not None)
            events = [list(map(int, line.split()))
                      for line in stimulus.read_text(encoding="utf-8").splitlines()[1:]]
            before = [event for event in events if event[0] <= tick][-6:]
            after = [event for event in events if event[0] > tick][:2]
            return {"equal": False, "observation": index, "tick": tick,
                    "expected": left, "actual": right, "input_context": before + after}
    return {"equal": True, "observations": len(want)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--stimulus", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = compare(args.expected, args.actual, args.stimulus)
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["equal"] else 1


if __name__ == "__main__":
    sys.exit(main())
