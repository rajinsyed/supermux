#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

struct MobileBottomScrollStressRepresentable: UIViewRepresentable {
    // SUPERMUX:begin ios-terminal-native-scroll
    let nativeScrollOnly: Bool

    func makeCoordinator() -> MobileBottomScrollStressCoordinator {
        MobileBottomScrollStressCoordinator(nativeScrollOnly: nativeScrollOnly)
    }
    // SUPERMUX:end ios-terminal-native-scroll

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.text = "BottomScrollStress: runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator, fontSize: 10)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
