// SUPERMUX:begin runtime-cloud-route-catalog-regressions
import CmuxCloud
import CmuxCloudResizeCore
import CmuxSurfaceCatalogModel
import Testing

@Suite("Runtime cloud catalog-only resize admission")
struct RuntimeCloudRouteCatalogAdmissionTests {
    private let limits = CloudVMResizeLimits(
        maxVcpus: 8, maxMemoryMb: 16_384, maxDiskMb: 131_072,
        resourcePool: CloudVMResourcePool(poolVcpus: 8, poolMemoryMb: 16_384, usedVcpus: 8, usedMemoryMb: 16_384)
    )

    @Test("Paused and stopped catalog placeholders cannot bypass a full pool", arguments: ["paused", "stopped"])
    func inactivePlaceholder(status: String) {
        let row = placeholder(status: status)
        #expect(!row.usesResourcePool)
        #expect(row.resourceReservation == nil)
        let validator = CloudVMResizePlanValidator()
        let target = CloudVMResizeShape(diskMb: 32_768)
        // Catalog-only rows lack compute shape: the real menu must conservatively disable resizing.
        #expect(validator.violation(
            target: target, current: nil, usesResourcePool: row.usesResourcePool, limits: limits
        ) == .missingCurrentShape)
        // Even if shape becomes known, waking a stopped machine needs a new pool allocation.
        #expect(validator.violation(
            target: target, current: .init(vcpus: 2, memoryMb: 4_096, diskMb: 16_384),
            usesResourcePool: row.usesResourcePool, limits: limits
        ) == .poolLimit(requestedVcpus: 2, requestedMemoryMb: 4_096, freeVcpus: 0, freeMemoryMb: 0))
    }

    @Test("Running catalog placeholders keep disk-only resizing without fresh compute admission")
    func runningPlaceholder() {
        let row = placeholder(status: "running")
        #expect(row.usesResourcePool)
        #expect(CloudVMResizePlanValidator().violation(
            target: .init(diskMb: 32_768), current: nil,
            usesResourcePool: row.usesResourcePool, limits: limits
        ) == nil)
        #expect(row.label == "Display name")
        #expect(row.image == "snapshot")
        #expect(row.activity == .ready)
    }

    private func placeholder(status: String) -> MachineSnapshot {
        MachineSnapshotBuilder.catalogPlaceholder(id: "machine", info: SurfaceMachineInfo(
            id: .cloud("machine"), name: "Display name", status: status,
            image: "snapshot", hasDesktop: true, linkState: .connected
        ))
    }
}
// SUPERMUX:end runtime-cloud-route-catalog-regressions
