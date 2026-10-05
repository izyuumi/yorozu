#!/bin/sh
# Private signed candidate. This script never publishes a release or update feed.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/build-version.sh
[ "$VERSION" = 0.6.0 ] || { echo "internal secretary version must be 0.6.0" >&2; exit 1; }
DIST=${DIST:-dist/internal/mac}
mkdir -p "$DIST"
DIST=$(cd "$DIST" && pwd)
export YOROZU_REVIEWED_REPO="$PWD"
export YOROZU_REVIEWED_SHA="$(git rev-parse HEAD)"
SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/yorozu-internal-build.XXXXXX")
python3 scripts/stage-internal-alpha.py "$SOURCE"
(
  cd "$SOURCE"
  export YOROZU_SECRETARY_ENABLED=1
  pnpm install --frozen-lockfile
  DIST="$DIST" sh scripts/build-mac.sh
)
cp "$DIST/Yorozu.app/Contents/Resources/internal-source.json" "$DIST/internal-source.json"
python3 - "$DIST" <<'PY'
import hashlib, json, os, plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
app = root / 'Yorozu.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['YorozuSecretaryEnabled'] and 'SUFeedURL' not in info
manifest = json.loads((root / 'internal-source.json').read_text())
manifest.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'])
intake = Path(os.environ['YOROZU_HERMES_RUNTIME_ARTIFACT']).parent / 'intake-receipt.json'
receipt = json.loads(intake.read_text())
unsigned = json.loads((root / 'hermes-unsigned-manifest.json').read_text())
bundled = json.loads((app / 'Contents/Resources/agent-runtimes/hermes/runtime-artifact.json').read_text())
assert receipt['inventorySha256'] == unsigned['inventorySha256']
assert receipt['manifestSha256'] == hashlib.sha256((root / 'hermes-unsigned-manifest.json').read_bytes()).hexdigest()
assert manifest['harnessPlugins']['hermes']['bundledRuntime'] is True
assert manifest['harnessPlugins']['hermes']['inventorySha256'] == bundled['inventorySha256']
manifest['runtimeIntake'] = {'receiptSha256': hashlib.sha256(intake.read_bytes()).hexdigest(),
    'archiveSha256': receipt['archiveSha256'], 'unsignedInventorySha256': unsigned['inventorySha256'],
    'signedInventorySha256': bundled['inventorySha256'], 'archiveProvenanceSha256': receipt['archiveProvenanceSha256']}

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
