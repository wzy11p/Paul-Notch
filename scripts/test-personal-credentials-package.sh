#!/bin/zsh
set -euo pipefail
if [[ $# != 2 ]]; then
  print -u2 'Usage: test-personal-credentials-package.sh <signed maintainer app> <previous signed app>'
  exit 64
fi
package_app="$1"
package_reference="$2"
[[ "$package_app" == *.app && -d "$package_app/Contents" && ! -L "$package_app" ]]
package_pin='certificate leaf = H"b93fcbf197e02d3e8568408d1ecdfc04adf1562e"'
/usr/bin/codesign --verify --deep --strict -R "=identifier \"local.paul.home-preview-20260905\" and $package_pin" "$package_app"
for package_version in v1 v2; do
  package_name=PaulCredentialAgent
  if [[ "$package_version" == v2 ]]; then package_name=PaulCredentialAgentV2; fi
  package_agent="$package_app/Contents/Helpers/$package_name"
  if [[ ! -f "$package_agent" || -L "$package_agent" ]]; then
    print -u2 -- "FAIL: formal app is missing the pinned $package_version credential component"; exit 1
  fi
  /usr/bin/codesign --verify --strict -R "=identifier \"local.paul.notch.credential-agent.$package_version\" and $package_pin" "$package_agent"
  if [[ -f "$package_reference/Contents/Helpers/$package_name" ]]; then
    cmp "$package_reference/Contents/Helpers/$package_name" "$package_agent"
  fi
done
package_output=$(mktemp -d /tmp/paul-packaged-credentials.XXXXXX)
if "$package_app/Contents/Helpers/PaulCredentialAgentV2" </dev/null > "$package_output/untrusted-response"; then
  print -u2 'FAIL: shipped credential component accepted an untrusted parent'; exit 1
fi
[[ ! -s "$package_output/untrusted-response" ]]
print -r -- 'PASS: sealed formal app, dual pinned helpers, immutable previous helpers and untrusted-parent rejection; no account read or launch implied'
