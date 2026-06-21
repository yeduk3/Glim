#!/bin/bash
# Build Glim to DerivedData OUTSIDE the source tree.
# In-tree build output gets crawled by Spotlight + Xcode/VSCode indexers ->
# concurrent swift-frontend/mdworker spikes -> system memory pressure on low-RAM Macs.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
DD="${GLIM_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/glim-build}"

command -v xcodegen >/dev/null && xcodegen generate

echo "Building $CONFIG -> $DD"
xcodebuild -project Glim.xcodeproj -scheme Glim -configuration "$CONFIG" \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="-" build

echo "Built: $DD/Build/Products/$CONFIG/Glim.app"
