#!/bin/sh
# Runs the headless test suite. Set ASEPRITE to the binary if it is not found.
set -e
cd "$(dirname "$0")/.."
bin=${ASEPRITE:-$(command -v aseprite || echo /Applications/Aseprite.app/Contents/MacOS/aseprite)}
out=$(mktemp -d)
"$bin" -b --script-param root="$PWD" --script-param out="$out" --script test/run.lua | tee "$out/log.txt"
grep -q "ALL PASSED" "$out/log.txt"
