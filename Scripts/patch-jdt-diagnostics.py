#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Compile a pinned EPL JDT patch into the app's copied JAR only. No download/install."""
import argparse, hashlib, json, subprocess, tempfile, zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--plugins', type=Path, required=True)
p.add_argument('--jdk', type=Path, required=True)
p.add_argument('--source-output', type=Path)
a = p.parse_args()
patch_root = root/'ServerPatches/jdtls-1.61'
manifest = json.loads((patch_root/'sources.json').read_text())
jar = a.plugins/'org.eclipse.jdt.ls.core_1.61.0.202609031315.jar'
if not jar.is_file(): raise SystemExit('Pinned JDT LS1.61 core JAR required; no version guessing')
server_input = json.loads((patch_root/'server-input.json').read_text())
if hashlib.sha256(jar.read_bytes()).hexdigest() != server_input['sha256']: raise SystemExit('Pinned original JDT JAR hash mismatch; use the packager with the approved input')
sources = {}
for name, digest in manifest.items():
    path = patch_root/'upstream'/name
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest: raise SystemExit('Pinned JDT source hash mismatch: '+name)
    sources[name] = raw.decode().replace('\r\n', '\n')
def replace(text, old, new):
    if text.count(old) != 1: raise SystemExit('JDT patch anchor mismatch')
    return text.replace(old, new)
life = sources['BaseDocumentLifeCycleHandler.java']
life = replace(life, 'private Map<String, Integer> documentVersions = new HashMap<>();', 'private Map<String, Integer> documentVersions = new ConcurrentHashMap<>();\n\tprivate final Map<String, Object> semanticDocumentSessions = new ConcurrentHashMap<>();')
life = replace(life, '\t\tdocumentVersions.remove(params.getTextDocument().getUri());', '\t\tdocumentVersions.remove(params.getTextDocument().getUri());\n\t\tsemanticDocumentSessions.remove(params.getTextDocument().getUri());')
life = replace(life, '\t\tdocumentVersions.put(uri, params.getTextDocument().getVersion());\n\t\tlastSyncedDocumentLengths.remove', '\t\tlastSyncedDocumentLengths.remove')
life = replace(life, '''			if (buffer != null && !buffer.getContents().equals(newContent)) {
				buffer.setContents(newContent);
			}''', '''			synchronized (reconcileLock) {
				if (buffer == null) { documentVersions.remove(uri); semanticDocumentSessions.remove(uri); return unit; }
				if (!buffer.getContents().equals(newContent)) {
					buffer.setContents(newContent);
				}
				semanticDocumentSessions.put(uri, new Object());
				documentVersions.put(uri, params.getTextDocument().getVersion());
			}''')
life = replace(life, "\t\tdocumentVersions.put(params.getTextDocument().getUri(), params.getTextDocument().getVersion());\n\t\thandleChanged(params);", "\t\tsynchronized (reconcileLock) {\n\t\t\tdocumentVersions.remove(params.getTextDocument().getUri());\n\t\t\thandleChanged(params);\n\t\t}")
# Commit the version only after every source edit was applied successfully.
life = replace(life, "\t\t\t\tlastSyncedDocumentLengths.put(uri, unit.getBuffer().getLength());", "\t\t\t\tlastSyncedDocumentLengths.put(uri, unit.getBuffer().getLength());\n\t\t\t\tdocumentVersions.put(uri, params.getTextDocument().getVersion());")
life = replace(life, "\t\t\tJavaLanguageServerPlugin.logException(\"Error while handling document change. URI: \" + uri, e);", "\t\t\tdocumentVersions.remove(uri);\n\t\t\tJavaLanguageServerPlugin.logException(\"Error while handling document change. URI: \" + uri, e);")
life = replace(life, '''		synchronized(reconcileLock) {
			unit.reconcile(ICompilationUnit.NO_AST, flags, wcOwner, monitor);''', '''		synchronized(reconcileLock) {
			String diagnosticUri = org.eclipse.jdt.ls.core.internal.ResourceUtils.toClientUri(JDTUtils.toURI(unit));
			Object session = semanticDocumentSessions.get(diagnosticUri);
			handler.semanticBindVersion(documentVersions.get(diagnosticUri), () ->
				semanticDocumentSessions.get(diagnosticUri) == session ? documentVersions.get(diagnosticUri) : null);
			unit.reconcile(ICompilationUnit.NO_AST, flags, wcOwner, monitor);''')
diag = sources['BaseDiagnosticsHandler.java']
diag = replace(diag, 'private final JavaClientConnection connection;', '''private final JavaClientConnection connection;
	private Integer semanticVersion;
	private java.util.function.Supplier<Integer> semanticCurrentVersion;
	public void semanticBindVersion(Integer version, java.util.function.Supplier<Integer> current) {
		semanticVersion = version; semanticCurrentVersion = current;
	}''')
diag = replace(diag, '''			this.connection.publishDiagnostics($);''', '''			// Publish only the version reconciled under the lifecycle lock; never guess at receipt.
			if (semanticVersion != null && semanticCurrentVersion != null && semanticVersion.equals(semanticCurrentVersion.get())) {
				$.setVersion(semanticVersion);
				this.connection.publishDiagnostics($);
			}''')
with tempfile.TemporaryDirectory(prefix='semantic-jdt-') as temp:
    folder = Path(temp); source = folder/'source'; output = folder/'classes'; source.mkdir(); output.mkdir()
    for name, text in [('BaseDocumentLifeCycleHandler.java', life), ('BaseDiagnosticsHandler.java', diag)]:
        (source/name).write_text(text)
        if a.source_output:
            a.source_output.mkdir(parents=True, exist_ok=True); (a.source_output/name).write_text(text)
    subprocess.run([str(a.jdk/'bin/javac'), '--release', '21', '-proc:none', '-classpath', str(a.plugins/'*'), '-d', str(output), *[str(path) for path in source.glob('*.java')]], check=True)
    classes = {str(path.relative_to(output)): path.read_bytes() for path in output.rglob('*.class')}
    target = folder/'patched.jar'
    with zipfile.ZipFile(jar) as original, zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as patched:
        for item in original.infolist():
            name = item.filename
            if name in classes: continue
            # Modified private binary cannot retain upstream JAR signature files.
            if name.startswith('META-INF/') and name.upper().endswith(('.SF', '.RSA', '.DSA', '.EC')): continue
            patched.writestr(item, original.read(name))
        for name, data in sorted(classes.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            patched.writestr(entry, data)
    jar.write_bytes(target.read_bytes())
print('Applied private JDT LS1.61 diagnostic-version patch; original external server input untouched')
