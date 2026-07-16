/// SupermuxMobileKit is the iOS-side domain layer for supermux feature
/// parity: the ``SupermuxMacCalling`` seam (typed `mobile.supermux.*`
/// request/response plus event streams), its production
/// ``SupermuxMacClient`` adapter over `CmuxMobileRPC`, the capability gate
/// ``SupermuxMobileCapabilities``, the etag-keyed
/// ``SupermuxProjectIconCache``, and the observable phone stores
/// (``SupermuxMobileProjectsStore``). No SwiftUI — screens live in
/// SupermuxMobileUI and observe these stores.
