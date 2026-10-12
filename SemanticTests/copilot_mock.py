#!/usr/bin/python3
# Offline JSON-RPC peer. Synthetic strings only; no network or OAuth.
import sys, json, threading, time
lock = threading.Lock()
text = ''; version = 0; opened = {}; shown = 0; accepted = 0; cancelled = []; trigger=0; language=''; partials=[]; shown_next=0; formatting={}
def send(value):
    data = json.dumps(value).encode()
    with lock:
        sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(data)).encode()+data); sys.stdout.buffer.flush()
def reply(msg, result): send({'jsonrpc':'2.0','id':msg['id'],'result':result})
def read():
    length=0
    while True:
        line=sys.stdin.buffer.readline()
        if not line: raise EOFError
        if line==b'\r\n': break
        if line.lower().startswith(b'content-length:'): length=int(line.split(b':')[1])
    return json.loads(sys.stdin.buffer.read(length))
try:
    while True:
        msg=read(); method=msg.get('method'); p=msg.get('params',{})
        if method=='initialize':
            assert p['initializationOptions']['editorInfo']['name']=='CompEditor'
            assert p['rootUri'] is None and p['workspaceFolders']==[]
            reply(msg, {'capabilities':{'positionEncoding':'utf-16','textDocumentSync':{'openClose':True,'change':2},'inlineCompletionProvider':True}})
        elif method=='workspace/didChangeConfiguration': assert p['settings']['telemetry']['telemetryLevel']=='off'
        elif method=='signIn':
            if p.get('fail'): send({'jsonrpc':'2.0','id':msg['id'],'error':{'code':-1,'message':'Synthetic authentication failure'}})
            elif p.get('delay'): threading.Timer(.5, reply, args=(msg,{'userCode':'MOCK-CODE','command':{'command':'github.copilot.finishDeviceFlow','arguments':[]}})).start()
            else: reply(msg,{'userCode':'MOCK-CODE','command':{'command':'github.copilot.finishDeviceFlow','arguments':[]}})
        elif method=='workspace/executeCommand':
            if p['command']=='github.copilot.didAcceptCompletionItem': accepted+=1
            if p['command']=='github.copilot.finishDeviceFlow': send({'jsonrpc':'2.0','method':'didChangeStatus','params':{'kind':'Normal','busy':False}})
            reply(msg,None)
        elif method=='signOut': reply(msg,None)
        elif method=='textDocument/didOpen':
            text=p['textDocument']['text']; version=p['textDocument']['version']; opened[p['textDocument']['uri']]=version; language=p['textDocument']['languageId']
        elif method=='textDocument/didChange':
            assert 'range' in p['contentChanges'][0]
            text=p['contentChanges'][0]['text']; version=p['textDocument']['version']; opened[p['textDocument']['uri']]=version
        elif method=='textDocument/didClose': opened.pop(p['textDocument']['uri'],None)
        elif method=='textDocument/inlineCompletion':
            trigger=p['context']['triggerKind']; assert trigger in [1,2]
            assert p['textDocument']['version']==version
            formatting=p['formattingOptions']; assert formatting['tabSize'] > 0 and isinstance(formatting['insertSpaces'],bool)
            item={'insertText':'synthetic()', 'range':{'start':p['position'],'end':p['position']},'command':{'command':'github.copilot.didAcceptCompletionItem','arguments':['mock-id']}}
            items=[item]
            if trigger==1:
                alternate=dict(item); alternate['insertText']='alternative()'; items.append(alternate)
            result={'items':items,'version':version,'position':p['position']}
            if text=='DELAY': threading.Timer(.5,reply,args=(msg,result)).start()
            else: reply(msg,result)
        elif method=='textDocument/copilotInlineEdit':
            assert p['textDocument']['version']==version
            if text=='NO_NES': send({'jsonrpc':'2.0','id':msg['id'],'error':{'code':-32601,'message':'Synthetic missing public method'}})
            else: reply(msg,{'edits':[{'insertText':'next','range':{'start':{'line':0,'character':0},'end':{'line':0,'character':1}},'command':{'command':'github.copilot.didAcceptCompletionItem','arguments':['mock-nes']}}]})
        elif method=='textDocument/didShowCompletion': shown+=1
        elif method=='textDocument/didShowInlineEdit': shown_next+=1
        elif method=='textDocument/didPartiallyAcceptCompletion': partials.append(p['acceptedLength'])
        elif method=='$/cancelRequest': cancelled.append(p['id'])
        elif method=='test/burst':
            for _ in range(1000): send({'jsonrpc':'2.0','method':'test/ignored','params':{'synthetic':'x'*64}})
            reply(msg,{'messages':1000})
        elif method=='test/parity': reply(msg,{'trigger':trigger,'languageId':language,'partials':partials,'shownNext':shown_next,'formatting':formatting})
        elif method=='test/state': reply(msg,{'opened':len(opened),'shown':shown,'accepted':accepted,'cancelled':len(cancelled)})
        elif method=='shutdown': reply(msg,None)
        elif method=='exit': break
except EOFError: pass
