#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Bounded heuristic artifact audit; reports file/type/count, never matched values."""
import argparse,json,re,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--report',type=Path,required=True);a=p.parse_args()
patterns={
 'current-user-home':re.escape(str(Path.home()).encode()),
 'user-home-path':rb'/(?:Users|home)/[^\s/"\x00<>]{1,80}',
 'private-key-marker':rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
 'provider-token-candidate':rb'(?:gh[pousr]_[A-Za-z0-9]{30,120}|github_pat_[A-Za-z0-9_]{40,160}|AKIA[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,160}|xox[baprs]-[A-Za-z0-9-]{20,160})',
 'credential-url':rb'https?://[^\s/:]{2,80}:[^\s/@]{2,100}@'}
findings=[];files=0
for f in a.app.rglob('*'):
 if f.is_symlink():continue
 if not f.is_file():continue
 files+=1
 counts={}
 if '.git' in f.parts or any(x.endswith('.dSYM') for x in f.parts) or f.suffix in ('.dSYM','.p12','.pfx','.mobileprovision','.provisionprofile','.profraw') or f.name in ('.env','.DS_Store','credentials'):
  counts['forbidden-file']=1
 # Pattern overlap fits in 512 bytes; cap read memory even for JDK modules.
 with f.open('rb') as stream:
  carry=b''
  while True:
   chunk=stream.read(4*1024*1024)
   if not chunk:break
   data=carry+chunk
   for name,pattern in patterns.items():
    matches=list(re.finditer(pattern,data));count=sum(m.end()>len(carry) for m in matches)
    if count:counts[name]=counts.get(name,0)+count
   carry=data[-512:]
 if counts:findings.append({'path':str(f.relative_to(a.app)),'types':counts})
main=a.app/'Contents/MacOS/CompEditor'
linked=subprocess.check_output(['otool','-L',str(main)],text=True)
report={'files':files,'findings':findings,'sparkle_linked':'Sparkle.framework' in linked,'sparkle_embedded':(a.app/'Contents/Frameworks/Sparkle.framework').exists(),'limits':'Heuristic patterns; binary matches may be upstream public source paths/fixtures. No credentials outside supplied artifact accessed. Does not prove absence of secrets.'}
a.report.write_text(json.dumps(report,indent=2)+'\n')
print('Artifact scan completed:',files,'files;',len(findings),'finding files. Values suppressed.')
if report['sparkle_linked'] or report['sparkle_embedded']:raise SystemExit('Updater remains in candidate')
