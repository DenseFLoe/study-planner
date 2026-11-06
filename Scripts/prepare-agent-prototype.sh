#!/bin/bash
# Optional local SDK bridges. Downloads public packages, never model APIs.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
work="$root/.build/agent-prototype"
mkdir -p "$work"
case "$(uname -m)" in
  arm64) architecture=arm64; checksum=595d2f934e081b82961d1a5fd41c6dbd0c5a952d9e8be5b4566ab754426968d2 ;;
  x86_64) architecture=x64; checksum=bd19c6b98d923fb049f64b547163b9f7d52ae73f16fdee09ecef9ab248c4d6ff ;;
  *) echo 'Agent prototype requires macOS arm64 or x64' >&2; exit 1 ;;
esac
release="node-v26.7.0-darwin-$architecture"
archive="$work/$release.tar.xz"
verify_archive() { echo "$checksum  $archive" | shasum -a 256 -c - >/dev/null 2>&1; }
if ! verify_archive; then
  temporary="$(mktemp "$work/download.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  curl --fail --silent --show-error --max-time 180 --proto '=https' \
    "https://nodejs.org/dist/v26.7.0/$release.tar.xz" -o "$temporary"
  echo "$checksum  $temporary" | shasum -a 256 -c -
  mv "$temporary" "$archive"
  trap - EXIT
fi
tar -xJf "$archive" -C "$work"
node="$work/$release/bin/node"
# Supply no inherited environment, private registry configuration, or API credentials.
env -i PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" "$node" \
  "$work/$release/lib/node_modules/npm/bin/npm-cli.js" \
  --prefix "$root/Experiments/AgentPrototype" --userconfig=/dev/null \
  --globalconfig="$work/absent-global.npmrc" --cache="$work/npm-cache" \
  --registry=https://registry.npmjs.org --fetch-retries=0 --fetch-timeout=20000 \
  ci --ignore-scripts --no-audit --no-fund --prefer-offline
(
  cd "$root/Experiments/AgentPrototype"
  env -i PATH=/usr/bin:/bin "$node" build.mjs
)
mkdir -p "$work/payload"
cp "$node" "$work/payload/node"
cp "$work/$release/LICENSE" "$work/payload/NODE-LICENSE"
cp Experiments/AgentPrototype/out/helper.cjs "$work/payload/helper.cjs"
cp Experiments/AgentPrototype/out/assistant-helper.cjs "$work/payload/assistant-helper.cjs"
python3 - "$work/payload" <<'PY'
from pathlib import Path
import hashlib, json, sys
target = Path(sys.argv[1])
package = json.loads(Path('Experiments/AgentPrototype/package.json').read_text())
modules = Path('Experiments/AgentPrototype/node_modules')
licenses = []
for path in sorted(modules.rglob('*')):
    if path.is_file() and path.name.lower() in ('license', 'license.md', 'license.txt', 'copying'):
        licenses.append(str(path.relative_to(modules)) + '\n' + path.read_text(errors='replace'))
if not licenses:
    raise SystemExit('Missing dependency license files')
(target / 'DEPENDENCY-LICENSES.txt').write_text('\n\n'.join(licenses))
manifest = {'protocol': 1, 'syntheticOnly': True, 'node': '26.7.0',
            'dependencies': package['dependencies'],
            'helperSHA256': hashlib.sha256((target / 'helper.cjs').read_bytes()).hexdigest(),
            'assistantProtocol': 2,
            'assistantSHA256': hashlib.sha256((target / 'assistant-helper.cjs').read_bytes()).hexdigest()}
(target / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
# Inner executable is signed before the containing application.
codesign --force --sign - "$work/payload/node"
echo "Local SDK bridges prepared ($architecture)"
