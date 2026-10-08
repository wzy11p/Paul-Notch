#!/bin/zsh
set -euo pipefail
migration_root="${0:A:h:h}"
cd "$migration_root"
migration_output=$(mktemp -d /tmp/paul-credential-migration.XXXXXX)
print -r -- "Evidence: $migration_output"
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/QuotaConnectionModels.swift Sources/PaulNotchCore/QuotaCredentialVault.swift \
  Tests/QuotaOverview/QuotaCredentialMigrationValidation.swift -o "$migration_output/migration"
"$migration_output/migration"
