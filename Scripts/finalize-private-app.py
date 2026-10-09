#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Use the original icon's conventional file metadata in the unsigned private app."""
from pathlib import Path
import argparse
import plistlib

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=root.parent / 'CompEditorBuild/Build/Products/Debug/CompEditor.app')
app = parser.parse_args().app
if app.is_symlink():
    raise SystemExit('Refusing a symlink app')
info = app / 'Contents/Info.plist'
data = plistlib.loads(info.read_bytes())
if data.get('CFBundleIdentifier') != 'dev.local.SemanticEditor' or any(
        data.get(key) != 'CompEditor' for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable')):
    raise SystemExit('Only the CompEditor-named isolated fork may be finalized')
icon = app / 'Contents/Resources/AppIcon.icns'
if not icon.is_file() or icon.is_symlink() or icon.stat().st_size == 0:
    raise SystemExit('Original compiled AppIcon.icns is required')
if not (app / 'Contents/MacOS/CompEditor').is_file():
    raise SystemExit('CompEditor executable is required')
# Icon Composer name lookup produced a blank native file icon in this unsigned
# macOS 27 beta build. Explicit ICNS lookup renders the same original asset.
data.pop('CFBundleIconName', None)
data['CFBundleIconFile'] = 'AppIcon.icns'
info.write_bytes(plistlib.dumps(data, sort_keys=False))
print('Finalized CompEditor name and original AppIcon.icns metadata')
