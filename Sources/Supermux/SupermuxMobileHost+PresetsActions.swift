import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.preset.*` write handlers: the Mac side of the iOS
/// terminal-presets editor. All mutations flow through
/// ``SupermuxProjectsModel``'s presets extension (the same persistence chain
/// the desktop presets bar uses), and the wire parsing/patch semantics are
/// the package-tested ``SupermuxMobilePresetPatch``. `preset.launch` and
/// `action.run` are a later feature and deliberately absent — dispatch keeps
/// returning `method_not_found` for them until the capability ships.
///
/// `supermux.projects.updated` (presets persist in the projects file) is
/// emitted by ``SupermuxMobileProjectsObserver`` watching the model, so
/// mobile and desktop preset edits poke the phone through one path.
extension TerminalController {
    /// `mobile.supermux.preset.create`: appends a new launchable preset from
    /// flat params `{name, command, icon_symbol?, color_hex?}` (the Mac
    /// assigns the identity). Result: `{preset: SupermuxTerminalPresetDTO}`.
    @MainActor
    func v2SupermuxPresetCreate(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        do {
            preset = try SupermuxMobilePresetPatch.createPreset(fromWire: params)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed preset params", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        model.addPreset(preset)
        return supermuxPresetResult(preset)
    }

    /// `mobile.supermux.preset.update`: applies `patch` to the preset named
    /// by `preset_id` (patch semantics: only present keys applied; explicit
    /// `null` clears `icon_symbol`/`color_hex`; immutable/unknown keys
    /// rejected). Result: `{preset: SupermuxTerminalPresetDTO}`.
    @MainActor
    func v2SupermuxPresetUpdate(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        switch await supermuxResolvePreset(params: params) {
        case let .failure(error): return error
        case let .success(resolved): preset = resolved
        }
        guard let patchObject = params["patch"] as? [String: Any] else {
            return .err(code: "invalid_params", message: "patch must be an object", data: nil)
        }
        let updated: SupermuxTerminalPreset
        do {
            let patch = try SupermuxMobilePresetPatch(wire: patchObject)
            updated = patch.applied(to: preset)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed patch", data: nil)
        }
        SupermuxComposition.projectsModel.updatePreset(updated)
        return supermuxPresetResult(updated)
    }

    /// `mobile.supermux.preset.delete`: removes the preset from the bar. The
    /// confirmation dialog lives on the phone. Result:
    /// `{removed: true, preset_id}`.
    @MainActor
    func v2SupermuxPresetDelete(params: [String: Any]) async -> V2CallResult {
        let preset: SupermuxTerminalPreset
        switch await supermuxResolvePreset(params: params) {
        case let .failure(error): return error
        case let .success(resolved): preset = resolved
        }
        SupermuxComposition.projectsModel.removePreset(id: preset.id)
        return .ok([
            "removed": true,
            "preset_id": preset.id.uuidString,
        ])
    }

    // MARK: - Shared pieces

    /// Resolves the request's `preset_id` against the loaded model, or the
    /// wire error to return (`invalid_params` / `not_found`).
    @MainActor
    private func supermuxResolvePreset(
        params: [String: Any]
    ) async -> SupermuxParamResolution<SupermuxTerminalPreset> {
        guard let idString = params["preset_id"] as? String,
              let presetID = UUID(uuidString: idString) else {
            return .failure(.err(code: "invalid_params", message: "preset_id must be a preset UUID", data: nil))
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        guard let preset = model.presets.first(where: { $0.id == presetID }) else {
            return .failure(.err(code: "not_found", message: "Unknown preset", data: [
                "preset_id": idString,
            ]))
        }
        return .success(preset)
    }

    /// The `{preset: SupermuxTerminalPresetDTO}` result for one record.
    private func supermuxPresetResult(_ preset: SupermuxTerminalPreset) -> V2CallResult {
        do {
            let payload: [String: Any] = [
                "preset": try SupermuxWireJSON().dictionary(from: SupermuxTerminalPresetDTO(preset: preset)),
            ]
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode preset", data: nil)
        }
    }
}
