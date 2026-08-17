import Foundation

/// Serializes every metadata write in the app.
///
/// Culling is a machine-gun interaction: a photographer holding down rating and label keys
/// can fire a dozen writes at the same file inside a second. Previously each keystroke
/// spawned an independent `Task.detached` doing read-modify-write on the same `.xmp`, with
/// no ordering guarantee — so a later keystroke could be overwritten by an earlier one that
/// happened to finish last, and two writes could collide on the same scratch file.
///
/// This gives three guarantees:
///
///  1. **Ordering** — writes to one sidecar URL never overlap. A drain loop per URL owns it.
///  2. **Coalescing** — while a write is in flight, further edits to the same file replace
///     the pending value instead of queueing. Ten rapid keystrokes cost two disk writes, not
///     ten, and the file always converges on the last state the user asked for.
///  3. **Synchronous enqueue** — `submit` is not `async`. By the time it returns, the job is
///     visible to `flush()`. This matters: an earlier version made `submit` an actor method,
///     so callers had to wrap it in `Task { await … }` and `flush()` could observe an empty
///     queue *before* the job was ever enqueued — silently dropping writes at app quit.
///
/// Writes to *different* files still proceed concurrently.
public final class MetadataWriteCoordinator: @unchecked Sendable {

    public struct Job: Sendable {
        public let metadata: PhotoMetadata
        public let sidecarURL: URL
        public let imageURL: URL
        /// Embedded IPTC rewrites the whole image file, so it's opt-in per call site.
        public let writeEmbedded: Bool
        public let writeFinderTags: Bool

        public init(metadata: PhotoMetadata, sidecarURL: URL, imageURL: URL,
                    writeEmbedded: Bool = false, writeFinderTags: Bool = false) {
            self.metadata = metadata
            self.sidecarURL = sidecarURL
            self.imageURL = imageURL
            self.writeEmbedded = writeEmbedded
            self.writeFinderTags = writeFinderTags
        }
    }

    private let sidecarManager: SidecarManager
    private let embeddedWriter: EmbeddedMetadataWriter

    private let lock = NSLock()
    /// Latest desired state per sidecar URL. Superseded jobs are dropped, not queued.
    private var pending: [URL: Job] = [:]
    /// URLs with an active drain loop.
    private var draining: Set<URL> = []
    /// Continuations waiting for all work to finish (used at termination).
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastError: (url: URL, error: Error)?

    public init(sidecarManager: SidecarManager = SidecarManager(),
                embeddedWriter: EmbeddedMetadataWriter = EmbeddedMetadataWriter()) {
        self.sidecarManager = sidecarManager
        self.embeddedWriter = embeddedWriter
    }

    /// Queues a write. Returns immediately — the caller never blocks on disk — but the job
    /// is already queued when this returns, so a subsequent `flush()` is guaranteed to see it.
    public func submit(_ job: Job) {
        let needsDrain = lock.withLock { () -> Bool in
            pending[job.sidecarURL] = job
            guard !draining.contains(job.sidecarURL) else { return false }
            draining.insert(job.sidecarURL)
            return true
        }

        guard needsDrain else { return }
        let url = job.sidecarURL
        Task.detached(priority: .utility) { [self] in await drain(url) }
    }

    /// Waits until every queued write has completed. Call before the app terminates.
    public func flush() async {
        if lock.withLock({ pending.isEmpty && draining.isEmpty }) { return }

        await withCheckedContinuation { continuation in
            // Re-check under the lock: the queue may have drained while we got here.
            let alreadyIdle = lock.withLock { () -> Bool in
                if pending.isEmpty && draining.isEmpty { return true }
                quiescenceWaiters.append(continuation)
                return false
            }
            if alreadyIdle { continuation.resume() }
        }
    }

    /// The most recent write failure, for surfacing in the UI.
    public func consumeLastError() -> (url: URL, error: Error)? {
        lock.withLock {
            defer { lastError = nil }
            return lastError
        }
    }

    private func drain(_ url: URL) async {
        while true {
            let job = lock.withLock { () -> Job? in
                let next = pending.removeValue(forKey: url)
                if next == nil { draining.remove(url) }
                return next
            }

            guard let job else { break }
            await perform(job)
        }
        signalQuiescenceIfIdle()
    }

    private func signalQuiescenceIfIdle() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard draining.isEmpty && pending.isEmpty else { return [] }
            let pendingWaiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            return pendingWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Runs the actual disk work off the caller so other files keep flowing.
    private func perform(_ job: Job) async {
        let sidecar = sidecarManager
        let embedded = embeddedWriter

        let failure: Error? = await Task.detached(priority: .utility) { () -> Error? in
            var firstError: Error?

            do {
                try sidecar.write(job.metadata, to: job.sidecarURL)
            } catch {
                firstError = error
            }

            if job.writeEmbedded {
                do { try embedded.write(job.metadata, to: job.imageURL) }
                catch { firstError = firstError ?? error }
            }

            if job.writeFinderTags {
                do { try embedded.writeFinderTags(for: job.metadata, to: job.imageURL) }
                catch { firstError = firstError ?? error }
            }

            return firstError
        }.value

        if let failure {
            lock.withLock { lastError = (job.sidecarURL, failure) }
        }
    }
}
