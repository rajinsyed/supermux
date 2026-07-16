public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.project(s).*` and
/// `mobile.supermux.preset.*` write methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping that ``SupermuxMacClient`` sends is what fakes record and
/// tests assert against (UI-03: recorded calls match architecture §2 and
/// m2-f3's committed shapes exactly). Optional params are omitted — never
/// sent as empty strings.

/// `mobile.supermux.project.create`: `{root_path}`.
public struct SupermuxProjectCreateRequest: Equatable, Sendable {
    /// Absolute path of an existing folder on the Mac.
    public let rootPath: String

    /// Creates the request.
    /// - Parameter rootPath: Absolute folder path on the Mac.
    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.projectCreate.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["root_path": rootPath]
    }
}

/// `mobile.supermux.project.update`: `{project_id, patch}`.
public struct SupermuxProjectUpdateRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String
    /// The present-key patch to apply.
    public let patch: SupermuxProjectPatch

    /// Creates the request.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - patch: The present-key patch to apply.
    public init(projectID: String, patch: SupermuxProjectPatch) {
        self.projectID = projectID
        self.patch = patch
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.projectUpdate.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID, "patch": patch.wireObject]
    }
}

/// `mobile.supermux.project.delete`: `{project_id}`.
public struct SupermuxProjectDeleteRequest: Equatable, Sendable {
    /// The project's UUID string.
    public let projectID: String

    /// Creates the request.
    /// - Parameter projectID: The project's UUID string.
    public init(projectID: String) {
        self.projectID = projectID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.projectDelete.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["project_id": projectID]
    }
}

/// `mobile.supermux.projects.set_section_collapsed`: `{collapsed}`.
public struct SupermuxProjectsSetSectionCollapsedRequest: Equatable, Sendable {
    /// The collapse state to persist Mac-side.
    public let collapsed: Bool

    /// Creates the request.
    /// - Parameter collapsed: The collapse state to persist.
    public init(collapsed: Bool) {
        self.collapsed = collapsed
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.projectsSetSectionCollapsed.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["collapsed": collapsed]
    }
}

/// `mobile.supermux.preset.create`: flat `{name, command, icon_symbol?,
/// color_hex?}` — the Mac assigns the identity.
public struct SupermuxPresetCreateRequest: Equatable, Sendable {
    /// Chip label (required non-empty).
    public let name: String
    /// Shell command (required non-empty).
    public let command: String
    /// Optional SF Symbol for the chip.
    public let iconSymbol: String?
    /// Optional `#RRGGBB` accent.
    public let colorHex: String?

    /// Creates the request.
    /// - Parameters:
    ///   - name: Chip label (required non-empty).
    ///   - command: Shell command (required non-empty).
    ///   - iconSymbol: Optional SF Symbol for the chip.
    ///   - colorHex: Optional `#RRGGBB` accent.
    public init(name: String, command: String, iconSymbol: String? = nil, colorHex: String? = nil) {
        self.name = name
        self.command = command
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.presetCreate.rawValue }

    /// The exact wire params (optionals omitted when absent).
    public var wireParams: [String: Any] {
        var params: [String: Any] = ["name": name, "command": command]
        if let iconSymbol {
            params["icon_symbol"] = iconSymbol
        }
        if let colorHex {
            params["color_hex"] = colorHex
        }
        return params
    }
}

/// `mobile.supermux.preset.update`: `{preset_id, patch}`.
public struct SupermuxPresetUpdateRequest: Equatable, Sendable {
    /// The preset's UUID string.
    public let presetID: String
    /// The present-key patch to apply.
    public let patch: SupermuxPresetPatch

    /// Creates the request.
    /// - Parameters:
    ///   - presetID: The preset's UUID string.
    ///   - patch: The present-key patch to apply.
    public init(presetID: String, patch: SupermuxPresetPatch) {
        self.presetID = presetID
        self.patch = patch
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.presetUpdate.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["preset_id": presetID, "patch": patch.wireObject]
    }
}

/// `mobile.supermux.preset.delete`: `{preset_id}`.
public struct SupermuxPresetDeleteRequest: Equatable, Sendable {
    /// The preset's UUID string.
    public let presetID: String

    /// Creates the request.
    /// - Parameter presetID: The preset's UUID string.
    public init(presetID: String) {
        self.presetID = presetID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.presetDelete.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["preset_id": presetID]
    }
}
