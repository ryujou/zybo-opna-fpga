#!/usr/bin/env python3
"""
upload_raw_preload.py — Minimal CLI to upload a raw OPNA preload binary
via USB and trigger buffered playback.

Usage:
  python upload_raw_preload.py --input build/opna_test_tone.bin [--device auto] [--play]

The script does NOT modify:
  - USB protocol
  - upload_song / play_buffered protocol
  - PC event format
  - The existing GUI

It reuses protocol.ZyboTransport unchanged.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Ensure the pc_player directory is on sys.path
_REPO_ROOT = Path(__file__).resolve().parent.parent
_PC_PLAYER = _REPO_ROOT / "opl3_fpga" / "pc_player"
if str(_PC_PLAYER) not in sys.path:
    sys.path.insert(0, str(_PC_PLAYER))

from protocol import ZyboTransport, list_usb_devices, ProtocolError  # noqa: E402


def resolve_device(device_key: str) -> str:
    """Return a specific device key, or auto-pick the first OPL3 device."""
    if device_key != "auto":
        return device_key

    devices = list_usb_devices()
    if not devices:
        raise ProtocolError("未找到任何 Zybo OPL3 USB 设备")
    key = devices[0].key
    print(f"Auto-selected device: {key}")
    return key


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upload raw OPNA preload binary and (optionally) play it."
    )
    parser.add_argument(
        "--device",
        default="auto",
        help="USB device key from list_usb_devices(), or 'auto' (default: auto)",
    )
    parser.add_argument(
        "--input",
        required=True,
        help="Path to the preload binary file (e.g. build/opna_test_tone.bin)",
    )
    parser.add_argument(
        "--play",
        action="store_true",
        help="Start buffered playback after upload",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.is_file():
        print(f"ERROR: file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    data = input_path.read_bytes()
    if not data:
        print("ERROR: preload file is empty", file=sys.stderr)
        sys.exit(1)

    device_key = resolve_device(args.device)

    transport = ZyboTransport(device_key, timeout=3.0)
    try:
        print("Opening device...")
        hello = transport.open()
        print(
            f"Connected: v{hello.version_major}.{hello.version_minor}, "
            f"preload_capacity={hello.preload_capacity}, "
            f"upload_chunk={hello.upload_chunk_bytes}"
        )

        if hello.preload_capacity and len(data) > hello.preload_capacity:
            print(
                f"WARNING: preload binary ({len(data)} bytes) exceeds "
                f"reported capacity ({hello.preload_capacity} bytes) — upload may fail"
            )

        print(f"Uploading {len(data)} bytes...")
        transport.upload_song(data)
        print("Upload complete.")

        if args.play:
            print("Starting buffered playback...")
            transport.play_buffered()
            print("Playback started.")
        else:
            print("Use --play to start playback after upload.")

    except ProtocolError as exc:
        print(f"Protocol error: {exc}", file=sys.stderr)
        sys.exit(2)
    except Exception as exc:
        print(f"Unexpected error: {exc}", file=sys.stderr)
        sys.exit(3)
    finally:
        transport.close()


if __name__ == "__main__":
    main()
