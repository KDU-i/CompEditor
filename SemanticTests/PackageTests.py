#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Packaging safety boundaries only; no real runtime or server is executed."""
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'Scripts/package-semantic-servers.py'
with tempfile.TemporaryDirectory(prefix='semantic-package-') as directory:
    root = Path(directory)
    app = root / 'Editor.app'
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').touch()
    node = root / 'node'
    node.write_bytes(b'explicit test input')
    jdk = root / 'jdk'
    jdk.mkdir()
    servers = root / 'servers'
    (servers / 'pyright/node_modules').mkdir(parents=True)
    (servers / 'jdtls').mkdir()
    command = ['python3', str(script), '--app', str(app), '--servers', str(servers), '--node', str(node), '--jdk', str(jdk)]
    cycle = jdk / 'cycle'
    cycle.symlink_to(jdk, target_is_directory=True)
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0 and 'cycle refused' in result.stderr, result.stderr
    print('PASS: runtime directory symlink cycle fails closed')
    cycle.unlink()
    outside = root / 'outside'
    outside.write_text('must not be copied')
    (jdk / 'escape').symlink_to(outside)
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode != 0 and 'External runtime symlink refused' in result.stderr, result.stderr
    print('PASS: runtime external symlink target fails closed')
