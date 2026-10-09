#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Copy separately approved distributions/runtimes into a private local app. No downloads."""
import argparse, json, shutil, subprocess, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--app', type=Path, default=root.parent/'CompEditorBuild/Build/Products/Debug/CompEditor.app')
p.add_argument('--servers', type=Path, default=root.parent/'ExternalServers')
p.add_argument('--node', type=Path, default=Path('/usr/local/bin/node'))
p.add_argument('--jdk', type=Path, default=Path('/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home'))
a = p.parse_args()
sources = {'node': a.node.resolve(), 'jdk': a.jdk, 'pyright': a.servers/'pyright/node_modules', 'jdtls': a.servers/'jdtls'}
for name, source in sources.items():
    if not source.exists(): raise SystemExit(f'Missing approved {name} input: {source}; no dependency was downloaded')
if not (a.app/'Contents/Info.plist').is_file(): raise SystemExit('Build the local app first')
destination = a.app/'Contents/Resources/SemanticServers'
destination.mkdir(parents=True, exist_ok=True)
# Repeated local builds reuse exact copied runtimes. Copy only changed input files.
def copy_tree(source, target, ancestors=frozenset()):
    if source.is_symlink():
        resolved = source.resolve()
        # Preserve only links whose targets stay inside the explicitly supplied tree.
        source_root = next((v.resolve() for v in sources.values() if v.is_dir() and resolved.is_relative_to(v.resolve())), None)
        if source_root is None: raise SystemExit(f'External runtime symlink refused: {source}')
    if source.is_dir():
        canonical = source.resolve()
        if canonical in ancestors: raise SystemExit(f'Runtime symlink cycle refused: {source}')
        ancestors = ancestors | {canonical}
        target.mkdir(parents=True, exist_ok=True)
        for entry in source.iterdir(): copy_tree(entry, target/entry.name, ancestors)
    elif source.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.stat().st_size != source.stat().st_size or target.stat().st_mtime_ns != source.stat().st_mtime_ns:
            shutil.copy2(source, target)
    else: raise SystemExit(f'Unsupported runtime entry: {source}')
for name, source in sources.items(): copy_tree(source, destination/name)
copy_tree(root/'RuntimeNotices/Node-v24.14.1-LICENSE.txt', destination/'Node-LICENSE.txt')
copy_tree(root/'RuntimeNotices/VSCode-MIT-LICENSE.txt', destination.parent/'ThirdPartyNotices/VSCode-MIT-LICENSE.txt')
subprocess.run([sys.executable, str(root/'Scripts/patch-jdt-diagnostics.py'), '--plugins', str(destination/'jdtls/plugins'), '--jdk', str(a.jdk), '--source-output', str(destination.parent/'ThirdPartyNotices/JDT-Diagnostic-Patch/patched')], check=True)
copy_tree(root/'Scripts/patch-jdt-diagnostics.py', destination.parent/'ThirdPartyNotices/JDT-Diagnostic-Patch/patch-jdt-diagnostics.py')
copy_tree(root/'ServerPatches/jdtls-1.61', destination.parent/'ThirdPartyNotices/JDT-Diagnostic-Patch')
launchers = sorted((destination/'jdtls/plugins').glob('org.eclipse.equinox.launcher_*.jar'))
if len(launchers) != 1: raise SystemExit('Expected one known Equinox launcher')
manifest = {'schemaVersion': 1, 'pyrightVersion': json.loads((destination/'pyright/pyright/package.json').read_text())['version'], 'jdtlsVersion': '1.61.0', 'diagnosticVersionPatch': True, 'launcher': launchers[0].name}
(destination/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(f'Packaged private approved runtimes and servers at {destination}; relative app-owned paths only')
