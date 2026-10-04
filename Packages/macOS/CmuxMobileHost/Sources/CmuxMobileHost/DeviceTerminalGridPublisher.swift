public import Foundation

/// Emits Mac mirror dimensions only when the source terminal's actual grid changes.
/// Global Ghostty ticks can replace named render notifications, so they sample
/// the cached live surface IDs without sending a replay or render-grid frame.
public struct DeviceTerminalGridPublisher: Sendable {
    public static let eventTopic = "device.terminal.grid"

    public struct Grid: Equatable, Sendable {
        public let columns: Int
        public let rows: Int
        public let generation: UInt64

        public init(columns: Int, rows: Int, generation: UInt64) {
            self.columns = columns
            self.rows = rows
            self.generation = generation
        }
    }

    public init() {}

    private var topologyGeneration: UInt64?
    private var liveSurfaceIDs = Set<UUID>()
    private var grids: [UUID: Grid] = [:]
    // SUPERMUX:begin device-grid-global-sample-floor
    /// A global tick samples every terminal at most this often; the terminals
    /// a tick names are always sampled. While another Mac is connected every
    /// Ghostty tick (one per output burst of any terminal) read every
    /// terminal's grid under its renderer lock.
    public static let globalSampleInterval: Duration = .seconds(1)
    private var lastGlobalSampleAt: ContinuousClock.Instant?
    /// True when the last refresh skipped a global sample; the caller then
    /// refreshes again once the interval has passed, so a grid that changed
    /// on that tick is still published.
    public private(set) var hasDeferredGlobalSample = false
    // SUPERMUX:end device-grid-global-sample-floor

    public mutating func refresh(
        updatedSurfaceIDs: Set<UUID>,
        global: Bool,
        topologyGeneration: UInt64,
        allSurfaceIDs: () -> Set<UUID>,
        sample: (UUID) -> Grid?,
        publish: (UUID, Grid) -> Void
    ) {
        // SUPERMUX:begin device-grid-global-sample-floor (upstream: the topology check without `topologyChanged`, then `for id in global ? liveSurfaceIDs : updatedSurfaceIDs {`)
        var topologyChanged = false
        if self.topologyGeneration != topologyGeneration {
            liveSurfaceIDs = allSurfaceIDs()
            grids = grids.filter { liveSurfaceIDs.contains($0.key) }
            self.topologyGeneration = topologyGeneration
            topologyChanged = true
        }
        let now = ContinuousClock.now
        let samplesAll = global && (topologyChanged || lastGlobalSampleAt.map { now - $0 >= Self.globalSampleInterval } ?? true)
        if samplesAll { lastGlobalSampleAt = now }
        hasDeferredGlobalSample = global && !samplesAll
        for id in samplesAll ? liveSurfaceIDs : updatedSurfaceIDs {
        // SUPERMUX:end device-grid-global-sample-floor
            guard liveSurfaceIDs.contains(id), let grid = sample(id),
                  (1...Int(UInt16.max)).contains(grid.columns),
                  (1...Int(UInt16.max)).contains(grid.rows), grids[id] != grid else { continue }
            grids[id] = grid
            publish(id, grid)
        }
    }

    public mutating func reset() {
        guard topologyGeneration != nil else { return }
        topologyGeneration = nil
        // SUPERMUX:begin device-grid-global-sample-floor
        lastGlobalSampleAt = nil
        hasDeferredGlobalSample = false
        // SUPERMUX:end device-grid-global-sample-floor
        liveSurfaceIDs.removeAll()
        grids.removeAll()
    }
}
