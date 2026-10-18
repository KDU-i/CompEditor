#!/usr/bin/env python3
# Original differential tests for the unofficial Java/Python semantic fork.
# SPDX-License-Identifier: Apache-2.0
"""Compare real conditional config/exclusion evaluation with the app policy.

Only synthetic source/config is created. No user/global config or remote is read.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

probe = Path(sys.argv[1]).resolve()
env = {"PATH": "/usr/bin:/bin", "TMPDIR": tempfile.gettempdir(),
       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
       "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"}
results = []


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def git(root, *args):
    return subprocess.run(['/usr/bin/git', '--no-optional-locks', *args],
                          cwd=root, env=env, capture_output=True)


def check(project, admin, condition, conservative=False):
    # A matching include turns case matching off, so both true and false
    # condition results are observable. False positives also become failures.
    (admin / 'config').write_bytes((
        '[core]\nrepositoryformatversion=0\nbare=false\nignoreCase=true\n'
        '[includeIf ' + quote(condition) + ']\npath=condition.conf\n').encode())
    reference = git(project, 'check-ignore', '--no-index', '--quiet', '--', 'Sensitive.py')
    assert reference.returncode in (0, 1), (condition, reference.stderr)
    actual = subprocess.run([str(probe), '--probe', str(project), 'Sensitive.py'],
                            env=env, capture_output=True, text=True, check=True, timeout=15).stdout.strip()
    expected = 'REFUSE' if conservative or reference.returncode == 0 else 'ALLOW'
    assert actual == expected, (condition, expected, actual)
    results.append({'condition': condition, 'gitIgnored': reference.returncode == 0,
                    'policy': actual, 'conservativeUnsupported': conservative})
    if len(results) % 20 == 0:
        print('PROGRESS:', len(results), 'conditional cases', flush=True)


with tempfile.TemporaryDirectory(prefix='nes031-condition-differential-') as temporary:
    base = Path(temporary)
    for index, name in enumerate(['admin', 'admin ', 'admin\t', 'ad\rmin', 'ad"min', 'ad[min]', 'ADMIN', 'café']):
        fixture = base / str(index)
        fixture.mkdir()
        project, admin = fixture / 'project', fixture / name
        assert git(fixture, 'init', '-q', '--initial-branch=main', '--separate-git-dir', str(admin), str(project)).returncode == 0
        (project / 'Sensitive.py').write_text('print("ordinary synthetic source")\n')
        (project / '.gitignore').write_text('sensitive.py\n')
        (admin / 'condition.conf').write_text('[core]\nignoreCase=false\n')
        for pattern in ['main', 'main ', 'main\r', 'main\t', ' main', 'main\\ ',
                        'main\\', 'ma?n', 'm*', '*', '**', '**/main', 'main/',
                        'main/**', '[a-z]ain', '[[:lower:]]ain', '[!x]ain',
                        '#main', '!main', 'main"', 'MAIn', 'máin']:
            check(project, admin, 'onbranch:' + pattern)
        exact = str(admin.resolve())
        escaped = exact.replace('[', '\\[').replace(']', '\\]')
        for pattern in [exact, exact + ' ', exact + '\r', exact + '\t', exact + '/',
                        exact + '/**', exact + '*', escaped, '**/' + name,
                        name, './' + name, './', './**', './../' + name,
                        str(admin.parent) + '/*', str(admin.parent) + '/**',
                        str(admin.parent) + '/[a-z]*', 'does-not-match']:
            check(project, admin, 'gitdir:' + pattern)
        for pattern in [escaped.lower(), escaped.upper(), '**/ADMIN', 'admin ',
                        exact + '\r', 'does-not-match']:
            # Case-folded bracket semantics are deliberately unsupported, not
            # silently approximated. They must refuse even when Git would allow.
            check(project, admin, 'gitdir/i:' + pattern, conservative='[' in pattern)
        check(project, admin, 'gitdir/i:**/[a-z]*', conservative=True)
    # Exact regression 2: matching gitdir with a trailing-space admin must load
    # the actual exclusion rule, including its root-relative path semantics.
    fixture = base / 'trailing-space-regression'
    fixture.mkdir()
    project, admin = fixture / 'project', fixture / 'admin '
    assert git(fixture, 'init', '-q', '--initial-branch=main', '--separate-git-dir', str(admin), str(project)).returncode == 0
    (project / 'normal.py').write_text('print("synthetic")\n')
    (project / 'rules').write_text('normal.py\n')
    (admin / 'condition.conf').write_text('[core]\nexcludesFile=rules\n')
    (admin / 'config').write_text('[core]\nrepositoryformatversion=0\nbare=false\n[includeIf ' + quote('gitdir:' + str(admin.resolve())) + ']\npath=condition.conf\n')
    assert git(project, 'check-ignore', '--no-index', '--quiet', '--', 'normal.py').returncode == 0
    assert subprocess.check_output([str(probe), '--probe', str(project), 'normal.py'], env=env, text=True).strip() == 'REFUSE'
    results.append({'case': 'matching trailing-space gitdir exclusion', 'gitIgnored': True, 'policy': 'REFUSE'})

exact = sum(not row.get('conservativeUnsupported', False) for row in results)
print('PASS:', len(results), 'Git conditional differential cases;', exact,
      'exact outcomes; conservative unsupported cases fail closed')
print(json.dumps(results, ensure_ascii=True, separators=(',', ':')))
