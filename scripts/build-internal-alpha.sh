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
YOROZU_REVIEWED_SHA=$(git rev-parse HEAD)
export YOROZU_REVIEWED_SHA
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
openclaw = app / 'Contents/Resources/agent-runtimes/openclaw/runtime-artifact.json'
if os.environ.get('YOROZU_OPENCLAW_RUNTIME_ARTIFACT'):
    sealed = json.loads(openclaw.read_text())
    unsigned = json.loads((root / 'openclaw-unsigned-manifest.json').read_text())
    assert manifest['harnessPlugins']['openclaw']['bundledRuntime'] is True
    assert manifest['harnessPlugins']['openclaw']['inventorySha256'] == sealed['inventorySha256']
    assert sealed['hashStage'] == 'after-nested-signing-before-outer-bundle-signing'
    assert sealed['reseal']['unsignedInventorySha256'] == unsigned['inventorySha256'] == manifest['harnessPlugins']['openclaw']['unsignedInventorySha256']
    assert sealed['productionReady'] is False and manifest['harnessPlugins']['openclaw']['productionReady'] is False
    unsigned_sha = hashlib.sha256((root / 'openclaw-unsigned-manifest.json').read_bytes()).hexdigest()
    manifest['openclawRuntimeIntake'] = {'unsignedInventorySha256': unsigned['inventorySha256'], 'unsignedManifestSha256': unsigned_sha,
        'signedInventorySha256': sealed['inventorySha256'], 'dependencyEvidence': sealed['dependencyEvidence'], 'pins': sealed['pins']}
    # A local development override has no intake receipt; the Release job always does,
    # and publication refuses an intake without the receipt and archive digests.
    openclaw_intake = Path(os.environ['YOROZU_OPENCLAW_RUNTIME_ARTIFACT']).parent / 'intake-receipt.json'
    if openclaw_intake.is_file():
        openclaw_receipt = json.loads(openclaw_intake.read_text())
        assert openclaw_receipt['inventorySha256'] == unsigned['inventorySha256']
        assert openclaw_receipt['manifestSha256'] == unsigned_sha
        manifest['openclawRuntimeIntake'].update(receiptSha256=hashlib.sha256(openclaw_intake.read_bytes()).hexdigest(),
                                                 archiveSha256=openclaw_receipt['archiveSha256'])
else:
    assert not openclaw.exists() and manifest['harnessPlugins']['openclaw']['bundledRuntime'] is False
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
