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
for download_attempt in 1 2 3 4; do
  if http_status="$(curl --fail --location --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 60 --write-out '%{http_code}' \
      --output "$temporary" "$json_url")"; then
    break
  else
    download_status=$?
  fi
  case "$download_status:$http_status" in
    5:*|6:*|7:*|18:*|28:*|35:*|52:*|55:*|56:*|92:*|22:408|22:429|22:500|22:502|22:503|22:504) ;;
    *) exit "$download_status" ;;
  esac
  if [[ "$download_attempt" == 4 ]]; then
    echo 'JSON-java download failed after 4 attempts; dependency was not installed' >&2
    exit "$download_status"
  fi
  echo "JSON-java download failed (curl $download_status, HTTP $http_status); retrying after attempt $download_attempt/4" >&2
  sleep "$((download_attempt * 2))"
done
digest="$(digest_of "$temporary")"
[[ "${digest%% *}" == "$json_sha256" ]] || { echo 'JSON-java dependency checksum mismatch' >&2; exit 1; }
mv "$temporary" "$json_jar"
