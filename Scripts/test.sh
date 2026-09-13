#!/usr/bin/env bash
# Runs every Cicero test runner. Optional first argument filters by test name.
#
# `swift test` is NOT usable on this machine: without Xcode there is no `xctest`
# binary to load the bundle SwiftPM builds, so it exits 0 having run nothing.
# The runners are executables instead, and this script drives them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FILTER="${1:-}"
RUNNERS=(CiceroKitTests CiceroAudioTests CiceroWhisperTests CiceroPolishTests CiceroInputTests)

ran=0
failed=0
skipped=0
for runner in "${RUNNERS[@]}"; do
    [ -d "Tests/$runner" ] || continue
    echo "── $runner"

    output=""
    status=0
    if [ -n "$FILTER" ]; then
        output="$(swift run "$runner" --filter "$FILTER" 2>&1)" || status=$?
    else
        output="$(swift run "$runner" 2>&1)" || status=$?
    fi
    printf '%s\n' "$output"

    # A filter that matches nothing in this runner is not a failure: with
    # several runners, any filter necessarily misses most of them. Swift
    # Testing reports "0 tests" and exits non-zero in that case, so tell it
    # apart from a genuine failure rather than counting it as one.
    # Anchored to Swift Testing's summary line, and fed by a here-string rather
    # than a pipe: under `pipefail` a pipe into `grep -q` can return SIGPIPE on
    # large build output and turn a skip back into a reported failure.
    if [ "$status" -ne 0 ] && [ -n "$FILTER" ] && grep -q "Test run with 0 tests" <<<"$output"; then
        skipped=$((skipped + 1))
        echo "   (nenhum teste corresponde a \"$FILTER\" neste runner)"
        continue
    fi

    ran=$((ran + 1))
    [ "$status" -eq 0 ] || failed=$((failed + 1))
done

if [ "$ran" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "Nenhum runner de teste encontrado." >&2
    exit 1
fi
if [ "$ran" -eq 0 ]; then
    echo "Nenhum teste corresponde a \"$FILTER\" em nenhum runner." >&2
    exit 1
fi
if [ "$failed" -gt 0 ]; then
    echo "FALHOU: $failed de $ran runners." >&2
    exit 1
fi
echo "OK: $ran runner(s)."
