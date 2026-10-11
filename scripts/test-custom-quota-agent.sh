#!/bin/zsh
set -euo pipefail
agent_root="${0:A:h:h}"
cd "$agent_root"
agent_output=$(mktemp -d /tmp/paul-custom-agent-fixture.XXXXXX)
print -r -- "Evidence: $agent_output"
swiftc -suppress-warnings -swift-version 6 -D CUSTOM_QUOTA_AGENT_FIXTURE Sources/PaulCustomQuotaAgentV1/main.swift -o "$agent_output/agent-fixture"
swiftc -suppress-warnings -swift-version 6 Sources/PaulCustomQuotaAgentV1/main.swift -o "$agent_output/agent-production"
for agent_variant in before after; do
  agent_flags=()
  if [[ "$agent_variant" == after ]]; then agent_flags=(-D CLIENT_AFTER_UPDATE); fi
  swiftc -suppress-warnings -swift-version 6 -parse-as-library $agent_flags \
    Sources/PaulNotchCore/QuotaCredentialAgentClient.swift Sources/PaulNotchCore/QuotaConnectionModels.swift \
    Tests/QuotaOverview/CustomQuotaAgentValidation.swift -o "$agent_output/client-$agent_variant"
done
trap '"$agent_output/client-before" remove "$agent_output/accounts.keychain" "$agent_output/agent-fixture" >/dev/null 2>&1 || true' EXIT
"$agent_output/client-before" create "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
"$agent_output/client-before" read "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
"$agent_output/client-after" read "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
"$agent_output/client-after" scope "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
"$agent_output/client-after" delete-one "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
"$agent_output/client-before" remove "$agent_output/accounts.keychain" "$agent_output/agent-fixture"
if "$agent_output/agent-production" </dev/null > "$agent_output/untrusted-response"; then
  print -u2 'FAIL: production custom helper accepted an untrusted parent'; exit 1
fi
[[ ! -s "$agent_output/untrusted-response" ]]
print -r -- 'PASS: new independent scope, separate accounts, changed-caller cold reads and noninteractive parent boundary'
