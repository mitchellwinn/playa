#!/bin/sh
# Builds dist/playa.aseprite-extension (a zip Aseprite installs on double-click).
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json)
mkdir -p dist
rm -f dist/playa.aseprite-extension
zip -q -X dist/playa.aseprite-extension package.json LICENSE README.md src/*.lua
echo "dist/playa.aseprite-extension ($version)"
