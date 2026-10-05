import Foundation

/// Red stub (review T3, H3, I4): not implemented yet.
public struct SupermuxRouteCandidateFetchSchedule: Equatable, Sendable {
    public enum Answer: Equatable, Sendable {
        case stored, empty, notReady, directOff, failed, unsupported

        public init(addresses: [String]) { self = .stored }
        public init(errorCode: String?) { self = .failed }
    }

    public init() {}
    public func isDue(at now: Date) -> Bool { true }
    public mutating func started(at now: Date) {}
    public mutating func finished(_ answer: Answer, at now: Date) {}
    public mutating func connected() {}
}

extension SupermuxRouteCandidates {
    public static let notReadyErrorCode = "not_ready"
    public static let directOffErrorCode = "direct_off"
}
