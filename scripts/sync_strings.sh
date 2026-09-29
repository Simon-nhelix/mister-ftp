#!/bin/bash
# Collects the UI strings the code uses and merges them into Resources/Localizable.xcstrings.
# The Korean text in the code is the key. After a run, give each string listed as
# "needs English" a translation (in Xcode, or in the JSON), then rebuild the app.
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Resources/Localizable.xcstrings
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/strings"

# A clean build in its own folder: the compiler lists strings only for the files it
# compiles, and an incremental build would make unchanged files look empty.
swift build --product MiSTerFTP --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/strings/*.stringsdata

python3 - "$CATALOG" <<'EOF'
import collections, json, sys

path = sys.argv[1]
catalog = json.load(open(path), object_pairs_hook=collections.OrderedDict)
missing = []
for key, entry in catalog["strings"].items():
    localizations = entry.setdefault("localizations", collections.OrderedDict())
    # Every key needs a Korean entry. Without one, macOS shows Korean users the
    # English text, because English is the development (fallback) language.
    unit = localizations.get("ko", {}).get("stringUnit", {})
    localizations["ko"] = {"stringUnit": {"state": "translated", "value": unit.get("value", key)}}
    if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale" and "en" not in localizations:
        missing.append(key)
catalog["strings"] = collections.OrderedDict(sorted(catalog["strings"].items()))
with open(path, "w") as file:
    json.dump(catalog, file, ensure_ascii=False, indent=2, separators=(",", " : "))
    file.write("\n")
stale = [key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "stale"]
for key in missing:
    print(f"needs English: {key}")
for key in stale:
    print(f"no longer used: {key}")
print(f"{len(catalog['strings'])} strings, {len(missing)} need English, {len(stale)} no longer used")
EOF
