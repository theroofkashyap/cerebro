#!/bin/bash
# Runs the gesture and calibration logic against simulated head motion; no earbuds needed.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    Sources/Cerebro/Gestures.swift Sources/Cerebro/Calibrator.swift Tests/main.swift -o build/simulate
./build/simulate
