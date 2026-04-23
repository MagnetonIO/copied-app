#!/bin/zsh
# xcodegen wrapper that fixes the pbxproj `SystemCapabilities` serialization
# bug. xcodegen emits `SystemCapabilities = "[...string-literal...]";` which
# Xcode's parser ignores — so Push Notifications + iCloud capabilities never
# land, and Xcode's ProcessEntitlementsFile step strips the corresponding
# entitlement keys (notably `aps-environment`) from the signed app.
#
# This script runs `xcodegen generate` then rewrites the SystemCapabilities
# lines into the proper nested-dict pbxproj syntax.
#
# Usage: ./scripts/xcodegen-patch.sh
# Call this instead of `xcodegen generate` anywhere we previously called xcodegen.

set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

python3 - <<'PY'
import re
import pathlib

pbx = pathlib.Path("Copied.xcodeproj/project.pbxproj")
text = pbx.read_text()

# Turn strings like
#   SystemCapabilities = "[\"com.apple.Push\": [\"enabled\": 1], \"com.apple.iCloud\": [\"enabled\": 1]]";
# into
#   SystemCapabilities = {
#       com.apple.Push = { enabled = 1; };
#       com.apple.iCloud = { enabled = 1; };
#   };
pattern = re.compile(
    r'SystemCapabilities = "\[(.*?)\]";'
)

def replace(match: re.Match) -> str:
    inner = match.group(1)
    # inner now looks like: \"com.apple.Push\": [\"enabled\": 1], \"com.apple.iCloud\": [\"enabled\": 1]
    # split on `], ` to iterate capabilities (accounting for the trailing ])
    caps = re.findall(r'\\"([^\\]+)\\":\s*\[\\"enabled\\":\s*(\d+)\]', inner)
    if not caps:
        return match.group(0)
    lines = ["SystemCapabilities = {"]
    for name, enabled in caps:
        lines.append(f"\t\t\t\t\t\t{name} = {{")
        lines.append(f"\t\t\t\t\t\t\tenabled = {enabled};")
        lines.append(f"\t\t\t\t\t\t}};")
    lines.append("\t\t\t\t\t};")
    return "\n".join(lines)

new_text, n = pattern.subn(replace, text)
if n == 0:
    print("xcodegen-patch: no SystemCapabilities strings found — nothing to patch")
else:
    pbx.write_text(new_text)
    print(f"xcodegen-patch: rewrote {n} SystemCapabilities blocks to pbxproj dict format")
PY
