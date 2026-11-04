#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

json_jar="Android/tools/json.jar"
json_url='https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
json_sha256='3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'
digest_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
if [[ -f "$json_jar" ]]; then
  digest="$(digest_of "$json_jar")"
  [[ "${digest%% *}" == "$json_sha256" ]] || { echo 'JSON-java dependency checksum mismatch' >&2; exit 1; }
  exit 0
fi
mkdir -p "$(dirname "$json_jar")"
temporary="$(mktemp "${json_jar}.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --output "$temporary" "$json_url"
digest="$(digest_of "$temporary")"
[[ "${digest%% *}" == "$json_sha256" ]] || { echo 'JSON-java dependency checksum mismatch' >&2; exit 1; }
mv "$temporary" "$json_jar"
