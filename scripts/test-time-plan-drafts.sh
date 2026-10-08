#!/bin/zsh
set -euo pipefail
time_plan_drafts_root="${0:A:h:h}"
cd "$time_plan_drafts_root"
time_plan_drafts_output="$(mktemp -d /tmp/paul-time-plan-drafts-build.XXXXXX)"
trap 'rm -f -- "$time_plan_drafts_output/TimePlanningDraftValidation"; rmdir "$time_plan_drafts_output" 2>/dev/null || true' EXIT
swiftc -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/AppEnvironment.swift \
    Sources/PaulNotchCore/TimePlanningDraftCache.swift \
    Tests/IslandMemoTests/TimePlanningDraftValidation.swift \
    -o "$time_plan_drafts_output/TimePlanningDraftValidation"
"$time_plan_drafts_output/TimePlanningDraftValidation"
