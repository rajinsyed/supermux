import Foundation
import SupermuxMobileKit
import Testing

@Suite struct SupermuxPhonePushWireTests {
    @Test func registrationUsesTheExactMacWideWireShape() {
        let request = SupermuxPhonePushRegistrationRequest(
            deviceID: "00000000-0000-0000-0000-000000000001",
            deviceToken: String(repeating: "ab", count: 32),
            previousDeviceToken: String(repeating: "cd", count: 32),
            bundleID: "com.supermux.ios",
            environment: .sandbox,
            enabled: true
        )

        #expect(request.wireMethod == "mobile.supermux.phone_push.register")
        #expect(request.wireParams["device_id"] as? String == "00000000-0000-0000-0000-000000000001")
        #expect(request.wireParams["device_token"] as? String == String(repeating: "ab", count: 32))
        #expect(request.wireParams["previous_device_token"] as? String == String(repeating: "cd", count: 32))
        #expect(request.wireParams["bundle_id"] as? String == "com.supermux.ios")
        #expect(request.wireParams["environment"] as? String == "sandbox")
        #expect(request.wireParams["enabled"] as? Bool == true)
    }

    @Test func responseDecodesTheMacAcknowledgement() throws {
        let response = try JSONDecoder().decode(
            SupermuxPhonePushRegistrationResponse.self,
            from: Data(#"{"registered":true}"#.utf8)
        )
        #expect(response.registered)
    }
}
