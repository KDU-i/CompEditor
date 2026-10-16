#!/usr/bin/env python3
"""Regression audit for the deliberately narrow diagnostics boundary."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
model = (root/'CotEditor/Sources/Semantic Completion/CopilotDiagnostics.swift').read_text()
controller = (root/'CotEditor/Sources/Semantic Completion/CopilotCompletionController.swift').read_text()
# The stored schema cannot carry strings or JSON; text is rendered from fixed enum values.
entry = model.split('struct Entry {', 1)[1].split('\n    }', 1)[0]
assert 'String' not in entry and 'LSPJSON' not in entry and 'URL' not in entry
for forbidden in ['UserDefaults', 'FileHandle', 'URLSession', 'write(to:', 'print(', 'NSLog', 'Logger(']:
    assert forbidden not in model
# Diagnostic calls must never include sensitive local variables or unrestricted errors.
for call in re.findall(r'(?<!func )diagnose\((.*?)\)(?:;|\s*\n|\s*})', controller, re.S):
    for forbidden in ['snapshot', 'uri', 'languageId', 'file', 'candidate.edit.text', 'localizedDescription', 'String(describing:', 'reason: error']:
        assert forbidden not in call, (forbidden, call)
assert 'values.prefix(20)' in controller
assert 'self.automaticPolicy.needsNextEditFallback(displayableInlineCount: candidates.count, serverAvailable: !self.nextEditsUnavailable)' in controller
assert 'if !explicit { try await Task.sleep(for: .milliseconds(50)) }' in controller
assert 'epoch += 1; work?.cancel(); work = nil;' in controller
assert 'case LSPError.methodNotFound: reason = .methodNotFound' in controller
assert 'case LSPError.timeout: reason = .timeout' in controller
assert 'default: reason = .otherError' in controller
print('Diagnostics privacy boundary and original fallback/debounce/cancellation predicates: PASS')
