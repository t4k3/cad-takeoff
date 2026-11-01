#!/bin/bash
# Offline acceptance for Claude / ChatGPT / DeepSeek and the two compatible endpoints.
# Compiles the real app providers against an isolated transport and a fake Keychain.
# Pass --live to add the 3 DeepSeek smoke requests (needs DEEPSEEK_API_KEY in the environment).
set -euo pipefail
cd "$(dirname "$0")/.."
qa_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-assistant-provider.XXXXXX")
trap 'rm -rf "$qa_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  App/Sources/Integration/ToolBridge.swift \
  App/Sources/Integration/Assistant/AssistantProvider.swift \
  App/Sources/Integration/Assistant/AnthropicStream.swift \
  App/Sources/Integration/Assistant/ClaudeProvider.swift \
  App/Sources/Integration/OpenAI/*.swift \
  Tests/AssistantProviders/Runner.swift \
  -o "$qa_dir/assistant-provider-tests"
"$qa_dir/assistant-provider-tests" "$@"
