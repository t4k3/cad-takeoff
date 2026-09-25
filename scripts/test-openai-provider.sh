#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-openai.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    App/Sources/Integration/ToolBridge.swift \
    App/Sources/Integration/Assistant/AssistantProvider.swift \
    App/Sources/Integration/Assistant/Keychain.swift \
    App/Sources/Integration/OpenAI/*.swift \
    Tests/OpenAIProvider/Runner.swift -o "$test_dir/openai-tests"
"$test_dir/openai-tests"
