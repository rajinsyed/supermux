#if DEBUG
import AppKit
import CmuxMobileHost
import Foundation

/// `supermux.devices.terminal_sizing.*` drivers for the sizing recovery E2E
/// (`tests/supermux/loopback_terminal_sizing_recovery_e2e.py`), DEBUG builds
/// only. Routed from ``SupermuxTerminalSizingSocketCommands``. Each one runs
/// the code path of what it stands for, so the suite proves the real path:
///
/// - `governor {surface_id}` — the surface's apply governor (`applied`,
///   `staged`, `flush_scheduled`; `null` when it has none) and the grid the
///   terminal really has now (`surface_grid`, Ghostty's own size, cheap
///   enough to sample every 100 ms).
/// - `reset_hosts {}` — drops every viewport report and every local sizing
///   host, as this Mac quitting and relaunching does (the hosts start their
///   size-state generations over). Mirrors on another Mac keep their state.
/// - `local_scroll {surface_id, lines?}` — this Mac's user scrolling over a
///   shown terminal: a legacy wheel event (no phase, no momentum) addressed
///   to the pane's window at the pane's center (`hits_terminal` hit tests
///   the event's own location), posted to the app's event
///   queue so `NSApplication.sendEvent` dispatches it as user input. The
///   app is not activated and nothing gets focus.
/// - `activate {surface_id, textbox?}` — this Mac's user switching to the
///   app with the terminal focused: makes the terminal (with `textbox`, its
///   TextBox) first responder, makes its window key (activating the app when
///   it is not active), then runs the app-activation handler
///   (`didBecomeActiveNotification`'s). `handled` says whether the handler
///   found a focused terminal.
/// - `local_select {workspace_id, surface_id}` — this Mac's user selecting a
///   workspace and focusing one of its terminals (a sidebar click, a tab
///   click): the same selection `workspace.select` and `surface.focus` make,
///   inside a dispatch of this Mac's user's input
///   (``SupermuxLocalUserInput/beginUserAction()``). The socket methods
///   select outside one: automation, never the Mac's user.
/// - `connection_request {connection_id, method, params}` — a mobile RPC
///   (`mobile.terminal.*`) received on the phone connection
///   `connection_id`: the client id it names is recorded for that
///   connection, as the connection's authorized-request hook does, then the
///   request runs through the mobile RPC dispatcher with that connection as
///   its execution context. A refusal answers `ok: false` with the error's
///   `code`, `message` and `data`.
/// - `connection_close {connection_id, client_id?}` — that phone connection
///   closes (`removeConnection`, which drops its clients' viewport reports).
///   With `client_id`, the connection carried that client first: one call
///   is a connection of client X closing.
/// - `lane_input {surface_id, client_id, connection_id, text}` — the phone
///   `client_id` types `text` over its IRX input lane on the terminal: one
///   input frame through the lane's own delivery function. The lane's
///   control connection is `connection_id`, which carries `client_id`.
///   `delivered` is false when the lane refused the frame and closed.
/// - `hold_counts_lift {ms}` — the next counts lift a device mirror on this
///   Mac sends (`counts_override: null`, Size to My Window's first request
///   when the user had turned counting off) leaves `ms` later, as one the
///   link or the other Mac's request tasks delivered late: it lands after
///   the claim that follows it. One-shot.
@MainActor
enum SupermuxTerminalSizingRecoveryDrivers {
    static let methods: Set<String> = [
        "governor", "reset_hosts", "local_scroll", "activate", "local_select",
        "connection_request", "connection_close", "lane_input", "hold_counts_lift",
    ]

    static func handle(_ name: String, params: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "governor": return try governor(params)
        case "reset_hosts": return resetHosts()
        case "local_scroll": return try localScroll(params)
        case "activate": return try await activate(params)
        case "local_select": return try localSelect(params)
        case "connection_request": return try await connectionRequest(params)
        case "connection_close": return try connectionClose(params)
        case "lane_input": return try await laneInput(params)
        case "hold_counts_lift": return try holdCountsLift(params)
        default: throw invalid("unknown terminal_sizing method \(name)")
        }
    }

    // MARK: - Governor

    private static func governor(_ params: [String: Any]) throws -> [String: Any] {
        let id = try uuid(params, "surface_id")
        let controller = TerminalController.shared
        let grid = controller.currentMobileViewportGrid(surfaceID: id)
        var payload: [String: Any] = [
            "surface_id": id.uuidString,
            "surface_grid": grid.map { ["cols": $0.columns, "rows": $0.rows] as Any } ?? NSNull(),
            "governor": NSNull(),
        ]
        if let governor = controller.mobileViewportApplyGovernorsBySurfaceID[id] {
            payload["governor"] = [
                "applied": targetPayload(governor.applied),
                "staged": targetPayload(governor.staged),
                "flush_scheduled": governor.flushScheduled,
            ]
        }
        return payload
    }

    private static func targetPayload(_ target: MobileViewportApplyGovernor.Target?) -> Any {
        switch target {
        case nil: return NSNull()
        case .uncapped?: return ["kind": "uncapped"]
        case let .cap(columns, rows)?: return ["kind": "cap", "cols": columns, "rows": rows]
        }
    }

    // MARK: - A relaunch of this Mac's sizing state

    private static func resetHosts() -> [String: Any] {
        let controller = TerminalController.shared
        let hosts = controller.localSizingHostsBySurfaceID.count
        controller.clearAllMobileViewportReports(reason: "supermux.e2e.resetHosts")
        // clearAll skips the host reset when no report or governor is left.
        controller.resetLocalSizingHosts()
        return ["reset": true, "hosts": hosts]
    }

    // MARK: - This Mac's user

    private static func localScroll(_ params: [String: Any]) throws -> [String: Any] {
        let target = try terminal(params)
        let view = target.surface.hostedView.surfaceView
        guard let window = view.window, !target.surface.hostedView.isHidden else {
            throw invalid("the terminal's pane is not shown")
        }
        let lines = Int32(clamping: (params["lines"] as? NSNumber)?.intValue ?? 1)
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: center)
        // Quartz event locations are top-left based on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0
        ) else { throw invalid("could not create a scroll event") }
        cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        // `NSEvent(cgEvent:)` takes its window number from the event's window
        // id field (51, not public API), which the window server fills in for
        // a real wheel event; the window-under-pointer fields are not read.
        guard let windowIDField = CGEventField(rawValue: 51) else {
            throw invalid("could not address the scroll event to a window")
        }
        cgEvent.setIntegerValueField(windowIDField, value: Int64(window.windowNumber))
        // An event addressed to a window of this app takes `locationInWindow`
        // from the event's window location (top-left based, relative to the
        // window's frame), which only the window server fills in: left at
        // zero, the event lands on the window's corner, outside the pane.
        try setWindowLocation(cgEvent, CGPoint(x: center.x, y: window.frame.height - center.y))
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .scrollWheel else {
            throw invalid("could not create a scroll event")
        }
        guard event.windowNumber == window.windowNumber else {
            throw invalid("the scroll event is not addressed to the pane's window (\(event.windowNumber) != \(window.windowNumber))")
        }
        // Where AppKit will deliver it: the view under the event's location,
        // hit tested from the window's frame view (terminals are hosted in a
        // portal above the content view). Its coordinates are the window's.
        let frameView = window.contentView?.superview ?? window.contentView
        let hit = frameView?.hitTest(event.locationInWindow)
        let hitsTerminal = hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
        NSApp.postEvent(event, atStart: false)
        return [
            "surface_id": target.surfaceID.uuidString,
            "posted": true,
            "lines": Int(lines),
            "hits_terminal": hitsTerminal,
            "app_active": NSApp.isActive,
        ]
    }

    /// `CGEventSetWindowLocation` (CoreGraphics SPI, no public setter): the
    /// location AppKit reads for an event addressed to one of its windows.
    private static func setWindowLocation(_ event: CGEvent, _ location: CGPoint) throws {
        typealias Setter = @convention(c) (CGEvent, CGPoint) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            throw invalid("CGEventSetWindowLocation is unavailable")
        }
        unsafeBitCast(symbol, to: Setter.self)(event, location)
    }

    private static func activate(_ params: [String: Any]) async throws -> [String: Any] {
        let target = try terminal(params)
        let view = target.surface.hostedView.surfaceView
        guard let window = view.window, !target.surface.hostedView.isHidden else {
            throw invalid("the terminal's pane is not shown")
        }
        let useTextBox = (params["textbox"] as? Bool) ?? false
        // Focus first: an activation the app hears of finds this responder.
        if useTextBox {
            target.panel.preferTextBoxInputWhenActivated()
            let mounted = try await waitUntil(seconds: 3) { target.panel.textBoxInputView?.window === window }
            guard mounted, let box = target.panel.textBoxInputView else {
                throw invalid("the terminal's TextBox did not appear")
            }
            if window.firstResponder !== box { window.makeFirstResponder(box) }
        } else if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        let activated = !NSApp.isActive
        if activated { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        guard try await waitUntil(seconds: 3, { NSApp.isActive && NSApp.keyWindow === window }) else {
            throw invalid("the terminal's window did not become key")
        }
        let auto = SupermuxTerminalSizingAuto.shared
        let before = auto.macActivations
        auto.debugAppDidBecomeActive()
        let responder = window.firstResponder
        return [
            "surface_id": target.surfaceID.uuidString,
            "activated": activated,
            "first_responder": responder.map { String(describing: type(of: $0)) as Any } ?? NSNull(),
            "textbox_focused": useTextBox && responder === target.panel.textBoxInputView,
            "handled": auto.macActivations > before,
        ]
    }

    private static func localSelect(_ params: [String: Any]) throws -> [String: Any] {
        let workspaceID = try uuid(params, "workspace_id")
        let surfaceID = try uuid(params, "surface_id")
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            throw invalid("workspace_id must name an open workspace")
        }
        guard workspace.panels[surfaceID] != nil else {
            throw invalid("surface_id must name a panel of that workspace")
        }
        let enclosing = SupermuxLocalUserInput.beginUserAction()
        defer { SupermuxLocalUserInput.end(restoring: enclosing) }
        manager.selectWorkspace(workspace)
        workspace.focusPanel(surfaceID)
        return ["workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString, "selected": true]
    }

    // MARK: - Phone connections

    /// Phone connections these drivers opened, so the host's connection count stays balanced.
    private static var openConnections: Set<UUID> = []

    private static func open(_ connectionID: UUID, clientID: String?) {
        if openConnections.insert(connectionID).inserted { MobileHostRequestActivity.beginConnection() }
        if let clientID, !clientID.isEmpty {
            MobileHostService.shared.debugRecordClientIDForTesting(clientID, connectionID: connectionID)
        }
    }

    private static func connectionRequest(_ params: [String: Any]) async throws -> [String: Any] {
        let connectionID = try uuid(params, "connection_id")
        guard let method = params["method"] as? String, method.hasPrefix("mobile.terminal.") else {
            throw invalid("method must be a mobile.terminal.* method")
        }
        let rpcParams = (params["params"] as? [String: Any]) ?? [:]
        open(connectionID, clientID: rpcParams["client_id"] as? String)
        let context = MobileHostRPCExecutionContext(
            connectionID: connectionID, authorization: .stackBearer, artifactTransfers: nil
        )
        let request = MobileHostRPCRequest(id: nil, method: method, params: rpcParams, auth: nil)
        let result = await TerminalController.shared.mobileHostHandleRPC(request, executionContext: context)
        switch result {
        case .ok:
            return ["connection_id": connectionID.uuidString, "ok": true]
        case .failure(let error):
            return [
                "connection_id": connectionID.uuidString, "ok": false,
                "error": ["code": error.code, "message": error.message, "data": error.data ?? NSNull()],
            ]
        }
    }

    private static func connectionClose(_ params: [String: Any]) throws -> [String: Any] {
        let connectionID = try uuid(params, "connection_id")
        open(connectionID, clientID: params["client_id"] as? String)
        let clientIDs = MobileHostService.shared.clientIDs(forConnectionID: connectionID)
        openConnections.remove(connectionID)
        MobileHostService.shared.debugRemoveConnectionForTesting(id: connectionID)
        return ["connection_id": connectionID.uuidString, "closed": true, "client_ids": clientIDs.sorted()]
    }

    private static func laneInput(_ params: [String: Any]) async throws -> [String: Any] {
        let target = try terminal(params)
        let connectionID = try uuid(params, "connection_id")
        guard let clientID = params["client_id"] as? String, !clientID.isEmpty else {
            throw invalid("client_id must name the phone")
        }
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw invalid("text must not be empty")
        }
        open(connectionID, clientID: clientID)
        let delivered = await MobileHostIrxTerminalLaneServer.debugDeliverInput(
            text: text, surfaceID: target.surface.id, controlConnectionID: connectionID
        )
        return [
            "surface_id": target.surfaceID.uuidString, "client_id": clientID,
            "connection_id": connectionID.uuidString, "delivered": delivered,
        ]
    }

    // MARK: - A late counts lift

    /// How long the next device mirror counts lift waits before it is sent.
    private static var countsLiftHold: UInt64?

    private static func holdCountsLift(_ params: [String: Any]) throws -> [String: Any] {
        guard let ms = params["ms"] as? Int, ms > 0, ms <= 5000 else {
            throw invalid("ms must be 1...5000")
        }
        countsLiftHold = UInt64(ms) * 1_000_000
        return ["held_ms": ms]
    }

    /// The hold for the counts lift being sent now, once.
    static func takeCountsLiftHold() -> UInt64? {
        defer { countsLiftHold = nil }
        return countsLiftHold
    }

    // MARK: - Helpers

    private static func terminal(_ params: [String: Any]) throws -> ControlTerminalSocketTarget {
        let id = try uuid(params, "surface_id")
        guard let target = TerminalController.shared.terminalSocketTarget(surfaceID: id) else {
            throw invalid("surface_id must be a terminal id")
        }
        return target
    }

    private static func uuid(_ params: [String: Any], _ key: String) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else {
            throw invalid("\(key) must be a UUID")
        }
        return id
    }

    /// Polls `condition` every 50 ms on the main actor for up to `seconds`.
    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private static func invalid(_ message: String) -> SupermuxMirrorSocketCommands.InvalidParams {
        SupermuxMirrorSocketCommands.InvalidParams(message: message)
    }
}
#endif
