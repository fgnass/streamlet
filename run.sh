#!/bin/bash
# Debug build without an app bundle. Use ./build.sh install for a real app.
set -e
cd "$(dirname "$0")"
swift build
.build/debug/Streamlet
