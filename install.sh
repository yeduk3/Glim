#!/bin/bash
# Build (Release) + install to /Applications + register + set default md handler + reset Quick Look.
set -e
cd "$(dirname "$0")"

DD="${GLIM_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/glim-build}"
./build.sh Release
APP="$DD/Build/Products/Release/Glim.app"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "Install -> /Applications/Glim.app"
rm -rf /Applications/Glim.app
cp -R "$APP" /Applications/Glim.app

# avoid duplicate bundle-id copies confusing Launch Services
"$LSREG" -u "$APP" 2>/dev/null || true
"$LSREG" -f /Applications/Glim.app

# set Glim as default app for Markdown
swift - <<'SWIFT' 2>/dev/null || true
import AppKit
import UniformTypeIdentifiers
let sem = DispatchSemaphore(value: 0)
if let md = UTType("net.daringfireball.markdown") {
    Task {
        try? await NSWorkspace.shared.setDefaultApplication(
            at: URL(fileURLWithPath: "/Applications/Glim.app"), toOpen: md)
        sem.signal()
    }
    sem.wait()
}
SWIFT

qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "Done. Default md app + Quick Look ready."
