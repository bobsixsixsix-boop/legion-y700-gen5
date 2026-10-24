#!/bin/bash
# One-time: Python venv for bkerler/edl (checkout in ../edl, already patched: usblib MAX_USB_BULK_BUFFER_SIZE=2048, firehose MaxPayloadSizeToTargetInBytes=16384).
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
python3 -m venv "$R/edlvenv"
"$R/edlvenv/bin/pip" install -q pyusb pyserial docopt pycryptodome pycryptodomex colorama lxml capstone
mkdir -p "$R/edl/logs"
echo "venv ready: $R/edlvenv"
