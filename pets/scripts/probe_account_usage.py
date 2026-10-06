#!/usr/bin/env python3
"""Read account token metrics with the already-authorized local Codex CLI.

No login, inference, credential-file reads, reset consumption, or raw logging.
Only whitelisted usage fields are printed; unknown numeric metrics stay null.
"""

import argparse
import contextlib
import datetime
import json
import os
import selectors
import shutil
import subprocess
import time


class ProbeError(Exception):
    pass


def nonnegative_integer(value):
    return value if type(value) is int and value >= 0 else None


def fetch_usage(executable, timeout):
    process = subprocess.Popen(
        [executable, "app-server", "-c", "analytics.enabled=false"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray()
    deadline = time.monotonic() + timeout

    def send(message):
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()

    def receive(expected_id):
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, _, rest = buffer.partition(b"\n")
                buffer[:] = rest
                try:
                    reply = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if not isinstance(reply, dict):
                    continue
                if "method" in reply and "id" in reply:
                    # Refuse unsolicited authorization or other server requests.
                    send({"id": reply["id"], "error": {
                        "code": -32601, "message": "Read-only probe refuses server requests"
                    }})
                    raise ProbeError("server_request_refused")
                if reply.get("id") != expected_id:
                    continue
                if "error" in reply:
                    error = reply["error"]
                    code = error.get("code") if isinstance(error, dict) else None
                    # Do not expose arbitrary server error strings or identity data.
                    raise ProbeError(f"rpc_error_code:{code}")
                result = reply.get("result")
                if not isinstance(result, dict):
                    raise ProbeError("invalid_response")
                return result
            if not selector.select(max(0, min(0.25, deadline - time.monotonic()))):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise ProbeError("process_exited")
            buffer.extend(chunk)
            if len(buffer) > 2 * 1024 * 1024:
                raise ProbeError("response_too_large")
        raise ProbeError("timeout")

    try:
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "huantai_pets_probe", "title": "Token Pet Research", "version": "0.1.0"},
            "capabilities": {"experimentalApi": False, "requestAttestation": False, "explicitGatewayOauth": True},
        }})
        receive(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/usage/read", "params": {}})
        payload = receive(2)
        raw_summary = payload.get("summary")
        summary = raw_summary if isinstance(raw_summary, dict) else {}
        buckets = payload.get("dailyUsageBuckets")
        daily = None
        if isinstance(buckets, list):
            daily = []
            for bucket in buckets:
                if not isinstance(bucket, dict):
                    continue
                date = bucket.get("startDate")
                count = nonnegative_integer(bucket.get("tokens"))
                if isinstance(date, str) and len(date) == 10 and count is not None:
                    try:
                        datetime.date.fromisoformat(date)
                    except ValueError:
                        continue
                    daily.append({"startDate": date, "tokens": count})
        return {
            "method": "account/usage/read", "status": "ok",
            "summary": {key: nonnegative_integer(summary.get(key)) for key in (
                "lifetimeTokens", "peakDailyTokens", "longestRunningTurnSec", "currentStreakDays", "longestStreakDays"
            )},
            "dailyUsageBuckets": daily,
        }
    finally:
        selector.close()
        with contextlib.suppress(OSError):
            process.stdin.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if not args.codex:
        parser.error("codex executable unavailable")
    if not 0 < args.timeout <= 60:
        parser.error("timeout must be greater than 0 and at most 60 seconds")
    try:
        result = fetch_usage(args.codex, args.timeout)
    except (ProbeError, OSError) as error:
        reason = str(error) if isinstance(error, ProbeError) else type(error).__name__
        print(json.dumps({"status": "unavailable", "reason": reason}))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
