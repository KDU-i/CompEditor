// SPDX-License-Identifier: Apache-2.0
import Foundation

/// C owns synchronization, descriptors and the unreaped group leader. Retained
/// by each background operation until it finishes; never freed under a callback.
nonisolated final class RunWorker: RunLaunching, @unchecked Sendable {
    private let process: OpaquePointer
    private let outputLock = NSLock()
    private var retained = [Data(), Data()]
    private var decoders = [RunUTF8Decoder(), RunUTF8Decoder()]
    private let inputQueue = DispatchQueue(label: "dev.compeditor.run.stdin")
    init?() {
        guard let process = ce_run_create() else { return nil }
        self.process = process
    }
    deinit { ce_run_destroy(process) }
    func stop() { ce_run_stop(process) }
    func waitForStop() { ce_run_wait_stopped(process) }
    var acceptsInput: Bool { ce_run_accepts_input(process) != 0 }
    func eof() { inputQueue.async { [self] in ce_run_eof(process) } }
    func send(_ data: Data) {
        inputQueue.async { [self] in
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = ce_run_send(process, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n > 0 { offset += n }
                    else if n == -EAGAIN || n == -EWOULDBLOCK || n == -EINTR { Thread.sleep(forTimeInterval: 0.01) }
                    else { break }
                }
            }
        }
    }
    func output(_ stream: Int32, finished: Bool) -> RunOutput {
        outputLock.lock(); defer { outputLock.unlock() }
        let index = Int(stream)
        var omitted = 0
        var data = Data(count: 256 * 1024)
        while true {
            let n = data.withUnsafeMutableBytes { ce_run_read(process, stream, retained[index].count, $0.baseAddress, $0.count, &omitted) }
            if n == 0 { break }
            let chunk = data.prefix(n)
            retained[index].append(chunk)
            decoders[index].append(chunk)
        }
        if finished { decoders[index].append(Data(), final: true, truncated: omitted > 0) }
        return RunOutput(bytes: retained[index], omitted: omitted, decodingError: decoders[index].hadError, rendered: decoders[index].text)
    }
    func execute(_ command: RunCommand, input: Data, interactive: Bool) -> RunTermination {
        let args = ([command.executable.path] + command.arguments).map { strdup($0) }
        let env = command.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var argv = args + [nil], envp = env + [nil], status: Int32 = 0
        let error = input.withUnsafeBytes { bytes in
            argv.withUnsafeMutableBufferPointer { arguments in
                envp.withUnsafeMutableBufferPointer { environment in
                    ce_run_execute(process, command.executable.path, arguments.baseAddress!, environment.baseAddress!, command.directory.path, bytes.baseAddress, bytes.count, interactive ? 1 : 0, &status)
                }
            }
        }
        if error == ECANCELED { return .cancelled }
        if error != 0 { return .launchFailure(error) }
        let signal = status & 0x7f
        return signal == 0 ? .exit((status >> 8) & 0xff) : .signal(signal)
    }
}
