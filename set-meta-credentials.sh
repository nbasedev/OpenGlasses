#!/usr/bin/env bash
# Write the Meta DAT credentials into the gitignored project.local.yml, regenerate
# the Xcode project, rebuild, and install to the phone.
#
# Usage:
#   bash set-meta-credentials.sh <META_APP_ID> <CLIENT_TOKEN_OR_HASH>
#
# The client token reads AR|<app id>|<hash>; only the trailing hash is stored,
# because OpenGlasses/Info.plist composes the "AR|…|…" form itself. Passing the
# whole token is fine — the hash is extracted.

set -euo pipefail
cd "$(dirname "$0")"

APP_ID="${1:-}"
TOKEN="${2:-}"
DEVICE="${3:-4E28ED00-FE43-5346-87F0-8BC866C157FB}"

if [ -z "$APP_ID" ] || [ -z "$TOKEN" ]; then
    echo "usage: bash set-meta-credentials.sh <META_APP_ID> <CLIENT_TOKEN_OR_HASH>" >&2
    exit 1
fi

# Accept either the full AR|<id>|<hash> token or just the hash.
HASH="$TOKEN"
case "$TOKEN" in
    AR\|*) HASH="${TOKEN##*|}" ;;
esac

if [ -z "$HASH" ] || [ "$HASH" = "$APP_ID" ]; then
    echo "Could not read a client-token hash from: $TOKEN" >&2
    exit 1
fi

python3 - "$APP_ID" "$HASH" <<'PY'
import re, sys
app_id, token_hash = sys.argv[1], sys.argv[2]
p = "project.local.yml"
s = open(p).read()
s = re.sub(r'(MWDAT_META_APP_ID:\s*").*?(")',        rf'\g<1>{app_id}\g<2>',     s)
s = re.sub(r'(MWDAT_CLIENT_TOKEN_HASH:\s*").*?(")',  rf'\g<1>{token_hash}\g<2>', s)
open(p, "w").write(s)
print(f"set MWDAT_META_APP_ID={app_id}  hash=…{token_hash[-6:]}")
PY

echo "⚙️  regenerating project…"
bash Scripts/generate-xcodeproj.sh >/dev/null

# The validator rejects any value still containing "YOUR_" or an unexpanded $( ),
# so confirm substitution landed before spending time on a build.
python3 - <<'PY'
import plistlib, subprocess, sys
# The authored plist keeps $(…) references; check the generated build settings instead.
out = subprocess.run(
    ["xcodebuild", "-project", "OpenGlasses.xcodeproj", "-target", "OpenGlasses",
     "-showBuildSettings", "-configuration", "Debug"],
    capture_output=True, text=True).stdout
vals = {}
for line in out.splitlines():
    for key in ("MWDAT_META_APP_ID", "MWDAT_CLIENT_TOKEN_HASH"):
        if f" {key} = " in line:
            vals[key] = line.split(" = ", 1)[1].strip()
bad = [k for k, v in vals.items() if not v or "YOUR_" in v or "$(" in v]
if bad or len(vals) < 2:
    print("credentials did not substitute:", vals, file=sys.stderr)
    sys.exit(1)
print("credentials substituted OK")
PY

echo "🔨 building…"
xcodebuild -project OpenGlasses.xcodeproj -scheme OpenGlasses \
    -destination "id=${DEVICE}" -configuration Debug \
    -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (FAILED|SUCCEEDED)"

APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenGlasses-*/Build/Products/Debug-iphoneos \
      -maxdepth 1 -name "OpenGlasses.app" 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "built app not found" >&2; exit 1; }

echo "📲 installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | grep -E "App installed|bundleID|error"

echo
echo "Done. Open OpenGlasses and tap Connect to Glasses."
