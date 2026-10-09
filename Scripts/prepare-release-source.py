#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Export committed files into a NEW staging directory; never rewrite working files/history."""
import argparse,io,json,re,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
if a.destination.exists():raise SystemExit('Choose a new empty staging path; existing directories are protected')
a.destination.mkdir(parents=True)
archive=subprocess.check_output(['git','archive','HEAD'],cwd=root)
with tarfile.open(fileobj=io.BytesIO(archive)) as t:
 for entry in t.getmembers():
  if entry.issym() or entry.islnk() or Path(entry.name).is_absolute() or '..' in Path(entry.name).parts:raise SystemExit('Unsafe source archive member')
 t.extractall(a.destination)
fixture=a.destination/'SemanticTests/gui-error-config.json'
if fixture.exists():fixture.write_text(re.sub(r'/Users/[^"]+','/path/to/local-test-fixture',fixture.read_text()))
base='efd522f9fc9362a5211aef528b96a87dcad11335'
modified=subprocess.check_output(['git','diff','--name-only',base,'HEAD'],cwd=root,text=True).splitlines()
notice='Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.'
for name in modified:
 file=a.destination/name
 if not file.is_file():continue
 if file.suffix in ('.swift','.xcconfig','.py','.sh'):
  text=file.read_text();prefix='# ' if file.suffix in ('.py','.sh') else '// '
  lines=text.splitlines(keepends=True);index=1 if text.startswith('#!') else 0
  lines.insert(index,prefix+notice+'\n');file.write_text(''.join(lines))
 elif file.suffix=='.plist':
  text=file.read_text();pos=text.find('\n')+1;file.write_text(text[:pos]+'<!-- '+notice+' -->\n'+text[pos:])
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
(a.destination/'FORK_CHANGES.md').write_text('# Unofficial fork modifications\n\nBase: '+base+'\nSnapshot: '+commit+'\n\nJava/Python LSP features, isolated settings, private build compatibility and release preparation. Original attribution and licenses retained. Staging fixture paths generalized; code-comment change notices added. Generated JSON/project metadata differences are listed below. No Git history is included.\n\n'+''.join('- '+x+'\n' for x in modified))
private_home=str(Path.home()).encode()
remaining=[str(f.relative_to(a.destination)) for f in a.destination.rglob('*') if f.is_file() and private_home in f.read_bytes()]
if remaining:raise SystemExit('Current-user paths remain in staged source: '+', '.join(remaining))
print('Exported committed source without Git metadata; staging-only sanitization complete')
