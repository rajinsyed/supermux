// SUPERMUX:begin runtime-auth-token-lifetime-regressions
import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

@Suite struct RuntimeAuthAccessTokenLifetimeTests {
    private static let extremeClaims = [
        #"{"exp":1e300}"#,
        #"{"exp":-1e300}"#,
        #"{"exp":9223372036854775808}"#,
        #"{"exp":-9223372036854777856}"#,
    ]
    private static let invalidIssuedAtClaims = [
        #"{"exp":600,"iat":-1e300}"#,
        #"{"exp":600,"iat":1e300}"#,
        #"{"exp":600,"iat":"yesterday"}"#,
    ]

    @Test(arguments: extremeClaims)
    func extremeExpiryOmitsDiagnostics(claims: String) {
        let token = Self.token(claims)
        #expect(AccessTokenLifetime(token, now: Date(timeIntervalSince1970: 0)) == nil)
        #expect(AccessTokenLifetime.logFields(token) == "accessExpiresInSec=nil")
    }

    @Test(arguments: invalidIssuedAtClaims)
    func invalidIssuedAtOmitsOnlyLifetime(claims: String) throws {
        let facts = try #require(AccessTokenLifetime(Self.token(claims), now: Date(timeIntervalSince1970: 0)))
        #expect(facts.expiresInSeconds == 600)
        #expect(facts.lifetimeSeconds == nil)
    }

    @Test func fractionalAndExpiredClaimsKeepTruncationSemantics() throws {
        let token = Self.token(#"{"exp":10.75,"iat":1.25}"#)
        let facts = try #require(AccessTokenLifetime(token, now: Date(timeIntervalSince1970: 12)))
        #expect(facts.expiresInSeconds == -1)
        #expect(facts.lifetimeSeconds == 9)
    }

    @Test func representableIntegerBoundariesRemainValid() throws {
        let lower = try #require(AccessTokenLifetime(Self.token(#"{"exp":-9223372036854775808}"#), now: Date(timeIntervalSince1970: 0)))
        let upper = try #require(AccessTokenLifetime(Self.token(#"{"exp":9223372036854774784}"#), now: Date(timeIntervalSince1970: 0)))
        #expect(lower.expiresInSeconds == Int.min)
        #expect(upper.expiresInSeconds == Int.max - 1023)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, -Double.greatestFiniteMagnitude])
    func invalidClockOrOverflowingExpiryDeltaOmitsDiagnostics(now: Double) {
        #expect(AccessTokenLifetime(Self.token(#"{"exp":1e308}"#), now: Date(timeIntervalSince1970: now)) == nil)
    }

    @Test func overflowingIssuedLifetimeOmitsOnlyLifetime() throws {
        let facts = try #require(AccessTokenLifetime(
            Self.token(#"{"exp":1e308,"iat":-1e308}"#),
            now: Date(timeIntervalSince1970: 1e308)
        ))
        #expect(facts.expiresInSeconds == 0)
        #expect(facts.lifetimeSeconds == nil)
    }

    @Test(arguments: [#"{"exp":"tomorrow"}"#, #"{"iat":0}"#, #"{"exp":null}"#])
    func missingOrNonNumericExpiryOmitsDiagnostics(claims: String) {
        #expect(AccessTokenLifetime(Self.token(claims)) == nil)
    }

    @Test(arguments: extremeClaims + invalidIssuedAtClaims)
    func fileCompareAndSetPersistsTokensDespiteInvalidDiagnostics(claims: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeAuthLifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileStackTokenStore(directory: directory)
        await store.setTokens(accessToken: "old-access", refreshToken: "old-refresh")
        let token = Self.token(claims)

        await store.compareAndSet(
            compareRefreshToken: "old-refresh",
            newRefreshToken: "new-refresh",
            newAccessToken: token
        )

        #expect(await store.getStoredAccessToken() == token)
        #expect(await store.getStoredRefreshToken() == "new-refresh")
        let reopened = FileStackTokenStore(directory: directory)
        #expect(await reopened.getStoredAccessToken() == token)
        #expect(await reopened.getStoredRefreshToken() == "new-refresh")

        await store.compareAndSet(
            compareRefreshToken: "old-refresh",
            newRefreshToken: "stale-refresh",
            newAccessToken: "stale-access"
        )
        #expect(await store.getStoredAccessToken() == token)
        #expect(await store.getStoredRefreshToken() == "new-refresh")
    }

    #if canImport(Security)
    @Test(arguments: extremeClaims + invalidIssuedAtClaims)
    func keychainCompareAndSetPersistsTokensDespiteInvalidDiagnostics(claims: String) async throws {
        let service = "com.supermux.tests.RuntimeAuthLifetime.\(UUID().uuidString)"
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        let store = KeychainStackTokenStore(service: service)
        await store.setTokens(accessToken: "old-access", refreshToken: "old-refresh")
        try #require(await store.getStoredRefreshToken() == "old-refresh")
        let token = Self.token(claims)

        await store.compareAndSet(
            compareRefreshToken: "old-refresh",
            newRefreshToken: "new-refresh",
            newAccessToken: token
        )

        #expect(await store.getStoredAccessToken() == token)
        #expect(await store.getStoredRefreshToken() == "new-refresh")
        await store.clearTokens()
        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
    }
    #endif

    private static func token(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
}
// SUPERMUX:end runtime-auth-token-lifetime-regressions
