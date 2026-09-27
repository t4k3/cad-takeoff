#!/bin/bash
# Compile the actual app providers against an isolated transport and fake Keychain.
set -euo pipefail
cd "$(dirname "$0")/../../.."
qa_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-remote-provider.XXXXXX")
trap 'rm -rf "$qa_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  App/Sources/Integration/ToolBridge.swift \
  App/Sources/Integration/Assistant/AssistantProvider.swift \
  App/Sources/Integration/Assistant/AnthropicStream.swift \
  App/Sources/Integration/Assistant/ClaudeProvider.swift \
  App/Sources/Integration/OpenAI/*.swift \
  Tests/Electronics/RemoteProviders/Runner.swift \
  -o "$qa_dir/remote-provider-tests"
"$qa_dir/remote-provider-tests"
