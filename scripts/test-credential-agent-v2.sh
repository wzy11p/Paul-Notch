#!/bin/zsh
set -euo pipefail
agent_root="${0:A:h:h}"
cd "$agent_root"
agent_source="${1:-Sources/PaulCredentialAgentV2/main.swift}"
agent_output=$(mktemp -d /tmp/paul-agent-fixture.XXXXXX)
print -r -- "Evidence: $agent_output"
swiftc -suppress-warnings -swift-version 6 -D CREDENTIAL_AGENT_FIXTURE "$agent_source" -o "$agent_output/agent-fixture"
swiftc -suppress-warnings -swift-version 6 "$agent_source" -o "$agent_output/agent-production"
for agent_variant in before after; do
  agent_flags=()
  if [[ "$agent_variant" == after ]]; then agent_flags=(-D CLIENT_AFTER_UPDATE); fi
  swiftc -suppress-warnings -swift-version 6 -parse-as-library $agent_flags \
    Sources/PaulNotchCore/QuotaCredentialAgentClient.swift Sources/PaulNotchCore/QuotaConnectionModels.swift \
    Tests/QuotaOverview/CredentialAgentPersistenceValidation.swift -o "$agent_output/client-$agent_variant"
done
trap '"$agent_output/client-before" remove "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" >/dev/null 2>&1 || true' EXIT
"$agent_output/client-before" create "$agent_output/coexisting.keychain" "$agent_output/agent-fixture"
for agent_service in local.paul.notch.quota.deepseek.v1 local.paul.notch.quota.minimax-cn-wallet.v1 local.paul.notch.quota.cursor-account.v1; do
  # A fresh stable record must coexist with, never update/delete, the old item.
  "$agent_output/client-before" legacy-save "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" "$agent_service"
  "$agent_output/client-before" read-missing "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" "$agent_service"
  for agent_operation in save read rotate read-rotated large delete read-missing; do
    "$agent_output/client-before" "$agent_operation" "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" "$agent_service"
    if [[ "$agent_operation" == read || "$agent_operation" == read-rotated || "$agent_operation" == read-missing ]]; then
      "$agent_output/client-after" "$agent_operation" "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" "$agent_service"
    fi
    "$agent_output/client-before" legacy-read "$agent_output/coexisting.keychain" "$agent_output/agent-fixture" "$agent_service"
  done
done
for agent_operation in save lock read-locked unlock read reject-scope; do
  "$agent_output/client-after" "$agent_operation" "$agent_output/coexisting.keychain" "$agent_output/agent-fixture"
done
"$agent_output/client-before" remove "$agent_output/coexisting.keychain" "$agent_output/agent-fixture"
if "$agent_output/agent-production" </dev/null > "$agent_output/untrusted-response"; then
  print -u2 'FAIL: production v2 agent must reject an untrusted parent'; exit 1
fi
[[ ! -s "$agent_output/untrusted-response" ]]
print -r -- 'PASS: all three stable records coexist with untouched legacy items, changed-caller cold reads/rotation, lock retry and scope rejection'
