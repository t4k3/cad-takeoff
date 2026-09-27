#!/usr/bin/env bash
# Local verification, without API keys or live calls to AI providers.
# Usage (also from another directory): /path/to/FUSION-TAKEOFF/scripts/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in swift python3 xcrun xcodegen xcodebuild; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Strumento richiesto non trovato: %s\n' "$tool" >&2
        exit 127
    fi
done

mkdir -p build/ci
ci_run_dir=$(mktemp -d "$PWD/build/ci/run.XXXXXX")
printf 'Log della verifica: %s\n' "$ci_run_dir"

run_step() {
    local label="$1"
    shift
    printf '\n>>> %s\n' "$label"
    if "$@" 2>&1 | tee "$ci_run_dir/$label.log"; then
        printf 'OK: %s\n' "$label"
    else
        local status=$?
        printf 'FALLITO: %s (exit %s). Log: %s\n' "$label" "$status" "$ci_run_dir" >&2
        exit "$status"
    fi
}

run_step 01-core swift test --package-path Packages/CADCore
run_step 02-assistant bash scripts/test-assistant-tools.sh
run_step 02b-history bash scripts/test-design-history.sh
run_step 02c-camera bash scripts/test-camera.sh
run_step 02d-shaders bash scripts/test-shaders.sh
run_step 02e-sketch bash scripts/test-sketch.sh
run_step 02f-circuiti bash scripts/test-electronics.sh
run_step 02g-circuiti-app bash scripts/test-circuits.sh
run_step 03-mcp bash scripts/test-mcp-integration.sh
run_step 04-openai bash scripts/test-openai-provider.sh
run_step 05-connector python3 -m unittest discover -s Tests/ChatGPTConnector -v
run_step 06-3mf bash scripts/test-3mf.sh
run_step 07-sheet-metal bash scripts/test-sheet-metal.sh
run_step 07b-fusion-addin bash scripts/test-fusion-addin.sh
run_step 08-app bash scripts/build.sh
printf '\nVerifica completa: %s passaggi riusciti. Log: %s\n' "$(grep -c '^run_step ' "$0")" "$ci_run_dir"
