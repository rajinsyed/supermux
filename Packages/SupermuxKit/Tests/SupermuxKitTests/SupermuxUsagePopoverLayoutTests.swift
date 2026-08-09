#if canImport(AppKit)

import AppKit
import SwiftUI
import Testing
@testable import SupermuxKit

@MainActor
@Suite struct SupermuxUsagePopoverLayoutTests {
    @Test func compactContentKeepsItsIntrinsicHeight() {
        let fittingSize = fittingSize(rowCount: 2)

        #expect(fittingSize.width == SupermuxUsagePopoverView.popoverWidth)
        #expect(fittingSize.height > 0)
        #expect(fittingSize.height < SupermuxUsagePopoverView.maximumPopoverHeight)
    }

    @Test func expandedAccountContentCapsAtScrollableHeight() {
        let fittingSize = fittingSize(rowCount: 30)

        #expect(fittingSize.width == SupermuxUsagePopoverView.popoverWidth)
        #expect(abs(fittingSize.height - SupermuxUsagePopoverView.maximumPopoverHeight) < 0.5)
    }

    private func fittingSize(rowCount: Int) -> NSSize {
        let view = SupermuxUsagePopoverScrollContainer(
            width: SupermuxUsagePopoverView.popoverWidth,
            maximumHeight: SupermuxUsagePopoverView.maximumPopoverHeight
        ) {
            VStack(spacing: 3) {
                ForEach(0..<rowCount, id: \.self) { index in
                    Text("Account limit \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 21)
                }
            }
            .padding(12)
        }
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.layoutSubtreeIfNeeded()
        return hostingController.view.fittingSize
    }
}

#endif
