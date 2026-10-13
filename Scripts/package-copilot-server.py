#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bundle a verified official native release with all notices. No download or execution."""
import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path

VERSION = '1.552.0'
SHA256 = 'fd94d41828e75ff29586a3d3b1029ff203f69fb4d947120a24979e6ac75c5df0'
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, default=root.parent/'CompEditorBuild/Build/Products/Debug/CompEditor.app')
p.add_argument('--server', type=Path, default=Path(os.environ.get('COPILOT_SERVER', str(root.parent/'CopilotOfficial'/VERSION/'copilot-language-server'))))
p.add_argument('--notices', type=Path, default=root/'RuntimeNotices'/('Copilot-'+VERSION))
a = p.parse_args()
if a.app.is_symlink() or not (a.app/'Contents/Info.plist').is_file():
    raise SystemExit('A built regular app is required')
if a.server.is_symlink() or not a.server.is_file() or hashlib.sha256(a.server.read_bytes()).hexdigest() != SHA256:
    raise SystemExit('Missing or unverified official macOS arm64 1.552.0 input; nothing was downloaded')
if a.notices.is_symlink() or any(entry.is_symlink() for entry in a.notices.rglob('*')):
    raise SystemExit('Symlink notice sources refused')
required = ['LICENSE', 'zod-LICENSE', 'vscode-jsonrpc-License.txt', 'vscode-jsonrpc-thirdpartynotices.txt']
if any(not (a.notices/n).is_file() or (a.notices/n).is_symlink() or (a.notices/n).stat().st_size == 0 for n in required):
    raise SystemExit('Complete official license/third-party notices are required')
destination = a.app/'Contents/Resources/CopilotServer'
if any(p.is_symlink() for p in [a.app/'Contents', a.app/'Contents/Resources', destination]):
    raise SystemExit('Symlink package destination refused')
destination.mkdir(parents=True, exist_ok=True)
binary = destination/'copilot-language-server'
if binary.is_symlink():
    raise SystemExit('Symlink executable destination refused')
# Atomic replacement also protects a server process using the previous inode.
with tempfile.NamedTemporaryFile(dir=destination, prefix='.copilot-incoming-', delete=False) as temporary:
    staged = Path(temporary.name)
try:
    shutil.copy2(a.server, staged)
    staged.chmod(0o755)
    staged.replace(binary)
finally:
    staged.unlink(missing_ok=True)
notice_target = destination/'Notices'
if notice_target.is_symlink() or any(entry.is_symlink() for entry in notice_target.rglob('*')):
    raise SystemExit('Symlink notices destination refused')
shutil.copytree(a.notices, notice_target, dirs_exist_ok=True)
if (destination/'manifest.json').is_symlink():
    raise SystemExit('Symlink manifest destination refused')
(destination/'manifest.json').write_text(json.dumps({
    'schemaVersion': 1, 'version': VERSION, 'platform': 'darwin-arm64', 'sha256': SHA256,
    'source': 'https://registry.npmjs.org/@github/copilot-language-server-darwin-arm64/-/copilot-language-server-darwin-arm64-1.552.0.tgz',
    'license': 'MIT', 'notices': required,
}, indent=2)+'\n')
print('Bundled checksum-verified official Copilot 1.552.0 and complete notices; app-relative paths only')
