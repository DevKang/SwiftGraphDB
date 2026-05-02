#!/usr/bin/env bash
# Doc-coverage check for SwiftGraphDB. Counts the ratio of top-level `public` declarations
# that have an immediately preceding `///` triple-slash comment. Exits non-zero if coverage
# is below the threshold (default 100%, override with --threshold N).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THRESHOLD=100

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2;;
        *) echo "usage: $0 [--threshold N]" >&2; exit 2;;
    esac
done

python3 - <<'PY' "$REPO_ROOT" "$THRESHOLD"
import os, re, sys
repo, threshold = sys.argv[1], int(sys.argv[2])
roots = [os.path.join(repo, p) for p in
         ('Sources/SwiftGraphDB', 'Sources/SwiftGraphDBCloudKit')]
docced = total = 0
missing = []
for root in roots:
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.swift'):
                continue
            path = os.path.join(dp, f)
            with open(path) as fh:
                lines = fh.readlines()
            for i, line in enumerate(lines):
                if re.match(r'^public ', line):
                    total += 1
                    j = i - 1
                    while j >= 0 and (lines[j].strip() == '' or lines[j].lstrip().startswith('@')):
                        j -= 1
                    if j >= 0 and lines[j].lstrip().startswith('///'):
                        docced += 1
                    else:
                        missing.append(f"{path}:{i+1}: {line.strip()[:100]}")

ratio = (100 * docced // total) if total else 0
print(f"Doc coverage: {docced}/{total} = {ratio}%  (threshold {threshold}%)")
if ratio < threshold:
    print("Symbols missing a /// comment:")
    for m in missing:
        print("  ", m)
    sys.exit(1)
PY
