#!/bin/bash
# Runs the gesture, calibration, dwell click, signal check and bite detection logic against
# simulated motion; no earbuds needed.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    Sources/Cerebro/Gestures.swift Sources/Cerebro/Calibrator.swift Sources/Cerebro/Dwell.swift \
    Sources/Cerebro/SignalRecorder.swift Sources/Cerebro/Bite.swift Tests/main.swift -o build/simulate
./build/simulate
