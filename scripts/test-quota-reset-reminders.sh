#!/bin/zsh
set -euo pipefail
reset_root="${0:A:h:h}"
cd "$reset_root"
reset_output=$(mktemp -d /tmp/paul-reset-reminders.XXXXXX)
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaConnectionModels.swift Sources/PaulNotchCore/QuotaResetReminderPolicy.swift Tests/QuotaOverview/QuotaResetNoticeValidation.swift -o "$reset_output/policy"
"$reset_output/policy"
swift build --disable-sandbox
reset_bin=$(swift build --show-bin-path)
reset_objects=("$reset_bin"/PaulNotchCore.build/*.swift.o)
reset_objects=(${reset_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$reset_bin/Modules" Tests/WindowValidation/QuotaResetReminderNativeValidation.swift "${reset_objects[@]}" "$reset_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$reset_output/native"
PAUL_PREVIEW_DIRECTORY="$reset_output" "$reset_output/native" "$reset_output"
print -r -- "Evidence: $reset_output"
