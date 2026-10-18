#if DEBUG
import Foundation
import SupermuxMobileCore

/// DEBUG-only shared-order drivers for `tests/supermux/loopback_workspace_order_e2e.py`,
/// routed from ``SupermuxDevicesSocketCommands``:
///
/// - `order_state {}`: whether `supermux.order_sync.v1` is served, the mode,
///   every window's rows as the reconciler sees them (`workspace_id`,
///   `canonical_id`, `key`, `is_mirror`, `is_pinned`, `tier`, `pending_key`,
///   `order_group`) and the counters (`passes`, `own_key_writes`,
///   `own_key_writes_by_workspace`, `applies`, `set_order_sent`,
///   `set_order_received`, `set_order_refused`, `set_order_beeps`: sends that
///   ended with a beep, `workspace_updated_emits`: the fork's coalesced
///   `workspace.updated` emits).
/// - `order_key_between {lower?, upper?}`: `{key}`, minted the way capture does.
/// - `order_debug {mode: normal | paused | old_host}`: `paused` stops the
///   reconciler; `old_host` also withholds the capability, the key export and
///   `set_order` (takes effect for peers on the link's next connection).
/// - `project_move {project_id, over_project_id}`: moves a project the way the
///   sidebar does (``SupermuxProjectsModel/moveProject(_:over:)``, the shared
///   order mover); the ids are the sidebar's unified project ids, which are
///   this Mac's own ids for its projects.
@MainActor
enum SupermuxOrderSocketCommands {
    static let methods: Set<String> = ["order_state", "order_key_between", "order_debug", "project_move"]

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        methods.contains(String(name))
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) throws -> [String: Any] {
        let reconciler = SupermuxComposition.workspaceOrder
        switch String(name) {
        case "order_state":
            return state(reconciler)
        case "order_key_between":
            let key = SupermuxOrderKey().mint(
                after: params["lower"] as? String,
                before: params["upper"] as? String,
                known: reconciler.knownKeys(),
                seed: reconciler.origin
            )
            return ["key": key]
        case "order_debug":
            guard let raw = params["mode"] as? String, let mode = SupermuxOrderDebugMode(rawValue: raw) else {
                throw HookError(message: "mode must be normal, paused or old_host")
            }
            reconciler.setMode(mode)
            return ["mode": mode.rawValue]
        case "project_move":
            guard let dragged = uuid(params["project_id"]), let over = uuid(params["over_project_id"]) else {
                throw HookError(message: "project_id and over_project_id must be project UUIDs")
            }
            SupermuxComposition.projectsModel.moveProject(dragged, over: over)
            return ["project_id": dragged.uuidString, "over_project_id": over.uuidString]
        default:
            throw HookError(message: "unknown order method \(name)")
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func state(_ reconciler: SupermuxWorkspaceOrderReconciler) -> [String: Any] {
        var windows: [[String: Any]] = []
        if let app = AppDelegate.shared {
            for summary in app.listMainWindowSummaries() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let rows = reconciler.makeRows(manager).rows.map { row -> [String: Any] in
                    [
                        "workspace_id": row.id.uuidString,
                        "canonical_id": row.canonicalID,
                        "key": row.key ?? NSNull(),
                        "is_mirror": row.isMirror,
                        "is_pinned": row.isPinned,
                        "tier": row.tier,
                        "pending_key": row.pendingKey ?? NSNull(),
                        "order_group": row.unit,
                    ]
                }
                windows.append(["window_id": summary.windowId.uuidString, "rows": rows])
            }
        }
        let counters = reconciler.counters
        return [
            "capability_served": SupermuxMobileCapabilities.advertised.contains(SupermuxMobileCapability.orderSyncV1.rawValue),
            "mode": SupermuxOrderDebugMode.current.rawValue,
            "windows": windows,
            "counters": [
                "passes": counters.passes,
                "own_key_writes": counters.ownKeyWrites,
                "own_key_writes_by_workspace": Dictionary(uniqueKeysWithValues: counters.ownKeyWritesByWorkspace.map {
                    ($0.key.uuidString, $0.value)
                }),
                "applies": counters.applies,
                "set_order_sent": SupermuxComposition.mirrorOrderOutbox.sentCount,
                "set_order_received": counters.setOrderReceived,
                "set_order_refused": counters.setOrderRefused,
                "set_order_beeps": SupermuxComposition.mirrorOrderOutbox.beepCount,
                "workspace_updated_emits": SupermuxMobileActivityObserver.workspaceUpdatedEmitCount,
            ] as [String: Any],
        ]
    }
}
#endif
