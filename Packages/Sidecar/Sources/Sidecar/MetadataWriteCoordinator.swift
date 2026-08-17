import Foundation

/// Serializes every metadata write in the app.
///
/// Culling is a machine-gun interaction: a photographer holding down rating and label keys
/// can fire a dozen writes at the same file inside a second. Previously each keystroke
/// spawned an independent `Task.detached` doing read-modify-write on the same `.xmp`, with
/// no ordering guarantee — so a later keystroke could be overwritten by an earlier one that
/// happened to finish last, and two writes could collide on the same scratch file.
///
/// This actor gives two guarantees:
///
///  1. **Ordering** — writes to one sidecar URL never overlap. A drain loop per URL owns it.
///  2. **Coalescing** — while a write is in flight, further edits to the same file replace
///     the pending value instead of queueing. Ten rapid keystrokes cost two disk writes, not
///     ten, and the file always converges on the last state the user asked for.
///
/// Writes to *different* files still proceed concurrently.
public actor MetadataWriteCoordinator {

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

    /// Queues a write. Returns immediately — the caller never blocks on disk.
    public func submit(_ job: Job) {
        pending[job.sidecarURL] = job

        guard !draining.contains(job.sidecarURL) else { return }
        draining.insert(job.sidecarURL)

        Task { await self.drain(job.sidecarURL) }
    }

    /// Waits until every queued write has completed. Call before the app terminates.
    public func flush() async {
        guard !pending.isEmpty || !draining.isEmpty else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    /// The most recent write failure, for surfacing in the UI.
    public func consumeLastError() -> (url: URL, error: Error)? {
        defer { lastError = nil }
        return lastError
    }

    private func drain(_ url: URL) async {
        // Each iteration takes the newest pending value. Anything submitted while the
        // await below is suspended simply replaces `pending[url]` and gets picked up next
        // time round — that's the coalescing.
        while let job = pending.removeValue(forKey: url) {
            await perform(job)
        }
        draining.remove(url)
        signalQuiescenceIfIdle()
    }

    private func signalQuiescenceIfIdle() {
        guard draining.isEmpty, pending.isEmpty, !quiescenceWaiters.isEmpty else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Runs the actual disk work off the actor so other files keep flowing.
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
            lastError = (job.sidecarURL, failure)
        }
    }
}
