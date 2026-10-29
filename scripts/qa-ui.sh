#!/usr/bin/env bash
# Build and run the app's own debug-only UI tests in an isolated preferences domain.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
QA_OUTPUT="${1:-/tmp/photo-culler-native-ui}"
python3 - "$QA_OUTPUT" <<'PY'
from pathlib import Path
import json, sys
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
(out / 'results.json').write_text(json.dumps({'status': 'building', 'passed': 0, 'failures': []}) + '\n')
PY
swift build --product PhotoCuller
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil
app = Path('build/PhotoCuller Design QA.app/Contents')
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Resources').mkdir(exist_ok=True)
shutil.copy2('.build/debug/PhotoCuller', app / 'MacOS/PhotoCuller')
shutil.copy2('PhotoCuller/AppIcon.icns', app / 'Resources/AppIcon.icns')
info = plistlib.loads(Path('PhotoCuller/Info.plist').read_bytes())
info.update(CFBundleIdentifier='com.braveenkumar.photoculler.designqa',
            CFBundleName='Photo Culler Design QA', CFBundleDisplayName='Photo Culler Design QA')
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --deep -s - 'build/PhotoCuller Design QA.app'
exec 'build/PhotoCuller Design QA.app/Contents/MacOS/PhotoCuller' \
    -ApplePersistenceIgnoreState YES --ui-qa-output "$QA_OUTPUT"
