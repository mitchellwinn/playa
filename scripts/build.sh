#!/bin/sh
# Builds dist/s-playa.aseprite-extension (a zip Aseprite installs on double-click).
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json)
mkdir -p dist
rm -f dist/s-playa.aseprite-extension
zip -q -X dist/s-playa.aseprite-extension package.json LICENSE README.md src/*.lua
echo "dist/s-playa.aseprite-extension ($version)"
