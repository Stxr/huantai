#!/usr/bin/env python3
"""Inspect Token metadata in a bounded sample of local Codex JSONL files.

This is a schema/discovery probe, not a complete usage ledger or daily total.
Prints metadata availability only. Never prints messages, titles, paths, or IDs.
"""

import argparse
import json
from pathlib import Path


def inspect(path):
    event_count = valid_count = duplicate_count = decreasing_count = 0
    previous = None
    fields = set()
    models = set()
    with path.open("rb") as handle:
        while True:
            line = handle.readline(4 * 1024 * 1024 + 1)
            if not line:
                break
            if not line.endswith(b"\n"):
                # A partial record is ignored. Skip the rest of an oversized line.
                while len(line) > 4 * 1024 * 1024 and not line.endswith(b"\n"):
                    line = handle.readline(4 * 1024 * 1024 + 1)
                continue
            if len(line) > 4 * 1024 * 1024:
                continue
            try:
                record = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(record, dict):
                continue
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            if record.get("type") == "turn_context":
                model = payload.get("model")
                if isinstance(model, str) and len(model) <= 80 and all(c.isalnum() or c in "-._/" for c in model):
                    models.add(model)
            if record.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            event_count += 1
            info = payload.get("info")
            total = info.get("total_token_usage") if isinstance(info, dict) else None
            if not isinstance(total, dict):
                continue
            fields.update(key for key in total if key in {
                "total_tokens", "input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"
            })
            value = total.get("total_tokens")
            if type(value) is not int or value < 0:
                continue
            valid_count += 1
            duplicate_count += previous == value
            decreasing_count += previous is not None and value < previous
            previous = value
    return {"token_events": event_count, "valid_total_snapshots": valid_count,
            "repeated_total_snapshots": duplicate_count, "decreasing_total_snapshots": decreasing_count,
            "numeric_fields": sorted(fields), "models": sorted(models)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, action="append", help="Repeatable directory or JSONL file")
    parser.add_argument("--sample", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.sample <= 20:
        parser.error("sample must be between 1 and 20")
    roots = args.root or [Path.home() / ".codex/sessions", Path.home() / ".codex/archived_sessions"]
    files = set()
    for root in roots:
        if root.is_symlink():
            continue
        if root.is_file() and root.suffix == ".jsonl":
            files.add(root)
        elif root.is_dir():
            # Path.rglob does not follow directory symlinks; also reject symlink files.
            files.update(p for p in root.rglob("*.jsonl") if p.is_file() and not p.is_symlink())
    selected = sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)[:args.sample]
    print(json.dumps({"scope": "sample_only", "discovered_file_count": len(files),
                      "sampled_file_count": len(selected), "samples": [inspect(p) for p in selected]}, indent=2))


if __name__ == "__main__":
    main()
