public import SupermuxMobileCore

/// Typed decoders for the project/preset write RPC results, exactly as
/// `SupermuxMobileHost+Projects.swift` / `+PresetsActions.swift` emit them.
/// Confirmation-only fields decode leniently so old or partial hosts never
/// break the phone.

/// `mobile.supermux.project.create` / `project.update` result:
/// `{project: SupermuxProjectDTO}`.
public struct SupermuxProjectWriteResponse: Codable, Sendable, Equatable {
    /// The created/updated record (the response's whole point — required).
    public var project: SupermuxProjectDTO

    /// Creates a response value (used by tests and fakes).
    /// - Parameter project: The created/updated record.
    public init(project: SupermuxProjectDTO) {
        self.project = project
    }
}

/// `mobile.supermux.project.delete` result: `{removed: true, project_id}`.
public struct SupermuxProjectDeleteResponse: Codable, Sendable, Equatable {
    /// Whether the Mac removed the registration.
    public var removed: Bool?
    /// The removed project's UUID string.
    public var projectId: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - removed: Whether the Mac removed the registration.
    ///   - projectId: The removed project's UUID string.
    public init(removed: Bool? = nil, projectId: String? = nil) {
        self.removed = removed
        self.projectId = projectId
    }

    private enum CodingKeys: String, CodingKey {
        case removed
        case projectId = "project_id"
    }
}

/// `mobile.supermux.projects.set_section_collapsed` result:
/// `{section_collapsed}`.
public struct SupermuxSectionCollapsedResponse: Codable, Sendable, Equatable {
    /// The collapse state the Mac persisted.
    public var sectionCollapsed: Bool?

    /// Creates a response value (used by tests and fakes).
    /// - Parameter sectionCollapsed: The persisted collapse state.
    public init(sectionCollapsed: Bool? = nil) {
        self.sectionCollapsed = sectionCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case sectionCollapsed = "section_collapsed"
    }
}

/// `mobile.supermux.preset.create` / `preset.update` result:
/// `{preset: SupermuxTerminalPresetDTO}`.
public struct SupermuxPresetWriteResponse: Codable, Sendable, Equatable {
    /// The created/updated record (the response's whole point — required).
    public var preset: SupermuxTerminalPresetDTO

    /// Creates a response value (used by tests and fakes).
    /// - Parameter preset: The created/updated record.
    public init(preset: SupermuxTerminalPresetDTO) {
        self.preset = preset
    }
}

/// `mobile.supermux.preset.delete` result: `{removed: true, preset_id}`.
public struct SupermuxPresetDeleteResponse: Codable, Sendable, Equatable {
    /// Whether the Mac removed the preset.
    public var removed: Bool?
    /// The removed preset's UUID string.
    public var presetId: String?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - removed: Whether the Mac removed the preset.
    ///   - presetId: The removed preset's UUID string.
    public init(removed: Bool? = nil, presetId: String? = nil) {
        self.removed = removed
        self.presetId = presetId
    }

    private enum CodingKeys: String, CodingKey {
        case removed
        case presetId = "preset_id"
    }
}
