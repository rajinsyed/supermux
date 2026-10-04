#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel

extension TaskComposerSheet {
    func persistPickerPreferences() {
        guard store.isSignedIn, store.currentSessionGeneration == sessionGeneration,
              !selectedMacDeviceID.isEmpty, let selectedTemplateID else { return }
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID, instanceTag: selectedMacInstanceTag
        )
        store.taskTemplateStore?.setComposerPickerPreferences(
            MobileTaskComposerPickerPreferences(
                templateID: selectedTemplateID,
                model: selectedModel,
                defaultModel: displayedDefaultModel,
                effortID: selectedEffortID,
                directory: directory,
                didEditDirectory: didEditDirectory,
                workspaceGroupID: selectedWorkspaceGroupID
            ),
            macPairingID: pairingID
        )
        // Keep the legacy physical-Mac preference for older callers while the
        // pairing-aware field preserves Stable/Nightly instance identity.
        store.taskTemplateStore?.setLastMacDeviceID(selectedMacDeviceID)
        store.taskTemplateStore?.setLastMacPairingID(pairingID)
    }

    /// Called after changing the Mac identity, before the next model refresh.
    func restorePickerPreferences(templates: [MobileTaskTemplate]) {
        let fallbackTemplateID = selectedTemplateID
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID, instanceTag: selectedMacInstanceTag
        )
        let preferences = store.taskTemplateStore?.composerPickerPreferences(macPairingID: pairingID)
        // SUPERMUX:begin task-composer-typecheck (a typed helper per candidate; the closure chain timed out the Release type-checker)
        let knownTemplateID: (MobileTaskTemplate.ID?) -> MobileTaskTemplate.ID? = { id in
            guard let id, templates.contains(where: { $0.id == id }) else { return nil }
            return id
        }
        let rememberedTemplateID = knownTemplateID(preferences?.templateID)
        let currentTemplateID = knownTemplateID(fallbackTemplateID)
        let lastTemplateID = knownTemplateID(store.taskTemplateStore?.lastTemplateID())
        selectedTemplateID = rememberedTemplateID ?? currentTemplateID ?? lastTemplateID ?? templates.first?.id
        // SUPERMUX:end task-composer-typecheck
        let matchingPreferences = preferences?.templateID == selectedTemplateID ? preferences : nil
        selectedModelID = matchingPreferences?.model?.id
        explicitlySelectedModel = matchingPreferences?.model
        selectedEffortID = matchingPreferences?.effortID
        displayedModels = []
        displayedDefaultModel = matchingPreferences?.defaultModel
        displayedModelError = nil
        selectedWorkspaceGroupID = preferences?.workspaceGroupID
        pendingRestoredWorkspaceGroupID = selectedWorkspaceGroupID
        workspaceGroupSelectionRequiresResolution = false
        // A folder chosen on another Mac must never follow the route switch.
        didEditDirectory = preferences?.didEditDirectory ?? false
        if preferences?.didEditDirectory == true, let preferences {
            directory = preferences.directory
        } else {
            syncSuggestedDirectory()
        }
    }
}
#endif
