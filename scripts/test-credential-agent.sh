#!/bin/zsh
set -euo pipefail
agent_root="${0:A:h:h}"
cd "$agent_root"
agent_output=$(mktemp -d /tmp/paul-agent-fixture.XXXXXX)
print -r -- "Evidence: $agent_output"
swiftc -suppress-warnings -swift-version 6 -D CREDENTIAL_AGENT_FIXTURE \
  Sources/PaulCredentialAgent/main.swift -o "$agent_output/agent-fixture"
swiftc -suppress-warnings -swift-version 6 Sources/PaulCredentialAgent/main.swift -o "$agent_output/agent-production"
for agent_variant in before after; do
  agent_flags=()
  if [[ "$agent_variant" == after ]]; then agent_flags=(-D CLIENT_AFTER_UPDATE); fi
  swiftc -suppress-warnings -swift-version 6 -parse-as-library $agent_flags \
    Sources/PaulNotchCore/QuotaCredentialAgentClient.swift Sources/PaulNotchCore/QuotaConnectionModels.swift \
    Tests/QuotaOverview/CredentialAgentPersistenceValidation.swift -o "$agent_output/client-$agent_variant"
done
"$agent_output/client-before" create "$agent_output/legacy.keychain" "$agent_output/agent-fixture"
"$agent_output/client-before" legacy-save "$agent_output/legacy.keychain" "$agent_output/agent-fixture"
if "$agent_output/client-after" legacy-read "$agent_output/legacy.keychain" "$agent_output/agent-fixture"; then
  print -u2 'FAIL: pre-fix reproduction must reject the changed caller binary'; exit 1
fi
"$agent_output/client-before" remove "$agent_output/legacy.keychain" "$agent_output/agent-fixture"
"$agent_output/client-before" create "$agent_output/stable.keychain" "$agent_output/agent-fixture"
for agent_operation in save read lock read-locked unlock read rotate read-rotated large delete read-missing; do
  "$agent_output/client-before" "$agent_operation" "$agent_output/stable.keychain" "$agent_output/agent-fixture"
  if [[ "$agent_operation" == read || "$agent_operation" == read-rotated || "$agent_operation" == read-missing ]]; then
    "$agent_output/client-after" "$agent_operation" "$agent_output/stable.keychain" "$agent_output/agent-fixture"
  fi
done
"$agent_output/client-before" remove "$agent_output/stable.keychain" "$agent_output/agent-fixture"
if "$agent_output/agent-production" </dev/null > "$agent_output/untrusted-response"; then
  print -u2 'FAIL: production credential agent must reject an unsigned/untrusted parent'; exit 1
fi
[[ ! -s "$agent_output/untrusted-response" ]]
print -r -- 'PASS: changed-caller restart, stable read/write/rotation/deletion, bounded large pipe data, and production caller rejection'
