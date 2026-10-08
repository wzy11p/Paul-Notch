#!/bin/zsh
set -euo pipefail
adversarial_root="${0:A:h:h}"
cd "$adversarial_root"
adversarial_output=$(mktemp -d /tmp/paul-adversarial.XXXXXX)
print -r -- "Regression logs: $adversarial_output"
for suite in safety clipboard-lifecycle note-ime note-store time-plan time-plan-drafts notes tab-strip workspace-bars presentation-reveal quota-layout ambient-service ambient-foreground-native quota-input-focus quota-keychain credential-migration credential-agent credential-agent-v2 quota-setup quota-drag quota-interactions desktop-quota cursor-account cursor-browser website-quota website-quota-lifecycle website-quota-persistence muse-quota muse-lifecycle persistence-failures workspace-motion workspace-window workspace-geometry; do
  if zsh "scripts/test-$suite.sh" > "$adversarial_output/$suite.log" 2>&1; then
    print -r -- "PASS: $suite"
  else
    cat "$adversarial_output/$suite.log"
    exit 1
  fi
done
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/AppEnvironment.swift Sources/PaulNotchCore/TaskItem.swift \
  Sources/PaulNotchCore/TaskStore.swift Sources/PaulNotchCore/TaskRepository.swift \
  Tests/IslandMemoTests/MemoTaskDetailsValidation.swift -o "$adversarial_output/TaskDetails"
PAUL_PREVIEW_DIRECTORY="$adversarial_output" "$adversarial_output/TaskDetails"
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/QQNowPlaying.swift Tests/IslandMemoTests/QQNowPlayingValidation.swift \
  -o "$adversarial_output/QQParsing"
"$adversarial_output/QQParsing"
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/MusicPermissionDiagnostics.swift Tests/IslandMemoTests/MusicPermissionValidation.swift \
  -o "$adversarial_output/MusicErrors"
"$adversarial_output/MusicErrors"
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/CodexStatusModels.swift Sources/PaulNotchCore/CodexTaskRuntimeIndex.swift \
  Sources/PaulNotchCore/CodexRolloutActivityIndex.swift Tests/IslandMemoTests/CodexRolloutActivityIndexValidation.swift \
  -lsqlite3 -o "$adversarial_output/CodexLifecycle"
"$adversarial_output/CodexLifecycle"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/HomeLayoutEngine.swift \
  Tests/IslandMemoTests/HomeLayoutEngineTests.swift -o "$adversarial_output/HomeLayout"
"$adversarial_output/HomeLayout"
print -r -- "PASS: adversarial regression round. Logs: $adversarial_output"
