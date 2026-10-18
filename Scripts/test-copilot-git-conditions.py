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


def value_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'


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

    # Vary repository topology AND the including configuration's directory.
    # A source file at the project root sees .git/admin as descendants; ./ is
    # then true, whereas the same condition in admin/config is false.
    for topology in ['normal', 'inside-project']:
        fixture = base / ('origins-' + topology)
        fixture.mkdir()
        project = fixture / 'project[origin]'
        admin = project / ('.git' if topology == 'normal' else 'admin')
        args = ['init', '-q', '--initial-branch=main']
        if topology != 'normal':
            args += ['--separate-git-dir', str(admin)]
        assert git(fixture, *args, str(project)).returncode == 0
        (project / 'normal.py').write_text('print("synthetic")\n')
        (project / 'rules').write_text('normal.py\n')
        (project / 'matching.conf').write_text('[core]\nexcludesFile=rules\n')
        for origin in [project, admin, project / 'literal[dir]']:
            origin.mkdir(exist_ok=True)
            config = origin / 'origin.conf'
            # The chosen include's effect is an actual exclusion, so a missed
            # true condition cannot hide as merely conservative rejection.
            for pattern in ['', './', './**', './*', './.git', './admin',
                            './[a-z]*', './literal[dir]/', './../', '../',
                            str(admin.resolve()), str(admin.resolve()) + '/',
                            '**/.git', '**/admin', 'does-not-match']:
                (admin / 'config').write_text('[core]\nrepositoryformatversion=0\nbare=false\n[include]\npath=' + value_quote(str(config)) + '\n')
                condition = 'gitdir:' + pattern
                config.write_text('[includeIf ' + quote(condition) + ']\npath=' + value_quote(str(project / 'matching.conf')) + '\n')
                reference = git(project, 'check-ignore', '--no-index', '--quiet', '--', 'normal.py')
                assert reference.returncode in (0, 1), reference.stderr
                actual = subprocess.check_output([str(probe), '--probe', str(project), 'normal.py'], env=env, text=True, timeout=15).strip()
                expected = 'REFUSE' if reference.returncode == 0 else 'ALLOW'
                assert actual == expected, (topology, str(origin), condition, expected, actual)
                results.append({'topology': topology, 'origin': str(origin.relative_to(project)),
                                'condition': condition, 'gitIgnored': reference.returncode == 0, 'policy': actual})

        # Environment repository identities must be canonical and unambiguous.
        (admin / 'config').write_text('[core]\nrepositoryformatversion=0\nbare=false\n')
        alias = fixture / 'admin-alias'
        alias.symlink_to(admin, target_is_directory=True)
        canonical = dict(env, GIT_DIR=str(admin.resolve()), GIT_COMMON_DIR=str(admin.resolve()), GIT_WORK_TREE=str(project.resolve()))
        reference = subprocess.run(['/usr/bin/git', 'check-ignore', '--no-index', '--quiet', '--', 'normal.py'], cwd=project, env=canonical)
        actual = subprocess.check_output([str(probe), '--probe', str(project), 'normal.py'], env=canonical, text=True, timeout=15).strip()
        assert reference.returncode == 1 and actual == 'ALLOW'
        results.append({'case': 'canonical repository environment', 'gitIgnored': False, 'policy': actual})
        for key, value in [('GIT_DIR', str(alias)), ('GIT_CONFIG_GLOBAL', 'relative.conf'),
                           ('GIT_CONFIG_SYSTEM', 'relative.conf'),
                           ('GIT_NAMESPACE', 'synthetic'), ('GIT_CEILING_DIRECTORIES', str(fixture)),
                           ('GIT_DISCOVERY_ACROSS_FILESYSTEM', '1')]:
            changed = dict(env, **{key: value})
            actual = subprocess.check_output([str(probe), '--probe', str(project), 'normal.py'], env=changed, text=True, timeout=15).strip()
            assert actual == 'REFUSE', (key, value, actual)
            results.append({'case': 'unsupported environment identity', 'key': key,
                            'policy': actual, 'conservativeUnsupported': True})

    # Repository-format activation precedes normal config/include precedence.
    for scope in ['global', 'local', 'local-include', 'local-then-included-false',
                  'worktree-file', 'missing-version', 'duplicate-direct']:
        fixture = base / ('format-' + scope)
        fixture.mkdir()
        assert git(fixture, 'init', '-q', '--initial-branch=main', str(fixture)).returncode == 0
        admin = fixture / '.git'
        (fixture / 'Sensitive.py').write_text('print("synthetic")\n')
        (fixture / '.gitignore').write_text('sensitive.py\n')
        common = '[core]\nrepositoryformatversion=0\nbare=false\nignorecase=true\n'
        worktree = '[core]\nignorecase=false\n'
        changed = dict(env)
        if scope == 'global':
            (fixture / 'global.conf').write_text('[extensions]\nworktreeConfig=true\n')
            changed['GIT_CONFIG_GLOBAL'] = str(fixture / 'global.conf')
        elif scope == 'local':
            common += '[extensions]\nworktreeConfig=true\n'
        elif scope == 'local-include':
            (fixture / 'included.conf').write_text('[extensions]\nworktreeConfig=true\n')
            common += '[include]\npath=../included.conf\n'
        elif scope == 'local-then-included-false':
            (fixture / 'included.conf').write_text('[extensions]\nworktreeConfig=false\n')
            common += '[extensions]\nworktreeConfig=true\n[include]\npath=../included.conf\n'
        elif scope == 'worktree-file':
            worktree += '[extensions]\nworktreeConfig=true\n'
        elif scope == 'missing-version':
            common = '[core]\nbare=false\nignorecase=true\n[extensions]\nworktreeConfig=true\n'
        elif scope == 'duplicate-direct':
            common += '[extensions]\nworktreeConfig=true\nworktreeConfig=false\n'
        (admin / 'config').write_text(common)
        (admin / 'config.worktree').write_text(worktree)
        reference = subprocess.run(['/usr/bin/git', 'check-ignore', '--no-index', '--quiet', '--', 'Sensitive.py'], cwd=fixture, env=changed)
        assert reference.returncode in (0, 1)
        actual = subprocess.check_output([str(probe), '--probe', str(fixture), 'Sensitive.py'], env=changed, text=True, timeout=15).strip()
        assert actual == ('REFUSE' if reference.returncode == 0 else 'ALLOW'), (scope, reference.returncode, actual)
        results.append({'case': 'worktree format activation', 'scope': scope, 'gitIgnored': reference.returncode == 0, 'policy': actual})

    # A configured different working root must not silently lose ancestor
    # exclusions. Reject rather than reading outside the validated source root.
    fixture = base / 'working-root'
    project = fixture / 'selected'
    fixture.mkdir()
    assert git(fixture, 'init', '-q', str(project)).returncode == 0
    (project / 'normal.py').write_text('print("synthetic")\n')
    (fixture / '.gitignore').write_text('selected/normal.py\n')
    for value, conservative in [('../..', True), ('..', False), (str(project.resolve()), False)]:
        (project / '.git/config').write_text('[core]\nrepositoryformatversion=0\nbare=false\nworktree=' + value_quote(value) + '\n')
        reference = git(project, 'check-ignore', '--no-index', '--quiet', '--', 'normal.py')
        actual = subprocess.check_output([str(probe), '--probe', str(project), 'normal.py'], env=env, text=True, timeout=15).strip()
        if conservative:
            assert reference.returncode == 0 and actual == 'REFUSE'
        else:
            assert reference.returncode == 1 and actual == 'ALLOW'
        results.append({'case': 'configured working root', 'differentRootRefused': conservative,
                        'gitIgnored': reference.returncode == 0, 'policy': actual})

    # NOSYSTEM wins over an explicit system filename. Otherwise an ignored
    # system excludesFile="" could wrongly erase Git's default XDG ignore.
    fixture = base / 'system-scope'
    fixture.mkdir()
    assert git(fixture, 'init', '-q', str(fixture)).returncode == 0
    (fixture / 'normal.py').write_text('print("synthetic")\n')
    (fixture / 'ordinary.py').write_text('print("synthetic")\n')
    (fixture / 'xdg/git').mkdir(parents=True)
    (fixture / 'xdg/git/ignore').write_text('normal.py\n')
    (fixture / 'system.conf').write_text('[core]\nexcludesFile=""\n')
    for value in ['1', '0', 'true', 'false', 'yes', 'off', '', 'TrUe']:
        changed = dict(env, GIT_CONFIG_SYSTEM=str(fixture / 'system.conf'),
                       GIT_CONFIG_NOSYSTEM=value, XDG_CONFIG_HOME=str(fixture / 'xdg'))
        reference = subprocess.run(['/usr/bin/git', 'check-ignore', '--no-index', '--quiet', '--', 'normal.py'], cwd=fixture, env=changed)
        assert reference.returncode in (0, 1)
        actual = subprocess.check_output([str(probe), '--probe', str(fixture), 'normal.py'], env=changed, text=True, timeout=15).strip()
        assert actual == ('REFUSE' if reference.returncode == 0 else 'ALLOW'), (value, reference.returncode, actual)
        results.append({'case': 'system config suppression', 'nosystem': value,
                        'gitIgnored': reference.returncode == 0, 'policy': actual})
    changed = dict(env, GIT_CONFIG_SYSTEM=str(base / 'unrelated-missing-system.conf'),
                   GIT_CONFIG_NOSYSTEM='1', XDG_CONFIG_HOME=str(fixture / 'xdg'))
    reference = subprocess.run(['/usr/bin/git', 'check-ignore', '--no-index', '--quiet', '--', 'ordinary.py'], cwd=fixture, env=changed)
    actual = subprocess.check_output([str(probe), '--probe', str(fixture), 'ordinary.py'], env=changed, text=True, timeout=15).strip()
    assert reference.returncode == 1 and actual == 'ALLOW', 'Ignored system config must not be followed or authorized.'
    results.append({'case': 'ignored outside system config not followed', 'gitIgnored': False, 'policy': actual})

exact = sum(not row.get('conservativeUnsupported', False) for row in results)
print('PASS:', len(results), 'Git conditional differential cases;', exact,
      'exact outcomes; conservative unsupported cases fail closed')
print(json.dumps(results, ensure_ascii=True, separators=(',', ':')))
