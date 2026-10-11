#!/usr/bin/env bash
# Writes Google OAuth credentials into Config.local.xcconfig without disturbing
# any other settings already in there (such as DEVELOPMENT_TEAM).
#
# Usage: tools/set-credentials.sh <client-id> <client-secret>
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <client-id> <client-secret>" >&2
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
config="$root/Config.local.xcconfig"
touch "$config"

set_key() {
    local key="$1" value="$2"
    if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$config"; then
        # Rewrite in place, preserving every other line.
        awk -v k="$key" -v v="$value" '
            $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { print k " = " v; next }
            { print }
        ' "$config" > "$config.tmp" && mv "$config.tmp" "$config"
    else
        printf '%s = %s\n' "$key" "$value" >> "$config"
    fi
}

set_key GPTV_CLIENT_ID "$1"
set_key GPTV_CLIENT_SECRET "$2"
chmod 600 "$config"

echo "Credentials written to Config.local.xcconfig (git-ignored)."
echo "Current keys:"
sed -E 's/(SECRET[[:space:]]*=[[:space:]]*).*/\1<hidden>/' "$config" | grep -E "=" | sed 's/^/  /'
