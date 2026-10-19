#!/usr/bin/env python3
"""Exercise harness shell/argv behavior without requiring Apple's SDK.

Set BASH_UNDER_TEST to Bash 3.2 to test its nounset/empty-argument behavior.
The compiler stubs preserve all compile and test-execution stages, asserting the
Darwin path has zero optional linker arguments and Linux has exactly one.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExpectedOutputHarnessTests(unittest.TestCase):
    def test_optional_linker_arguments_and_all_test_stages(self):
        shell = os.environ.get('BASH_UNDER_TEST', shutil.which('bash'))
        for platform in ('Darwin', 'Linux'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix='expected harness ') as temp:
                root = Path(temp)
                binary = root / 'bin'
                binary.mkdir()
                log = root / 'calls.jsonl'
                executed = root / 'executed.jsonl'
                compiler = binary / 'swiftc'
                compiler.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['HARNESS_CALLS'], 'a') as log:
    log.write(json.dumps({'tool': pathlib.Path(sys.argv[0]).name, 'args': args}) + '\\n')
output = pathlib.Path(args[args.index('-o') + 1])
output.write_text("#!/usr/bin/env python3\\nimport json, os\\nwith open(os.environ['HARNESS_EXECUTED'], 'a') as log: log.write(json.dumps(" + repr(output.name) + ") + '\\\\n')\\n")
output.chmod(0o700)
''')
                compiler.chmod(0o700)
                shutil.copyfile(compiler, binary / 'cc')
                (binary / 'cc').chmod(0o700)
                uname = binary / 'uname'
                uname.write_text('#!/bin/sh\nprintf "%s\\n" "$HARNESS_PLATFORM"\n')
                uname.chmod(0o700)
                environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                    SWIFTC=str(compiler), HARNESS_CALLS=str(log), HARNESS_EXECUTED=str(executed),
                    HARNESS_PLATFORM=platform, TMPDIR=str(root))
                result = subprocess.run([shell, str(ROOT / 'Scripts/test-expected-output.sh')],
                    env=environment, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([call['tool'] for call in calls], ['swiftc', 'swiftc', 'cc', 'swiftc'])
                swift = [call['args'] for call in calls if call['tool'] == 'swiftc']
                self.assertEqual([Path(args[args.index('-o') + 1]).name for args in swift],
                                 ['tests', 'session-tests', 'integration-tests'])
                self.assertTrue(all('' not in args for args in swift), 'empty optional flag became an argument')
                self.assertEqual([args.count('-static-stdlib') for args in swift],
                                 [0, int(platform == 'Linux'), 0])
                self.assertEqual([json.loads(line) for line in executed.read_text().splitlines()],
                                 ['tests', 'session-tests', 'integration-tests'])
                self.assertFalse(list(root.glob('compeditor-expected.*')), 'temporary build was not cleaned')


if __name__ == '__main__':
    unittest.main(verbosity=2)
