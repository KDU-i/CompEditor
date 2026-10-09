# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
# Deliberately fragmented stdio LSP peer. This is a mock, not Pyright/JDT LS.
import json, sys, time

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line: raise EOFError()
        if line == b'\r\n': break
        if line.lower().startswith(b'content-length:'): length = int(line.split(b':')[1])
    return json.loads(sys.stdin.buffer.read(length))

def send(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    packet = ('Content-Length: %s\r\n\r\n' % len(data)).encode() + data
    for offset in range(0, len(packet), 7):
        sys.stdout.buffer.write(packet[offset:offset+7]); sys.stdout.buffer.flush(); time.sleep(0.0002)

text = ''
version = 0
uri = ''

def diagnostics():
    if text.startswith('DIAG'):
        item = {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'severity': 1, 'message': 'Current error'}
        items = [] if text == 'DIAG_CLEAR' else [item]
        send({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics', 'params': {'uri': uri, 'version': version, 'diagnostics': items}})
        send({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics', 'params': {'uri': uri, 'version': version - 1, 'diagnostics': [item]}})
        send({'jsonrpc': '2.0', 'method': 'textDocument/publishDiagnostics', 'params': {'uri': uri, 'diagnostics': [item]}})
try:
    while True:
        msg = read()
        method = msg.get('method')
        if method == 'initialize':
            send({'jsonrpc':'2.0','id':msg['id'],'result':{'capabilities':{'positionEncoding':'utf-16','definitionProvider':True,'codeActionProvider':{'resolveProvider':True},'hoverProvider':True,'signatureHelpProvider':{'triggerCharacters':['(']},'textDocumentSync':{'openClose':True,'change':2},'completionProvider':{'resolveProvider':True,'triggerCharacters':['.']}}}})
            send({'jsonrpc':'2.0','method':'$/progress','params':{'value':{'percentage':0.5}}})
        elif method == 'textDocument/didOpen':
            text = msg['params']['textDocument']['text']; version = msg['params']['textDocument']['version']; uri = msg['params']['textDocument']['uri']
            diagnostics()
        elif method == 'textDocument/didChange':
            change = msg['params']['contentChanges'][0]
            assert 'range' in change
            text = change['text']; version = msg['params']['textDocument']['version']; uri = msg['params']['textDocument']['uri']
            diagnostics()
        elif method == 'textDocument/completion':
            if text == 'DELAY': time.sleep(2)
            send({'jsonrpc':'2.0','id':msg['id'],'result':{'items':[{'label':'length','insertText':'length','detail':text,'data':{'version':version,'context':msg['params'].get('context')}}]}})
        elif method == 'textDocument/hover':
            if text == 'HOVER_DELAY': time.sleep(1)
            result = None if text == 'NO_HOVER' else {'contents': {'kind': 'markdown', 'value': '```python\nprobe(count: int) -> str\n```\n' + text}, 'data': {'version': version, 'position': msg['params']['position']}}
            send({'jsonrpc': '2.0', 'id': msg['id'], 'result': result})
        elif method == 'textDocument/signatureHelp':
            if text == 'SIGNATURE_TIMEOUT': continue
            if text == 'SIGNATURE_ERROR':
                send({'jsonrpc': '2.0', 'id': msg['id'], 'error': {'code': -32603, 'message': 'No signature at this position'}})
                continue
            send({'jsonrpc': '2.0', 'id': msg['id'], 'result': {'signatures': [{'label': 'Probe(count: int)', 'documentation': {'kind': 'markdown', 'value': 'Local constructor docs'}}]}})
        elif method == 'textDocument/definition':
            if text == 'DEFINITION_DELAY': time.sleep(1)
            send({'jsonrpc': '2.0', 'id': msg['id'], 'result': [{'uri': uri, 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}}]})
        elif method == 'textDocument/codeAction':
            action = {'title': 'Replace current token', 'kind': 'quickfix', 'edit': {'documentChanges': [{'textDocument': {'uri': uri, 'version': version}, 'edits': [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'newText': 'Fixed'}]}]}}
            send({'jsonrpc': '2.0', 'id': msg['id'], 'result': [action]})
        elif method == 'completionItem/resolve':
            resolved = dict(msg['params'])
            if resolved.get('data', {}).get('resolveAddsEdit'):
                resolved['additionalTextEdits'] = [{'newText': 'import example\n', 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}}]
            send({'jsonrpc':'2.0','id':msg['id'],'result':resolved})
except (EOFError, BrokenPipeError): pass
