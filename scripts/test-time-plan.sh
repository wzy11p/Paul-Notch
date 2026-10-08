#!/bin/zsh
set -euo pipefail
time_plan_root="${0:A:h:h}"
cd "$time_plan_root"
time_plan_output="$(mktemp -d /tmp/paul-time-plan-build.XXXXXX)"
trap 'rm -f -- "$time_plan_output/TimePlanValidation"; rmdir "$time_plan_output" 2>/dev/null || true' EXIT
swiftc -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/AppEnvironment.swift \
    Sources/PaulNotchCore/TimePlanStore.swift \
    Tests/IslandMemoTests/TimePlanValidation.swift \
    -o "$time_plan_output/TimePlanValidation"
"$time_plan_output/TimePlanValidation"
