struct ArrowlessPopoverRootViewUpdatePolicy {
    enum Strategy {
        case none
        // SUPERMUX:begin popover-dynamic-height-reanchor
        case deferredPresentation
        // SUPERMUX:end popover-dynamic-height-reanchor
        case deferredVisible
    }

    static func rootViewUpdateStrategy(isPresented: Bool, popoverIsShown: Bool) -> Strategy {
        // SUPERMUX:begin popover-dynamic-height-reanchor
        guard isPresented else { return .none }
        if popoverIsShown { return .deferredVisible }
        return .deferredPresentation
        // SUPERMUX:end popover-dynamic-height-reanchor
    }
}
