import Foundation

/// Find over a device mirror's folder (`FileSearchScope.supermuxDevice`,
/// touchpoint `mirror-file-search-scope`): ripgrep runs on the owning Mac and
/// the results land exactly like a Cloud search's.
@MainActor
extension FileSearchController {
    func startSupermuxDeviceSearch(provider: SupermuxDeviceFileExplorerProvider, query: String, rootPath: String) {
        generation += 1
        let searchGeneration = generation
        emit(status: .searching, isSearching: true)
        searchTask = Task { [weak self] in
            do {
                let snapshot = try await provider.search(query: query, rootPath: rootPath)
                guard !Task.isCancelled else { return }
                self?.finishRemoteSearch(snapshot, generation: searchGeneration)
            } catch is CancellationError {
                return
            } catch {
                self?.finishRemoteSearch(
                    FileSearchSnapshot(query: query, results: [], status: .failed(error.localizedDescription), isSearching: false),
                    generation: searchGeneration
                )
            }
        }
    }
}
