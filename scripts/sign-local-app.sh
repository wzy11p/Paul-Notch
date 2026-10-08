#!/bin/zsh
set -euo pipefail

# Local development only. Never create identities, modify trust/TCC, or fall back to ad-hoc signing.
signing_selector="${PAUL_SIGNING_IDENTITY:-Paul Notch Local Development}"
if [[ "$signing_selector" == "-" || -z "$signing_selector" ]]; then
  print -u2 -- "A fixed code-signing identity is required; ad-hoc signing is disabled."
  exit 1
fi
signing_fingerprint="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v wanted="$signing_selector" '
  { hash=$2; label=$0; sub(/^[^"]*"/, "", label); sub(/".*$/, "", label)
    if (length(hash)==40 && hash ~ /^[[:xdigit:]]+$/ && (hash==toupper(wanted) || label==wanted)) print hash }
')"
if [[ ! "$signing_fingerprint" =~ '^[A-Fa-f0-9]{40}$' ]]; then
  print -u2 -- "No unique valid signing identity matched: $signing_selector"
  print -u2 -- "Create/verify the dedicated identity in Keychain Access. No app or permissions were changed."
  exit 1
fi
if [[ "${1:-}" == "--check" && $# == 1 ]]; then
  print -r -- "$signing_fingerprint"
  exit 0
fi
if [[ $# != 1 || "$1" != *.app || ! -d "$1/Contents" || -L "$1" ]]; then
  print -u2 -- "Usage: zsh scripts/sign-local-app.sh <Paul Notch.app> | --check"
  exit 64
fi
signing_app="$1"
signing_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$signing_app/Contents/Info.plist")"
if [[ "$signing_name" != "Paul Notch" && "$signing_name" != "Paul Notch Preview" ]]; then
  print -u2 -- "Refusing to sign a different product: $signing_name"
  exit 1
fi
for signing_agent_version in v1 v2; do
  signing_agent_name=PaulCredentialAgent
  if [[ "$signing_agent_version" == v2 ]]; then signing_agent_name=PaulCredentialAgentV2; fi
  signing_agent="$signing_app/Contents/Helpers/$signing_agent_name"
  [[ -f "$signing_agent" ]] || continue
  [[ ! -L "$signing_agent" ]]
  signing_agent_identifier="local.paul.notch.credential-agent.$signing_agent_version"
  signing_agent_pin="identifier \"$signing_agent_identifier\" and certificate leaf = H\"${(L)signing_fingerprint}\""
  if ! /usr/bin/codesign --verify --strict -R "=$signing_agent_pin" "$signing_agent" 2>/dev/null; then
    # First inclusion only. A shipped helper with an unexpected signature must
    # be rejected, not silently resigned or replaced.
    if /usr/bin/codesign -d "$signing_agent" >/dev/null 2>&1; then
      signing_agent_detail=$(/usr/bin/codesign -dvv "$signing_agent" 2>&1)
      if [[ "$signing_agent_detail" != *'Signature=adhoc'* ]]; then
        print -u2 'Credential agent identity changed; refusing silent replacement.'; exit 1
      fi
    fi
    /usr/bin/codesign --force --timestamp=none --identifier "$signing_agent_identifier" \
      --sign "$signing_fingerprint" "$signing_agent"
    /usr/bin/codesign --verify --strict -R "=$signing_agent_pin" "$signing_agent"
  fi
done
/usr/bin/codesign --force --timestamp=none --sign "$signing_fingerprint" "$signing_app"
/usr/bin/codesign --verify --deep --strict "$signing_app"
signing_requirement="$(/usr/bin/codesign -d -r- "$signing_app" 2>&1)"
if [[ "$signing_requirement" == *'cdhash H'* || ( "$signing_requirement" != *anchor* && "$signing_requirement" != *certificate* ) ]]; then
  print -u2 -- "Unexpected designated requirement; do not install this bundle."
  exit 1
fi
print -r -- "$signing_requirement"
