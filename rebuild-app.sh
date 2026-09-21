#!/bin/bash
# Rebuild GalaxySim.app after changing source.
# Only needed when the code changes — otherwise just double-click the app.
set -e
cd "$(dirname "$0")"
swift build -c release
mkdir -p GalaxySim.app/Contents/{MacOS,Resources}
cp Packaging/Info.plist GalaxySim.app/Contents/Info.plist
cp .build/release/GalaxySim GalaxySim.app/Contents/MacOS/
rm -rf GalaxySim.app/Contents/Resources/GalaxySim_GalaxySim.bundle
cp -R .build/release/GalaxySim_GalaxySim.bundle GalaxySim.app/Contents/Resources/
echo "GalaxySim.app updated — double-click it, or: open GalaxySim.app"
