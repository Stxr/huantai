#!/usr/bin/env python3
"""Identify Espressif native USB serial ports on macOS; optionally listen.

The listener sends no bytes, toggles no DTR/RTS explicitly, and never flashes.
Opening/closing a serial port can still affect firmware on some devices.
Only recognized CODO HELLO records are retained; arbitrary logs are discarded.
"""

import argparse
import fcntl
import json
import os
import plistlib
import re
import select
import subprocess
import termios
import time


def discover():
    result = subprocess.run(["ioreg", "-a", "-p", "IOService", "-l"], check=True, capture_output=True)
    roots = plistlib.loads(result.stdout)
    if isinstance(roots, dict):
        roots = [roots]
    devices = []

    def visit(node, ancestors):
        if not isinstance(node, dict):
            return
        port = node.get("IOCalloutDevice")
        if isinstance(port, str):
            usb = next((p for p in reversed(ancestors) if "idVendor" in p and "idProduct" in p), None)
            if usb and usb["idVendor"] == 0x303A and usb["idProduct"] == 0x1001:
                devices.append({"port": port, "vendor_id": "303a", "product_id": "1001", "vendor": "Espressif"})
        for child in node.get("IORegistryEntryChildren", []):
            visit(child, ancestors + [node])

    for root in roots:
        visit(root, [])
    return devices


def listen(port, seconds):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    original = None
    try:
        # Advisory exclusivity; never seize a port held by a cooperating process.
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = termios.tcgetattr(fd)
        settings = original[:]
        settings[6] = original[6][:]
        settings[0] = settings[1] = settings[3] = 0
        settings[2] = (settings[2] & ~(termios.PARENB | termios.CSTOPB | termios.CSIZE | termios.HUPCL)) | termios.CS8 | termios.CREAD | termios.CLOCAL
        settings[4] = settings[5] = termios.B115200
        settings[6][termios.VMIN] = settings[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, settings)
        deadline = time.monotonic() + seconds
        pending = bytearray()
        received_bytes = 0
        records = set()
        record_count = 0
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                continue
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                break
            received_bytes += len(chunk)
            pending.extend(chunk)
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending[:] = rest
                text = line.decode("ascii", errors="ignore").strip()
                if re.fullmatch(r"CODO HELLO \d+ \d+ \d+ \d+", text):
                    record_count += 1
                    records.add(text)
            if len(pending) > 16384:
                pending.clear()
            if received_bytes > 1024 * 1024:
                break
        return {"baud": 115200, "received_bytes": received_bytes, "transmitted_bytes": 0,
                "explicit_reset_requested": False, "hello_count": record_count, "hello_samples": sorted(records)[:3]}
    finally:
        try:
            if original is not None:
                termios.tcsetattr(fd, termios.TCSANOW, original)
        finally:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=float, default=0, metavar="SECONDS")
    parser.add_argument("--port", help="Must match an enumerated Espressif 303a:1001 device")
    args = parser.parse_args()
    if not 0 <= args.listen <= 30:
        parser.error("listen duration must be between 0 and 30 seconds")
    devices = discover()
    result = {"devices": devices, "detection": "found" if devices else "not_found"}
    if args.listen:
        candidates = [d for d in devices if args.port is None or d["port"] == args.port]
        if len(candidates) != 1:
            parser.error("listening requires exactly one matching device")
        result["observation"] = listen(candidates[0]["port"], args.listen)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
