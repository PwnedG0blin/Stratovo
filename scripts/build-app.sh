#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Stratovo benötigt einen Apple-Silicon-Mac und ein natives Terminal (ohne Rosetta)." >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Bitte Xcode beziehungsweise die Xcode Command Line Tools installieren." >&2
    exit 1
fi
# Build with the Liquid Glass SDK; deployment remains macOS 14.
# Select a suitable installed Xcode for this process only.
sdk_major="$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)"
if [[ "$sdk_major" -lt 26 ]]; then
    for xcode_candidate in /Applications/Xcode*.app; do
        candidate_developer="$xcode_candidate/Contents/Developer"
        candidate_sdk="$(DEVELOPER_DIR="$candidate_developer" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
        candidate_major="${candidate_sdk%%.*}"
        if [[ "$candidate_major" =~ ^[0-9]+$ && "$candidate_major" -ge 26 ]]; then
            export DEVELOPER_DIR="$candidate_developer"
            sdk_major="$candidate_major"
            break
        fi
    done
fi
if [[ "$sdk_major" -lt 26 ]]; then
    echo "Zum Bauen der App wird Xcode 26 oder neuer mit macOS-SDK 26 benötigt." >&2
    exit 1
fi
cd "$project_dir"
python3 scripts/test-hvf-memory.py
python3 scripts/test-scanout-snapshot.py
python3 scripts/test-embedded-display.py
python3 scripts/test-player-surfaces.py
python3 scripts/test-native-geometry.py
python3 scripts/test-native-window.py
python3 scripts/test-display-rate.py
python3 -m unittest discover -s Tests/GraphicsLabTests -q
python3 -m unittest discover -s Tests/AndroidDataTests -q
xcrun swift test
xcrun swift build -c release --arch arm64
binary_dir="$(xcrun swift build -c release --arch arm64 --show-bin-path)"
app_path="$project_dir/dist/Stratovo.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Stratovo" "$app_path/Contents/MacOS/Stratovo"
/usr/bin/ditto "$binary_dir/Stratovo_StratovoCore.bundle" "$app_path/Contents/Resources/Stratovo_StratovoCore.bundle"
cp "$project_dir/Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/LICENSE" "$project_dir/AUTHORS.md" "$project_dir/THIRD_PARTY_NOTICES.md" "$project_dir/SIGNIERUNG.md" "$app_path/Contents/Resources/"
cp "$project_dir/Android_Werkzeuge_einrichten.command" "$project_dir/Android_einrichten.command" "$project_dir/Android_System_verwalten.command" "$project_dir/Android_Streaming_einrichten.command" "$project_dir/Windows_Treiber_einrichten.command" "$app_path/Contents/Resources/"
cp "$project_dir/LIES_MICH_ZUERST.md" "$app_path/Contents/Resources/"
cp "$project_dir/Android_Daten_uebernehmen.py" "$app_path/Contents/Resources/"
cp "$project_dir/Packaging/install-update.sh" "$app_path/Contents/Resources/"
/usr/bin/ditto "$project_dir/Packaging/GraphicsLab" "$app_path/Contents/Resources/GraphicsLab"
# Remove obsolete generated helpers when rebuilding into an existing output folder.
rm -f "$app_path/Contents/Resources/Aufraeumen.command" \
    "$app_path/Contents/Resources/scripts/storage-cleanup.py" \
    "$app_path/Contents/Resources/scripts/trash-packages.swift" \
    "$project_dir/dist/private-installer/Aufraeumen.command"
test -f "$project_dir/Packaging/WindowsExchange/Stratovo.exe"
/usr/bin/ditto "$project_dir/Packaging/WindowsExchange" "$app_path/Contents/Resources/WindowsExchange"
bash scripts/build-icon.sh
# Local development signature only. It is not Developer ID signing or notarization.
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
python3 scripts/test-relocated-app.py "$app_path" "$binary_dir"
echo "Lokale Test-App erstellt: $app_path"
if [[ "${1:-}" == "--open" ]]; then /usr/bin/open "$app_path"; fi

