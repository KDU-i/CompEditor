// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Completion covers the entire background operation, including pipe drain and
/// owned-directory cleanup; process-group disappearance alone is insufficient.
nonisolated final class RunActivity: @unchecked Sendable {
    let worker: RunWorker
    private let ownedDirectory: URL?
    private let completion = DispatchGroup()
    init(worker: RunWorker, ownedDirectory: URL? = nil) {
        self.worker = worker; self.ownedDirectory = ownedDirectory
        completion.enter()
    }
    /// Exactly one call from the operation's background completion path.
    func finish() {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        completion.leave()
    }
    func stopAndWait() { worker.stop(); completion.wait() }
}

@MainActor protocol RunOwnedSession: AnyObject {
    func close()
    func waitForStop()
}

/// Independent of NSDocumentController: closed documents can still have a
/// stopping session. Hold ownership until its asynchronous cleanup completes.
@MainActor final class RunSessionRegistry {
    static let shared = RunSessionRegistry()
    private var sessions: [UUID: any RunOwnedSession] = [:]
    func retain(_ session: any RunOwnedSession) -> UUID {
        let id = UUID(); sessions[id] = session; return id
    }
    func release(_ id: UUID) { sessions[id] = nil }
    func shutdown() {
        let stopping = Array(sessions.values)
        stopping.forEach { $0.close() }
        stopping.forEach { $0.waitForStop() }
        sessions.removeAll()
    }
}
