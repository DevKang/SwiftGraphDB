#!/usr/bin/env bash
# SwiftGraphDB public-API drift detector.
#
# Enumerates every top-level `public` declaration in the package source and diffs it against
# Scripts/public-api-allowlist.txt. New, removed, or renamed public symbols cause a non-zero
# exit so CI can flag accidental API drift. Adding a symbol on purpose: regenerate the
# allowlist with `Scripts/audit-public-api.sh --update`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/public-api-allowlist.txt"

extract() {
    grep -rE "^public " \
        "$REPO_ROOT/Sources/SwiftGraphDB/" \
        "$REPO_ROOT/Sources/SwiftGraphDBCloudKit/" \
        --include="*.swift" -h \
    | sed -E 's/^public //; s/ \{.*//; s/ where .*//; s/\(.*//; s/<.*//' \
    | awk '{
        for (i=1; i<=NF; i++) {
            if ($i=="enum" || $i=="struct" || $i=="protocol" || $i=="actor" || \
                $i=="class" || $i=="typealias" || $i=="func" || $i=="var" || $i=="let") {
                name=$(i+1); gsub(/[:,].*$/, "", name); print $i, name; next
            }
        }
    }' \
    | sort -u
}

case "${1:-check}" in
    --update)
        extract > "$ALLOWLIST"
        echo "Updated $ALLOWLIST ($(wc -l < "$ALLOWLIST") symbols)."
        ;;
    check|"")
        TMP=$(mktemp)
        extract > "$TMP"
        if ! diff -u "$ALLOWLIST" "$TMP"; then
            echo
            echo "Public API drift detected. If intentional, run:"
            echo "  Scripts/audit-public-api.sh --update"
            rm -f "$TMP"
            exit 1
        fi
        rm -f "$TMP"
        echo "Public API matches allowlist ($(wc -l < "$ALLOWLIST") symbols)."
        ;;
    *)
        echo "usage: $0 [check|--update]" >&2
        exit 2
        ;;
esac
