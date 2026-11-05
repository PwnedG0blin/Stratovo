#!/bin/bash
set -euo pipefail
umask 077
app_pid="$1"
target="$2"
source_app="$3"
handoff="${4:-}"
job_label="${5:-}"
phase="Start"
stage=""
backup=""
replaced=0
finish() {
    result=$?
    trap - EXIT
    if [[ "$result" -ne 0 ]]; then
        printf 'Update fehlgeschlagen · %s · Exit %s\n' "$phase" "$result"
        if [[ -n "$backup" && -d "$backup" ]]; then
            if [[ "$replaced" -eq 1 && -d "$target" ]]; then
                /bin/mv "$target" "$stage/Failed-Stratovo.app" || true
            fi
            if [[ ! -e "$target" ]]; then
                /bin/mv "$backup" "$target" || true
                /usr/bin/open -n "$target" || true
            fi
        fi
        if [[ -n "$handoff" ]]; then printf '%s\n' "$phase" > "$handoff/failed"; fi
    fi
    if [[ -n "$job_label" ]]; then
        /bin/launchctl bootout "gui/$(id -u)/$job_label" >/dev/null 2>&1 || true
    fi
    exit "$result"
}
trap finish EXIT
printf 'Update-Helfer gestartet · %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ "$app_pid" =~ ^[0-9]+$ && "$app_pid" -gt 1 && "$app_pid" -ne "$$" ]]
[[ "$target" == /*/Stratovo.app && "$source_app" == /*/Stratovo.app ]]
[[ -d "$target" && ! -L "$target" && -d "$source_app" && ! -L "$source_app" ]]
parent="$(dirname -- "$target")"
[[ -w "$parent" ]]
if [[ -n "$handoff" ]]; then
    [[ -d "$handoff" && ! -L "$handoff" && "$handoff" == "$(dirname -- "$source_app")" ]]
fi
phase="App vorbereiten"
expected_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_app/Contents/Info.plist")"
[[ "$expected_build" =~ ^[0-9]+$ ]]
stage="$(mktemp -d "$parent/.Stratovo-update.XXXXXX")"
backup="$stage/Previous-Stratovo.app"
/usr/bin/ditto "$source_app" "$stage/Stratovo.app"
/usr/bin/codesign --verify --deep --strict "$stage/Stratovo.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/Stratovo.app/Contents/Info.plist")" == "$expected_build" ]]
printf 'App vorbereitet · Build %s\n' "$expected_build"
if [[ -n "$handoff" ]]; then
    printf '%s\n' "$expected_build" > "$handoff/ready"
    phase="Übergabe bestätigen"
    for ((attempt=0; attempt<60; attempt++)); do
        [[ -f "$handoff/commit" ]] && break
        sleep 1
    done
    [[ -f "$handoff/commit" ]]
fi
phase="Auf Stratovo warten"
for ((attempt=0; attempt<120; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$app_pid" 2>/dev/null; then echo "App wurde nicht beendet."; exit 1; fi
phase="App austauschen"
/bin/mv "$target" "$backup"
/bin/mv "$stage/Stratovo.app" "$target"
replaced=1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")" == "$expected_build" ]]
phase="Stratovo starten"
/usr/bin/open -n "$target"
printf 'Update installiert · Build %s. Vorherige App für Rückkehr: %s\n' "$expected_build" "$backup"
