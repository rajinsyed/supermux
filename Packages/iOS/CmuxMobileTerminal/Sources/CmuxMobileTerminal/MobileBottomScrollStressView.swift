#if canImport(UIKit) && DEBUG
import SwiftUI

/// DEBUG repro harness for the bottom-scroll viewport-shrink bug.
public struct MobileBottomScrollStressView: View {
    // SUPERMUX:begin ios-terminal-native-scroll
    private let nativeScrollOnly: Bool

    /// Creates the bottom-scroll stress harness view.
    ///
    /// - Parameter nativeScrollOnly: Whether to stop after seeding bounded primary history.
    public init(nativeScrollOnly: Bool = false) {
        self.nativeScrollOnly = nativeScrollOnly
    }
    // SUPERMUX:end ios-terminal-native-scroll

    /// The mounted stress harness.
    public var body: some View {
        // SUPERMUX:begin ios-terminal-native-scroll
        MobileBottomScrollStressRepresentable(nativeScrollOnly: nativeScrollOnly)
        // SUPERMUX:end ios-terminal-native-scroll
            .ignoresSafeArea()
            .background(Color.black)
    }
}
#endif
