public import Foundation

/// Watches one persisted session file and reports append bursts, debounced.
///
/// The CLI titles a session by appending records to its JSONL mid-turn, so a
/// pane that only reads the file at turn boundaries lags the terminal's tab.
/// The file may not exist yet when a fresh session starts — the watcher retries
/// until the CLI's first write creates it.
@MainActor
public final class SupermuxHarnessSessionFileWatcher {
    /// Schedules one debounced callback and returns its cancellation action.
    typealias DebounceScheduler = (
        DispatchTimeInterval,
        @escaping @MainActor () -> Void
    ) -> (@Sendable () -> Void)

    private let fileURL: URL
    private let debounce: DispatchTimeInterval
    private let debounceScheduler: DebounceScheduler
    private let onChange: @MainActor () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var retryTimer: (any DispatchSourceTimer)?
    private var cancelScheduledChange: (@Sendable () -> Void)?
    private var isCancelled = false

    /// Creates and starts a watcher for one session file.
    ///
    /// - Parameters:
    ///   - fileURL: The session JSONL to watch; may not exist yet.
    ///   - debounce: Quiet window after a write burst before `onChange` fires.
    ///   - onChange: Invoked on the main actor after each debounced burst, and
    ///     once when a previously missing file first appears.
    public convenience init(
        fileURL: URL,
        debounce: DispatchTimeInterval = .milliseconds(300),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.init(
            fileURL: fileURL,
            debounce: debounce,
            debounceScheduler: Self.scheduleDebounceOnMainQueue,
            onChange: onChange
        )
    }

    /// Test seam for driving a pending debounce callback without wall-clock time.
    init(
        fileURL: URL,
        debounce: DispatchTimeInterval,
        debounceScheduler: @escaping DebounceScheduler,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.fileURL = fileURL
        self.debounce = debounce
        self.debounceScheduler = debounceScheduler
        self.onChange = onChange
        attachOrRetry()
    }

    /// Stops watching. Safe to call more than once; deinit also cancels.
    public func cancel() {
        isCancelled = true
        source?.cancel()
        source = nil
        retryTimer?.cancel()
        retryTimer = nil
        cancelScheduledChange?()
        cancelScheduledChange = nil
    }

    deinit {
        source?.cancel()
        retryTimer?.cancel()
        cancelScheduledChange?()
    }

    private func attachOrRetry() {
        guard !isCancelled else { return }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // The CLI rewrites some records via rename; re-attach to the
                // replacement file rather than holding the dead descriptor.
                self.source?.cancel()
                self.source = nil
                self.attachOrRetry()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        // Appends between the last poll and the descriptor opening are not
        // replayed by the source; report once so no title write is missed.
        scheduleChange()
    }

    private func scheduleRetry() {
        guard !isCancelled, retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.attachOrRetry()
        }
        retryTimer = timer
        timer.resume()
    }

    private func scheduleChange() {
        guard !isCancelled else { return }
        cancelScheduledChange?()
        cancelScheduledChange = debounceScheduler(debounce) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.cancelScheduledChange?()
            self.cancelScheduledChange = nil
            self.onChange()
        }
    }

    private static func scheduleDebounceOnMainQueue(
        _ debounce: DispatchTimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> (@Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + debounce)
        timer.setEventHandler {
            action()
        }
        timer.resume()
        return {
            timer.cancel()
        }
    }
}
