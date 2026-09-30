import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local
    case remoteCloud(CloudVMFileExplorerProvider)
    // SUPERMUX:begin mirror-file-search-scope
    case supermuxDevice(SupermuxDeviceFileExplorerProvider)
    // SUPERMUX:end mirror-file-search-scope

    /// Derives the search scope from the active file provider.
    init(provider: FileExplorerProvider?) {
        if provider is LocalFileExplorerProvider {
            self = .local
        } else if let cloudProvider = provider as? CloudVMFileExplorerProvider {
            self = .remoteCloud(cloudProvider)
        // SUPERMUX:begin mirror-file-search-scope
        } else if let deviceProvider = provider as? SupermuxDeviceFileExplorerProvider {
            self = .supermuxDevice(deviceProvider)
        // SUPERMUX:end mirror-file-search-scope
        } else {
            self = .unsupported
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local), (.unsupported, .unsupported): return true
        case let (.remoteCloud(a), .remoteCloud(b)): return a.id == b.id
        // SUPERMUX:begin mirror-file-search-scope
        case let (.supermuxDevice(a), .supermuxDevice(b)): return a === b
        // SUPERMUX:end mirror-file-search-scope
        default: return false
        }
    }

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        case .remoteCloud: return "remoteCloud"
        // SUPERMUX:begin mirror-file-search-scope
        case .supermuxDevice: return "supermuxDevice"
        // SUPERMUX:end mirror-file-search-scope
        }
    }

}
