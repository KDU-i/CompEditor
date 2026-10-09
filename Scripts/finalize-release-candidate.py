#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Local release-candidate hygiene and attribution. Does NOT sign or publish."""
import argparse,json,plistlib,shutil,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--packages',type=Path,required=True);a=p.parse_args()
if a.app.is_symlink():raise SystemExit('Refusing symlink app')
info=a.app/'Contents/Info.plist';d=plistlib.loads(info.read_bytes())
linked=subprocess.check_output(['otool','-L',str(a.app/'Contents/MacOS/CompEditor')],text=True)
if 'Sparkle.framework' in linked:raise SystemExit('Refusing to strip a linked updater; disable SPARKLE and rebuild')
if d.get('CFBundleIdentifier')!='dev.local.SemanticEditor':raise SystemExit('Only isolated private fork can be staged')
for k in list(d):
 if k.startswith('SU'):d.pop(k)
fork_notice='Unofficial Java/Python semantic fork. Not endorsed by the CotEditor Project.'
if fork_notice not in d.get('NSHumanReadableCopyright',''):
 d['NSHumanReadableCopyright']=d.get('NSHumanReadableCopyright','')+'\n'+fork_notice
d['SemanticReleaseCandidate']=True
info.write_bytes(plistlib.dumps(d,sort_keys=False))
for localized in (a.app/'Contents/Resources').glob('*.lproj/InfoPlist.strings'):
 data=localized.read_bytes()
 if data.startswith((b'\xff\xfe',b'\xfe\xff')):data=data.decode('utf-16').encode('utf-8').replace(b'UTF-16',b'UTF-8')
 values=plistlib.loads(data)
 if 'NSHumanReadableCopyright' in values and fork_notice not in values['NSHumanReadableCopyright']:
  values['NSHumanReadableCopyright'] += '\nUnofficial Java/Python semantic fork. Not endorsed by the CotEditor Project.'
  localized.write_bytes(plistlib.dumps(values,sort_keys=False))
sparkle=a.app/'Contents/Frameworks/Sparkle.framework'
if sparkle.exists():shutil.rmtree(sparkle)
for file in a.app.rglob('*'):
 if file.name=='.DS_Store' or file.suffix in ('.profraw','.dSYM','.mobileprovision','.provisionprofile','.p12','.pfx'):
  raise SystemExit('Forbidden release artifact: '+str(file.relative_to(a.app)))
# Remove compiler debug records from the candidate, never the user's running app.
subprocess.run(['strip','-S','-x',str(a.app/'Contents/MacOS/CompEditor')],check=True)
notices=a.app/'Contents/Resources/ThirdPartyNotices';notices.mkdir(exist_ok=True)
shutil.copy2(root/'LICENSE',notices/'CotEditor-LICENSE.txt')
for name in ('NOTICE.md','THIRD_PARTY.md','ARTWORK_ATTRIBUTION.md'):
 if (root/'Release'/name).exists():shutil.copy2(root/'Release'/name,notices/name)
# Preserve license text for every pinned cached Swift/tree-sitter dependency.
manifest=[]
for checkout in sorted((a.packages/'checkouts').iterdir()):
 if not checkout.is_dir():continue
 target=notices/'SwiftDependencies'/checkout.name
 for file in checkout.iterdir():
  if file.is_file() and file.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
   target.mkdir(parents=True,exist_ok=True)
   destination=target/file.name
   if destination.is_symlink():raise SystemExit('Symlink notice destination refused')
   # Cached dependency licenses can be read-only; a repeat finalization keeps
   # identical existing copies intact rather than reopening them for writing.
   if destination.exists():
    if destination.read_bytes()==file.read_bytes():continue
    raise SystemExit('Conflicting existing dependency notice; choose a new candidate')
   shutil.copy2(file,destination)
 manifest.append({'component':checkout.name,'notice_files':sorted(x.name for x in target.iterdir()) if target.exists() else []})
(notices/'swift-dependency-notices.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Candidate hygiene completed: unofficial notice, no Sparkle updater, license copies. Public release remains gated.')
