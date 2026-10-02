import AppKit
import CmuxMobileSimulatorStream
import CmuxSimulatorStreamKit
import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// A Simulator tab in a device mirror: it plays the video of a real
/// `SimulatorPanel` in the source workspace on the Mac that owns the
/// workspace (the "host panel"), and sends this Mac's clicks, keys and
/// toolbar buttons to it. Nothing simulator-related runs on this Mac: no
/// worker, `simctl` or CoreSimulator. The video is upstream's simulator
/// stream v2 (`SimulatorStreamV2Store`, the iPhone's tested engine), one
/// store per host panel.
///
/// It reuses `PanelType.simulator`, so the tab is titled, iconed, refused by
/// the Dock and saved like a local Simulator; upstream code that needs a real
/// simulator casts to `SimulatorPanel` and skips it. ``SupermuxRemoteSimulators``
/// creates it and finds (or opens) its host panel.
@MainActor
@Observable
final class SupermuxRemoteSimulatorPanel: Panel {
    /// Where the viewer stands with its host panel.
    enum HostAttachment: Equatable {
        /// Looking for, or opening, the host panel.
        case finding
        /// Showing ``SupermuxRemoteSimulatorPanel/hostPanelID``.
        case attached
        /// The host panel is gone ("Closed on <Mac>" and Open Again).
        case closedOnHost
        /// Opening one failed; the text says why.
        case failed(String)
    }

    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .simulator
    /// The Mac the simulator runs on.
    let machine: SurfaceMachineID
    /// The source workspace on that Mac.
    let remoteWorkspaceID: String

    private(set) var attachment = HostAttachment.finding
    private(set) var hostPanelID: UUID?
    /// The simulator the host panel shows, once known.
    private(set) var deviceUDID: String?
    /// The owning Mac's simulators, for the device menu.
    private(set) var devices: [SupermuxRemoteSimulatorHostClient.Device] = []
    private(set) var store: SimulatorStreamV2Store?
    private(set) var lastConfig: SimStreamConfig?
    private(set) var configsApplied = 0
    private(set) var quality = SupermuxRemoteSimulatorQuality.saved
    /// Whether the owning Mac serves rotate and the keyboard toggle.
    var supportsControls = false
    /// Another viewer (the phone, another Mac) took the stream. Latched until
    /// Show Here, so the two never take it back and forth on their own.
    private(set) var isSuperseded = false

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored let displayView: SupermuxRemoteSimulatorDisplayView
    @ObservationIgnored private var presenter: SupermuxRemoteSimulatorPresenter?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var keepsHostPanel = false
    @ObservationIgnored private var linkWasReady = false
    @ObservationIgnored private var needsRebind = false
    @ObservationIgnored private var rebindTask: Task<Void, Never>?
    @ObservationIgnored private var autoLongSide = SimStreamQualityPreset.high.maximumLongSidePixels
    @ObservationIgnored private var autoQualityTask: Task<Void, Never>?

    var displayTitle: String {
        String(localized: "simulator.pane.title", defaultValue: "Simulator")
    }

    var displayIcon: String? { "iphone" }

    /// The owning Mac's name, for the tab's texts.
    var macName: String {
        SupermuxComposition.devices.device(for: machine)?.displayName ?? machine.rawValue
    }

    /// The selected device's name, once the device menu has loaded.
    var deviceName: String? {
        devices.first { $0.udid == deviceUDID }?.name
    }

    var hostClient: SupermuxRemoteSimulatorHostClient {
        SupermuxRemoteSimulatorHostClient(machine: machine, workspaceID: remoteWorkspaceID)
    }

    /// The long-side cap the stream asks for now.
    var currentLongSide: UInt16 {
        quality.fixedLongSidePixels ?? autoLongSide
    }

    private var isLinkReady: Bool {
        SupermuxComposition.devices.device(for: machine)?.isConnected == true
    }

    init(
        machine: SurfaceMachineID,
        remoteWorkspaceID: String,
        hostPanelID: UUID?,
        deviceUDID: String?,
        workspace: Workspace
    ) {
        self.machine = machine
        self.remoteWorkspaceID = remoteWorkspaceID
        self.hostPanelID = hostPanelID
        self.deviceUDID = deviceUDID
        self.workspace = workspace
        displayView = SupermuxRemoteSimulatorDisplayView()
        presenter = SupermuxRemoteSimulatorPresenter(view: displayView) { [weak self] config in
            self?.configApplied(config)
        }
        displayView.onInput = { [weak self] event in self?.send(event) }
        displayView.onBackingLongSideChange = { [weak self] pixels in self?.backingLongSideChanged(pixels) }
        linkWasReady = isLinkReady
        observeLink()
    }

    // MARK: - Host panel

    /// Shows `hostPanelID`: a fresh stream store (a new host panel is a new
    /// stream), started now when the tab is visible.
    func attach(hostPanelID: UUID, deviceUDID: String?) {
        guard !isClosed else { return }
        if let deviceUDID { self.deviceUDID = deviceUDID }
        attachment = .attached
        needsRebind = false
        guard self.hostPanelID != hostPanelID || store == nil else { return }
        store?.deactivate()
        self.hostPanelID = hostPanelID
        isSuperseded = false
        let machine = machine
        let newStore = SimulatorStreamV2Store(
            panelID: hostPanelID.uuidString,
            opener: { try await SupermuxRemoteSimulatorLane.open(machine: machine, panelID: hostPanelID) },
            transportReady: { [weak self] in self?.isLinkReady ?? false },
            maximumLongSidePixels: currentLongSide
        )
        if let presenter { newStore.bindPresenter(presenter) }
        store = newStore
        observeStore(newStore)
        if isVisible { newStore.activate() }
        Task { await refreshDevices() }
    }

    /// Finding or opening the host panel failed.
    func attachFailed(_ message: String) {
        guard !isClosed else { return }
        attachment = .failed(message)
    }

    /// After a relaunch the saved host panel may be gone (the owning Mac
    /// restores its own panel with a new id): find it again once the link
    /// is up (``SupermuxRemoteSimulators/rebind(_:create:)``).
    func rebindWhenLinked() {
        needsRebind = true
        attachment = .finding
        startRebindIfReady(create: true)
    }

    /// "Open Again" after the owning Mac closed or lost the panel.
    func openAgain() {
        attachment = .finding
        needsRebind = true
        startRebindIfReady(create: true)
    }

    private func startRebindIfReady(create: Bool) {
        guard !isClosed, needsRebind, isLinkReady, rebindTask == nil else { return }
        rebindTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await SupermuxRemoteSimulators.shared.rebind(self, create: create)
            self.rebindTask = nil
        }
    }

    /// The host panel stopped existing while the link stayed up.
    func markClosedOnHost() {
        guard !isClosed else { return }
        needsRebind = false
        store?.deactivate()
        store = nil
        attachment = .closedOnHost
    }

    // MARK: - Visibility and input

    /// The tab became visible or hidden: a hidden viewer stops its stream, so
    /// the owning Mac stops encoding.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard let store else { return }
        if !visible {
            store.deactivate()
        } else if !isSuperseded {
            store.activate()
        }
    }

    /// "Show Here": takes the stream back from the other viewer.
    func showHere() {
        isSuperseded = false
        guard let store, isVisible else { return }
        if case .unavailable = store.phase {
            store.refresh()
        } else {
            store.activate()
        }
    }

    func send(_ event: SimStreamInputEvent) {
        store?.send(event)
    }

    func sendText(_ text: String) {
        store?.sendText(text)
    }

    func press(_ button: SimStreamHardwareButton) {
        store?.sendButton(button)
    }

    /// Rotate, the software keyboard or the appearance, on the owning Mac.
    func runControl(_ action: String) {
        guard let hostPanelID else { return }
        let host = hostClient
        Task { try? await host.control(action, panelID: hostPanelID) }
    }

    /// Restarts the owning Mac's crashed simulator worker.
    func recover() {
        guard let hostPanelID else { return }
        let host = hostClient
        Task { @MainActor [weak self] in
            try? await host.recover(panelID: hostPanelID)
            self?.store?.refresh()
        }
    }

    // MARK: - Devices

    /// Reloads the owning Mac's device menu (and which device it shows).
    func refreshDevices() async {
        guard let hostPanelID else { return }
        guard let listed = try? await hostClient.deviceList(panelID: hostPanelID),
              self.hostPanelID == hostPanelID else { return }
        devices = listed
        if let selected = listed.first(where: \.isSelected) {
            deviceUDID = selected.udid
        }
    }

    /// Shows another simulator, booting it on the owning Mac when needed.
    func selectDevice(_ udid: String) async {
        guard let hostPanelID else { return }
        deviceUDID = udid
        try? await hostClient.select(udid: udid, panelID: hostPanelID)
        await refreshDevices()
    }

    // MARK: - Quality

    func setQuality(_ quality: SupermuxRemoteSimulatorQuality) {
        self.quality = quality
        SupermuxRemoteSimulatorQuality.saved = quality
        store?.setQuality(maximumLongSidePixels: currentLongSide)
    }

    /// Auto follows the viewer's size, settled for half a second so a live
    /// resize does not rebuild the owning Mac's encoder on every step.
    private func backingLongSideChanged(_ pixels: CGFloat) {
        let next = SupermuxRemoteSimulatorQuality.autoLongSide(forBackingPixels: pixels)
        guard next != autoLongSide else { return }
        autoQualityTask?.cancel()
        autoQualityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.autoLongSide = next
            if self.quality == .auto {
                self.store?.setQuality(maximumLongSidePixels: next)
            }
        }
    }

    private func configApplied(_ config: SimStreamConfig) {
        let sizeChanged = lastConfig?.pixelWidth != config.pixelWidth || lastConfig?.pixelHeight != config.pixelHeight
        lastConfig = config
        configsApplied += 1
        // A new size usually means another device; learn which.
        if sizeChanged || deviceUDID == nil {
            Task { await refreshDevices() }
        }
    }

    // MARK: - Observation

    private func observeStore(_ store: SimulatorStreamV2Store) {
        withObservationTracking {
            _ = store.phase
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.store === store else { return }
                self.storePhaseChanged(store.phase)
                self.observeStore(store)
            }
        }
    }

    /// The owning Mac ended the stream for good (`closed`): it closed the
    /// panel, lost it, or another viewer took it.
    private func storePhaseChanged(_ phase: SimStreamViewerPhase) {
        guard case .unavailable(let detail) = phase else { return }
        switch detail {
        case "superseded":
            isSuperseded = true
        case "panel_closed":
            closeBecauseHostClosed()
        case "panel_not_found":
            needsRebind = true
            attachment = .finding
            store?.deactivate()
            store = nil
            startRebindIfReady(create: false)
        default:
            break
        }
    }

    private func observeLink() {
        withObservationTracking {
            _ = SupermuxComposition.devices.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.linkChanged()
                self.observeLink()
            }
        }
    }

    private func linkChanged() {
        let ready = isLinkReady
        guard ready != linkWasReady else { return }
        linkWasReady = ready
        store?.noteTransportReady(ready)
        if ready { startRebindIfReady(create: true) }
    }

    // MARK: - Closing

    /// The owning Mac closed the host panel: this tab goes too.
    private func closeBecauseHostClosed() {
        dismissKeepingHostPanel()
    }

    /// Closes this tab without touching the host panel (the owning Mac
    /// closed it, or cannot stream it here).
    func dismissKeepingHostPanel() {
        keepsHostPanel = true
        if let workspace, workspace.panels[id] != nil {
            _ = workspace.closePanel(id, force: true)
        }
    }

    /// Closing the tab here (its tab or pane) closes the host panel there, as
    /// closing a mirrored terminal does; the simulator device keeps running.
    /// Closing the mirror or its window, or a close the owning Mac started,
    /// closes only this viewer. A user close has already removed the panel's
    /// Bonsplit tab; a workspace teardown closes panels while their tabs exist.
    private var isClosedByUser: Bool {
        guard let workspace, let tabID = workspace.surfaceIdFromPanelId(id) else { return false }
        return workspace.bonsplitController.tab(tabID) == nil
    }

    func close() {
        guard !isClosed else { return }
        let closesHostPanel = !keepsHostPanel && isClosedByUser
        isClosed = true
        rebindTask?.cancel()
        rebindTask = nil
        autoQualityTask?.cancel()
        store?.deactivate()
        store = nil
        guard closesHostPanel, let hostPanelID else { return }
        let host = hostClient
        Task { try? await host.close(panelID: hostPanelID) }
    }

    // MARK: - Focus

    func focus() {
        guard let window = displayView.window, window.firstResponder !== displayView else { return }
        window.makeFirstResponder(displayView)
    }

    func unfocus() {}

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        responder === displayView && displayView.window === window ? .panel : nil
    }

    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent == .panel, window.firstResponder === displayView else { return false }
        return window.makeFirstResponder(nil)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
