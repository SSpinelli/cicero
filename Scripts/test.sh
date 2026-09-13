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
for runner in "${RUNNERS[@]}"; do
    [ -d "Tests/$runner" ] || continue
    ran=$((ran + 1))
    echo "── $runner"
    if [ -n "$FILTER" ]; then
        swift run "$runner" --filter "$FILTER" || failed=$((failed + 1))
    else
        swift run "$runner" || failed=$((failed + 1))
    fi
done

if [ "$ran" -eq 0 ]; then
    echo "Nenhum runner de teste encontrado." >&2
    exit 1
fi
if [ "$failed" -gt 0 ]; then
    echo "FALHOU: $failed de $ran runners." >&2
    exit 1
fi
echo "OK: $ran runner(s)."
