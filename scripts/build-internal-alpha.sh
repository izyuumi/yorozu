#!/bin/sh
# Private signed candidate. This script never publishes a release or update feed.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/build-version.sh
[ "$VERSION" = 0.6.0 ] || { echo "internal secretary version must be 0.6.0" >&2; exit 1; }
DIST=${DIST:-dist/internal/mac}
mkdir -p "$DIST"
DIST=$(cd "$DIST" && pwd)
SOURCE=$(mktemp -d "$DIST/source.XXXXXX")
python3 scripts/stage-internal-alpha.py "$SOURCE"
(
  cd "$SOURCE"
  export YOROZU_SECRETARY_ENABLED=1
  pnpm install --frozen-lockfile
  DIST="$DIST" sh scripts/build-mac.sh
)
cp "$DIST/Yorozu.app/Contents/Resources/internal-source.json" "$DIST/internal-source.json"
python3 - "$DIST" <<'PY'
import hashlib, json, plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
app = root / 'Yorozu.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['YorozuSecretaryEnabled'] and 'SUFeedURL' not in info
manifest = json.loads((root / 'internal-source.json').read_text())
manifest.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'])
runtime = app / 'Contents/Resources/runtime'
manifest['runtimeDependencies'] = {
    name: json.loads((runtime / 'node_modules' / name / 'package.json').read_text())['version']
    for name in json.loads((runtime / 'package.json').read_text())['dependencies']
}
manifest['files'] = {str(p.relative_to(app)): hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()
                     for p in sorted(app.rglob('*')) if p.is_file() and not p.is_symlink()}
manifest['symlinks'] = {str(p.relative_to(app)): str(p.readlink())
                        for p in sorted(app.rglob('*')) if p.is_symlink()}
manifest['dmgSha256'] = hashlib.file_digest((root / 'Yorozu.dmg').open('rb'), 'sha256').hexdigest()
(root / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Verified internal source and bundle identity:', manifest['sourceSha'], manifest['version'], manifest['build'])
PY
