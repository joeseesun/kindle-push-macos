#!/bin/bash
# Recompile the ink accent colour into mac-app/Assets/Assets.car (needs Xcode's actool).
# The compiled file is committed, so building the app needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../mac-app/Assets"
xcrun actool Colors.xcassets --compile . --platform macosx --minimum-deployment-target 14.0 >/dev/null
echo "Wrote $(pwd)/Assets.car"
