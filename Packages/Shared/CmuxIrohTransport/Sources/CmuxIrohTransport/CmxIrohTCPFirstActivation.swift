/// Orders mobile-host transport startup so the required TCP listener is
/// available before optional Iroh policy and credential work is scheduled.
///
/// `scheduleIroh` must enqueue asynchronous activation and return immediately.
/// Keeping that boundary synchronous makes it impossible for a relay-policy or
/// Keychain suspension to delay the existing TCP listener.
// SUPERMUX:begin lint-allow-upstream-debt
// SUPERMUX:end lint-allow-upstream-debt (lint:allow namespace-type — upstream debt at the 0.64.20 merge; conventions gate runs only on the fork while upstream CI is paused)
public enum CmxIrohTCPFirstActivation {
    public static func start(
        startTCP: () -> Void,
        scheduleIroh: () -> Void
    ) {
        startTCP()
        scheduleIroh()
    }
}
