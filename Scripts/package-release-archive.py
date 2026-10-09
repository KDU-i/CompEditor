#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Create a LOCAL review ZIP with fixed ZIP timestamps and no host xattrs/UIDs."""
import argparse,hashlib,json,os,stat,zipfile,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
outputs=[a.output,a.output.with_suffix(a.output.suffix+'.inventory.json'),a.output.with_suffix(a.output.suffix+'.sha256'),a.output.with_suffix(a.output.suffix+'.audit.json')]
if any(p.exists() or p.is_symlink() for p in outputs):raise SystemExit('Existing archive/sidecar is protected')
if not a.input.is_dir() or a.input.is_symlink():raise SystemExit('Regular source/app directory required')
a.input=a.input.resolve()
files=sorted(x for x in a.input.rglob('*') if x.is_file() or x.is_symlink())
for f in files:
 if '.git' in f.parts or any(x.endswith('.dSYM') for x in f.parts) or f.name in ('.DS_Store','.env','credentials') or f.suffix in ('.p12','.pfx','.mobileprovision','.provisionprofile','.profraw'):
  raise SystemExit('Forbidden archive member: '+str(f.relative_to(a.input)))
 if f.is_symlink():
  target=os.readlink(f)
  if Path(target).is_absolute() or not f.resolve().is_relative_to(a.input.resolve()):raise SystemExit('External symlink refused')
a.output.parent.mkdir(parents=True,exist_ok=True)
# Audit the exact input immediately before packing, including nested archives.
root=Path(__file__).resolve().parent.parent
subprocess.run([sys.executable,str(root/'Scripts/audit-release-artifact.py'),
 '--app' if a.input.suffix=='.app' else '--input',str(a.input),
 '--approvals',str(root/'Release/audit-reviewed-upstream.json'),
 '--report',str(outputs[3])],check=True)
inventory=[]
with zipfile.ZipFile(a.output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for f in files:
  name=a.input.name+'/'+str(f.relative_to(a.input))
  if Path(name).is_absolute() or '..' in Path(name).parts:raise SystemExit('Unsafe archive member')
  entry=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0));entry.create_system=3;entry.compress_type=zipfile.ZIP_DEFLATED
  mode=f.lstat().st_mode;entry.external_attr=(mode&0xffff)<<16
  data=os.readlink(f).encode() if f.is_symlink() else f.read_bytes()
  archive.writestr(entry,data)
  inventory.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'symlink':f.is_symlink()})
with outputs[1].open('x') as f:f.write(json.dumps(inventory,indent=2)+'\n')
digest=hashlib.sha256(a.output.read_bytes()).hexdigest()
with outputs[2].open('x') as f:f.write(digest+'  '+a.output.name+'\n')
print('Local archive created:',a.output.name,'members:',len(files),'sha256:',digest)
