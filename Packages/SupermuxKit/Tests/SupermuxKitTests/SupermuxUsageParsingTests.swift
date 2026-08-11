import CmuxFoundation
import Foundation
// SupermuxUsageSeverity moved to the shared wire package so the iOS usage
// screen buckets percents identically.
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

@Suite
struct SupermuxCswapUsageParserTests {
    private let sample = Data("""
    {
      "schemaVersion": 1,
      "activeAccountNumber": 2,
      "accounts": [
        {
          "number": 2,
          "email": "active@example.com",
          "organizationName": "Real Name",
          "active": true,
          "usageStatus": "ok",
          "usage": {
            "fiveHour": {"pct": 29.0, "resetsAt": "2026-08-04T19:30:00.880114+00:00"},
            "sevenDay": {"pct": 24.0, "resetsAt": "2026-08-10T18:00:00.880145+00:00"},
            "scoped": [
              {"pct": 32.0, "resetsAt": "2026-08-10T18:00:00.880672+00:00", "name": "Fable"}
            ]
          },
          "usageFetchedAt": "2026-08-04T15:47:57Z"
        },
        {
          "number": 4,
          "email": "idle@example.com",
          "organizationName": "idle@example.com's Organization",
          "active": false,
          "usageStatus": "ok",
          "usage": {"fiveHour": {"pct": 0.0}, "sevenDay": {"pct": 0.0}, "scoped": []}
        },
        {
          "number": 5,
          "email": "broken@example.com",
          "active": false,
          "usageStatus": "unavailable",
          "usage": null,
          "lastGoodUsage": {"fiveHour": {"pct": 88.0}, "sevenDay": {"pct": 12.0}},
          "lastGoodFetchedAt": "2026-08-04T10:00:00Z"
        }
      ]
    }
    """.utf8)

    @Test func parsesAccountsWindowsAndActiveFirst() throws {
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: sample))
        #expect(snapshot.source == .cswap)
        #expect(snapshot.accounts.count == 3)

        let active = try #require(snapshot.activeAccount)
        #expect(active.email == "active@example.com")
        #expect(active.isActive)
        #expect(active.displayName == "Real Name")
        #expect(active.status == .ok)
        #expect(active.windows.count == 3)
        let session = try #require(active.windows.first { $0.kind == .session })
        #expect(session.percent == 29.0)
        #expect(session.resetsAt != nil)
        let scoped = try #require(active.windows.first { $0.kind == .scoped("Fable") })
        #expect(scoped.percent == 32.0)
        #expect(active.fetchedAt != nil)
    }

    @Test func derivedOrganizationNameIsNotUsedAsDisplayName() throws {
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: sample))
        let idle = try #require(snapshot.accounts.first { $0.email == "idle@example.com" })
        #expect(idle.displayName == nil)
    }

    @Test func unavailableAccountServesLastGoodWindows() throws {
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: sample))
        let broken = try #require(snapshot.accounts.first { $0.email == "broken@example.com" })
        #expect(broken.status == .unavailable(reason: "unavailable"))
        #expect(broken.windows.first { $0.kind == .session }?.percent == 88.0)
        #expect(broken.fetchedAt != nil)
    }

    @Test func rejectsNonSchemaPayload() {
        #expect(SupermuxCswapUsageParser.parse(jsonData: Data("not json".utf8)) == nil)
        #expect(SupermuxCswapUsageParser.parse(jsonData: Data("{\"foo\": 1}".utf8)) == nil)
    }

    @Test func parsesBothISODateShapes() {
        #expect(SupermuxCswapUsageParser.parseISODate("2026-08-04T19:30:00.880114+00:00") != nil)
        #expect(SupermuxCswapUsageParser.parseISODate("2026-08-04T15:47:57Z") != nil)
        #expect(SupermuxCswapUsageParser.parseISODate("not a date") == nil)
    }
}

@Suite
struct SupermuxCodexUsageParserTests {
    @Test func classifiesWindowsByLengthNotPosition() throws {
        // Binding-window collapse observed live: the WEEKLY window served as
        // primary_window with secondary null. Must classify as weekly.
        let collapsed = Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "primary_window": {"used_percent": 86, "limit_window_seconds": 604800, "reset_after_seconds": 309780, "reset_at": 1786168231},
            "secondary_window": null
          }
        }
        """.utf8)
        let snapshot = try #require(SupermuxCodexUsageParser.parseAPIResponse(jsonData: collapsed))
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        #expect(window.kind == .weekly)
        #expect(window.percent == 86)
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1786168231))
        #expect(snapshot.planType == "pro")
    }

    @Test func parsesScopedPoolsButHidesCodexSpark() throws {
        let full = Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {"used_percent": 6, "limit_window_seconds": 18000, "reset_at": 1786000000},
            "secondary_window": {"used_percent": 42, "limit_window_seconds": 604800, "reset_at": 1786449899}
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "primary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_at": 1786449899}
              }
            },
            {
              "limit_name": "Some-Future-Pool",
              "rate_limit": {
                "primary_window": {"used_percent": 55, "limit_window_seconds": 604800, "reset_at": 1786449899}
              }
            }
          ]
        }
        """.utf8)
        let snapshot = try #require(SupermuxCodexUsageParser.parseAPIResponse(jsonData: full))
        // Codex Spark is on the hidden list; other scoped pools still render.
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.windows.first { $0.kind == .session }?.percent == 6)
        #expect(snapshot.windows.first { $0.kind == .weekly }?.percent == 42)
        #expect(snapshot.windows.first { $0.kind == .scoped("Some-Future-Pool") }?.percent == 55)
        #expect(snapshot.windows.contains { $0.kind == .scoped("GPT-5.3-Codex-Spark") } == false)
    }

    @Test func rejectsPayloadWithoutWindows() {
        #expect(SupermuxCodexUsageParser.parseAPIResponse(jsonData: Data("{}".utf8)) == nil)
    }

    @Test func parsesNewestRateLimitsEventFromSessionLog() throws {
        let log = """
        {"timestamp":"2026-08-04T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1786000000},"secondary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1786168228},"plan_type":"pro"}}}
        {"timestamp":"2026-08-04T15:08:45.173Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":85.0,"window_minutes":10080,"resets_at":1786168228},"secondary":null,"plan_type":"pro"}}}
        """
        let snapshot = try #require(SupermuxCodexUsageParser.parseSessionLog(jsonlContent: log))
        #expect(snapshot.source == .sessionLog)
        // Newest event wins; its lone window is weekly (10080 minutes).
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.kind == .weekly)
        #expect(snapshot.windows.first?.percent == 85.0)
    }

    @Test func sessionLogWithoutRateLimitsYieldsNil() {
        let log = """
        {"timestamp":"2026-08-04T14:00:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}
        """
        #expect(SupermuxCodexUsageParser.parseSessionLog(jsonlContent: log) == nil)
    }
}

@Suite
struct SupermuxClaudeDirectUsageParsingTests {
    @Test func parsesDirectOAuthUsageShape() throws {
        let body = Data("""
        {
          "five_hour": {"utilization": 27.0, "resets_at": "2026-08-04T19:30:00.758765+00:00"},
          "seven_day": {"utilization": 23.0, "resets_at": "2026-08-10T18:00:00.758893+00:00"},
          "limits": [
            {"kind": "session", "percent": 27, "resets_at": "2026-08-04T19:30:00.758765+00:00"},
            {"kind": "weekly_all", "percent": 23, "resets_at": "2026-08-10T18:00:00.758893+00:00"},
            {"kind": "weekly_scoped", "percent": 32, "resets_at": "2026-08-10T18:00:00.759298+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
        """.utf8)
        let account = try #require(SupermuxClaudeUsageSource.parseDirectUsage(jsonData: body, email: "me@example.com"))
        #expect(account.email == "me@example.com")
        #expect(account.isActive)
        #expect(account.windows.count == 3)
        #expect(account.windows.first { $0.kind == .session }?.percent == 27.0)
        #expect(account.windows.first { $0.kind == .weekly }?.percent == 23.0)
        #expect(account.windows.first { $0.kind == .scoped("Fable") }?.percent == 32)
    }

    @Test func rejectsEmptyUsageBody() {
        #expect(SupermuxClaudeUsageSource.parseDirectUsage(jsonData: Data("{}".utf8), email: "") == nil)
    }
}

@Suite
struct SupermuxUsageWindowTests {
    @Test func severityBuckets() {
        #expect(SupermuxUsageSeverity(percent: 0) == .normal)
        #expect(SupermuxUsageSeverity(percent: 69.9) == .normal)
        #expect(SupermuxUsageSeverity(percent: 70) == .warning)
        #expect(SupermuxUsageSeverity(percent: 89.9) == .warning)
        #expect(SupermuxUsageSeverity(percent: 90) == .critical)
        #expect(SupermuxUsageSeverity(percent: 120) == .critical)
    }

    @Test func tightestPicksHighestPercent() {
        let windows = [
            SupermuxUsageWindow(kind: .session, percent: 29, resetsAt: nil),
            SupermuxUsageWindow(kind: .weekly, percent: 24, resetsAt: nil),
            SupermuxUsageWindow(kind: .scoped("Fable"), percent: 32, resetsAt: nil),
        ]
        #expect(windows.tightest?.kind == .scoped("Fable"))
    }

    @Test func displayOrderIsSessionWeeklyScoped() {
        let windows = [
            SupermuxUsageWindow(kind: .scoped("Fable"), percent: 32, resetsAt: nil),
            SupermuxUsageWindow(kind: .weekly, percent: 24, resetsAt: nil),
            SupermuxUsageWindow(kind: .session, percent: 29, resetsAt: nil),
        ]
        let sorted = windows.sortedForDisplay()
        #expect(sorted.map(\.kind) == [.session, .weekly, .scoped("Fable")])
    }
}

@Suite
struct SupermuxCodexJWTTests {
    @Test func decodesExpiryFromUnsignedJWT() throws {
        // Header/payload base64url with a known exp; signature irrelevant.
        func b64url(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let jwt = "\(b64url("{\"alg\":\"none\"}")).\(b64url("{\"exp\":1786000000}")).sig"
        let expiry = try #require(SupermuxCodexUsageSource.jwtExpiry(jwt))
        #expect(expiry == Date(timeIntervalSince1970: 1786000000))
    }

    @Test func malformedJWTYieldsNil() {
        #expect(SupermuxCodexUsageSource.jwtExpiry("garbage") == nil)
        #expect(SupermuxCodexUsageSource.jwtExpiry("a.b.c") == nil)
    }
}

@Suite
@MainActor
struct SupermuxUsageModelMergeTests {
    @Test func failureNeverReplacesReadyData() {
        let ready = SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>.ready(
            SupermuxCodexUsageSnapshot(source: .api, planType: "pro", windows: [], fetchedAt: Date())
        )
        let merged = SupermuxUsageModel.merging(current: ready, incoming: .failed(message: "boom"))
        #expect(merged == ready)
    }

    @Test func freshDataReplacesEverything() {
        let old = SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>.failed(message: "old")
        let fresh = SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>.ready(
            SupermuxCodexUsageSnapshot(source: .api, planType: "pro", windows: [], fetchedAt: Date())
        )
        #expect(SupermuxUsageModel.merging(current: old, incoming: fresh) == fresh)
        #expect(SupermuxUsageModel.merging(current: fresh, incoming: .notConfigured) == .notConfigured)
    }
}

@Suite
@MainActor
struct SupermuxUsageModelThrottleTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Sol review finding 2: every refresh entry point must honor the floor —
    /// hammering refresh() (popover opens, refresh button) may trigger at
    /// most one provider fetch per minimumRefreshInterval.
    @Test func repeatedRefreshCallsCoalesceUnderTheFloor() async {
        let calls = Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                calls.increment()
                return .notConfigured
            },
            codexFetch: { .notConfigured },
            minimumRefreshInterval: 3600
        )
        for _ in 0..<10 {
            await model.refresh()
        }
        #expect(calls.count == 1)
    }

    /// Freshness honesty (sol finding 3): the displayed age comes from the
    /// snapshots' own fetchedAt, and a failed pass that keeps last-good data
    /// must not advance it.
    @Test func displayedAgeTracksSnapshotNotPassCompletion() async {
        let measured = Date(timeIntervalSinceNow: -3600)
        let snapshot = SupermuxCodexUsageSnapshot(source: .api, planType: "pro", windows: [], fetchedAt: measured)
        let model = SupermuxUsageModel(
            claudeFetch: { .notConfigured },
            codexFetch: { .ready(snapshot) },
            minimumRefreshInterval: 0
        )
        await model.refresh()
        #expect(model.oldestDisplayedDataAge == measured)
    }
}

@Suite
struct SupermuxClaudeCswapFallthroughTests {
    private struct ScriptedRunner: CommandRunning {
        let result: CommandResult
        func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
            result
        }
    }

    /// Sol review finding 1: CommandRunner launches unresolved binaries via
    /// /usr/bin/env, which exits 127 — that must fall through to the direct
    /// path (surfacing .notConfigured here, with no credentials in the fake
    /// home), NOT report a cswap failure.
    @Test func envExit127FallsThroughToDirectPath() async {
        let runner = ScriptedRunner(result: CommandResult(
            stdout: "", stderr: "env: cswap: No such file or directory",
            exitStatus: 127, timedOut: false, executionError: nil
        ))
        let source = SupermuxClaudeUsageSource(
            runner: runner,
            homeDirectory: URL(fileURLWithPath: "/nonexistent-supermux-test-home")
        )
        let state = await source.fetch()
        #expect(state == .notConfigured)
    }

    /// A real cswap failure (installed, but errored) must NOT silently fall
    /// through — it surfaces as failed so the user sees cswap's problem.
    @Test func realCswapFailureSurfacesAsFailed() async {
        let runner = ScriptedRunner(result: CommandResult(
            stdout: "", stderr: "cswap: config corrupted",
            exitStatus: 1, timedOut: false, executionError: nil
        ))
        let source = SupermuxClaudeUsageSource(
            runner: runner,
            homeDirectory: URL(fileURLWithPath: "/nonexistent-supermux-test-home")
        )
        let state = await source.fetch()
        #expect(state == .failed(message: "cswap: config corrupted"))
    }

    @Test func cswapSuccessParsesWithoutTouchingDirectPath() async {
        let json = """
        {"schemaVersion":1,"accounts":[{"number":1,"email":"a@b.c","active":true,"usageStatus":"ok",
        "usage":{"fiveHour":{"pct":10.0},"sevenDay":{"pct":5.0}}}]}
        """
        let runner = ScriptedRunner(result: CommandResult(
            stdout: json, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil
        ))
        let source = SupermuxClaudeUsageSource(
            runner: runner,
            homeDirectory: URL(fileURLWithPath: "/nonexistent-supermux-test-home")
        )
        let state = await source.fetch()
        let snapshot = try? #require(state.snapshot)
        #expect(snapshot?.source == .cswap)
        #expect(snapshot?.activeAccount?.email == "a@b.c")
    }
}


@Suite
struct SupermuxCswapSwitchResultTests {
    @Test func parsesSwitchedEnvelope() {
        let json = Data("""
        {"schemaVersion":1,"switched":true,"from":{"number":2,"email":"a@b.c"},
         "to":{"number":4,"email":"d@e.f"},"strategy":null,"reason":"switched",
         "message":"Switched to Account-4 (d@e.f)","warnings":[]}
        """.utf8)
        #expect(SupermuxCswapSwitchResult.parse(jsonData: json) == .switched(toEmail: "d@e.f"))
    }

    @Test func parsesAlreadyActiveEnvelope() {
        let json = Data("""
        {"schemaVersion":1,"switched":false,"from":{"number":2,"email":"a@b.c"},
         "to":{"number":2,"email":"a@b.c"},"reason":"already-active",
         "message":"Already on Account-2 (a@b.c)","warnings":[]}
        """.utf8)
        #expect(SupermuxCswapSwitchResult.parse(jsonData: json) == .alreadyActive(email: "a@b.c"))
    }

    @Test func parsesErrorEnvelope() {
        let json = Data("""
        {"schemaVersion":1,"error":{"type":"SwitchError","message":"Account-9 has no stored credentials."}}
        """.utf8)
        #expect(SupermuxCswapSwitchResult.parse(jsonData: json)
            == .failed(message: "Account-9 has no stored credentials."))
    }

    @Test func notSwitchedForOtherReasonSurfacesMessage() {
        let json = Data("""
        {"schemaVersion":1,"switched":false,"to":{"number":3,"email":"x@y.z"},
         "reason":"rate-limited","message":"Target is rate limited","warnings":[]}
        """.utf8)
        #expect(SupermuxCswapSwitchResult.parse(jsonData: json)
            == .failed(message: "Target is rate limited"))
    }

    @Test func garbageYieldsNil() {
        #expect(SupermuxCswapSwitchResult.parse(jsonData: Data("nope".utf8)) == nil)
        #expect(SupermuxCswapSwitchResult.parse(jsonData: Data("{}".utf8)) == nil)
    }
}

@Suite
@MainActor
struct SupermuxUsageModelBestAndEnableTests {
    @Test func switchToBestRefreshesOnSuccess() async {
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                return .notConfigured
            },
            codexFetch: { .notConfigured },
            claudeSwitchBest: { .switched(toEmail: "best@example.com") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        await model.switchClaudeToBest()
        #expect(fetches.count == 2)
        #expect(model.lastSwitchError == nil)
        #expect(model.isSwitchingToBest == false)
    }

    @Test func setEnabledFailureSurfacesError() async {
        let model = SupermuxUsageModel(
            claudeFetch: { .notConfigured },
            codexFetch: { .notConfigured },
            claudeSetEnabled: { _, _ in .failed(message: "unknown account") },
            minimumRefreshInterval: 3600
        )
        await model.setClaudeAccountEnabled(false, slot: 3)
        #expect(model.lastSwitchError == "unknown account")
    }
}

@Suite
struct SupermuxCswapPaceParsingTests {
    @Test func weeklyPaceFieldsCarryThrough() throws {
        let json = Data("""
        {"schemaVersion":1,"accounts":[{"number":1,"email":"a@b.c","active":true,"usageStatus":"ok",
          "usage":{
            "fiveHour":{"pct":10.0},
            "sevenDay":{"pct":80.0,"aheadOfPace":true,"expectedPct":40.0},
            "scoped":[{"pct":20.0,"name":"Fable","aheadOfPace":false}]
          }}]}
        """.utf8)
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: json))
        let account = try #require(snapshot.activeAccount)
        #expect(account.windows.first { $0.kind == .weekly }?.aheadOfPace == true)
        #expect(account.windows.first { $0.kind == .scoped("Fable") }?.aheadOfPace == false)
        // 5h windows never carry pace.
        #expect(account.windows.first { $0.kind == .session }?.aheadOfPace == nil)
    }
}

@Suite
@MainActor
struct SupermuxUsageModelSwitchTests {
    @Test func successfulSwitchRefreshesBypassingFloor() async {
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                return .notConfigured
            },
            codexFetch: { .notConfigured },
            claudeSwitch: { _ in .switched(toEmail: "d@e.f") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        #expect(fetches.count == 1)
        // The hour-long floor would normally block this second pass; a
        // completed switch must force it through.
        await model.switchClaudeAccount(toSlot: 4)
        #expect(fetches.count == 2)
        #expect(model.lastSwitchError == nil)
        #expect(model.switchingToSlot == nil)
    }

    @Test func failedSwitchSurfacesErrorWithoutRefreshing() async {
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                return .notConfigured
            },
            codexFetch: { .notConfigured },
            claudeSwitch: { _ in .failed(message: "no stored credentials") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        await model.switchClaudeAccount(toSlot: 9)
        #expect(fetches.count == 1)
        #expect(model.lastSwitchError == "no stored credentials")
        model.dismissSwitchError()
        #expect(model.lastSwitchError == nil)
    }
}

@Suite
struct SupermuxClaudeAccountIdentityTests {
    /// Sol review finding 6: two malformed rows without emails must not
    /// collide on the same SwiftUI identity.
    @Test func malformedAccountsKeepDistinctIdentities() throws {
        let json = Data("""
        {"schemaVersion":1,"accounts":[
          {"number":1,"active":false,"usageStatus":"unavailable"},
          {"number":2,"active":false,"usageStatus":"unavailable"}
        ]}
        """.utf8)
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: json))
        let ids = Set(snapshot.accounts.map(\.id))
        #expect(ids.count == 2)
    }
}

@Suite
struct SupermuxUsageReviewRegressionTests {
    /// A malformed account row (wrong-typed field) degrades to a stub instead
    /// of discarding every other account.
    @Test func malformedCswapRowDoesNotDropTheSnapshot() throws {
        let json = Data("""
        {"schemaVersion":1,"accounts":[
          {"number":1,"email":"good@example.com","active":true,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":10.0}}},
          {"number":"not-a-number","email":42}
        ]}
        """.utf8)
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: json))
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.activeAccount?.email == "good@example.com")
        let stub = try #require(snapshot.accounts.first { $0.email.isEmpty })
        #expect(stub.status == .unavailable(reason: nil))
    }

    /// Future schema majors must not be silently rendered as v1.
    @Test func rejectsFutureCswapSchemaVersion() {
        let json = Data("""
        {"schemaVersion":2,"accounts":[{"number":1,"email":"a@b.c","active":true,
         "usage":{"fiveHour":{"pct":10.0}}}]}
        """.utf8)
        #expect(SupermuxCswapUsageParser.parse(jsonData: json) == nil)
    }

    /// Rows with neither slot nor email keep distinct identities via ordinal.
    @Test func slotlessEmaillessRowsKeepDistinctIdentities() throws {
        let json = Data("""
        {"schemaVersion":1,"accounts":[
          {"active":false,"usageStatus":"unavailable"},
          {"active":false,"usageStatus":"unavailable"}
        ]}
        """.utf8)
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: json))
        #expect(Set(snapshot.accounts.map(\.id)).count == 2)
    }

    /// A missing percentage is "unknown", never 0%.
    @Test func missingPercentDropsTheWindowInsteadOfZero() throws {
        let json = Data("""
        {"schemaVersion":1,"accounts":[{"number":1,"email":"a@b.c","active":true,"usageStatus":"ok",
          "usage":{"fiveHour":{"resetsAt":"2026-08-04T19:30:00Z"},"sevenDay":{"pct":40.0}}}]}
        """.utf8)
        let snapshot = try #require(SupermuxCswapUsageParser.parse(jsonData: json))
        let account = try #require(snapshot.activeAccount)
        #expect(account.windows.count == 1)
        #expect(account.windows.first?.kind == .weekly)
    }

    /// A credits-only newest rate_limits event must not hide an older usable
    /// snapshot further up the session log.
    @Test func sessionLogScanSkipsCreditsOnlyEvents() throws {
        let log = """
        {"timestamp":"2026-08-04T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":33.0,"window_minutes":300,"resets_at":1786000000},"plan_type":"pro"}}}
        {"timestamp":"2026-08-04T15:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"credits":{"balance":12}}}}
        """
        let snapshot = try #require(SupermuxCodexUsageParser.parseSessionLog(jsonlContent: log))
        #expect(snapshot.windows.first?.percent == 33.0)
    }

    /// One malformed scoped limits[] row must not discard valid base windows
    /// in the direct OAuth payload.
    @Test func malformedScopedLimitKeepsDirectBaseWindows() throws {
        let body = Data("""
        {
          "five_hour": {"utilization": 27.0, "resets_at": "2026-08-04T19:30:00Z"},
          "seven_day": {"utilization": 23.0, "resets_at": "2026-08-10T18:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "percent": "not-a-number",
             "scope": {"model": {"display_name": "Broken"}}}
          ]
        }
        """.utf8)
        let account = try #require(SupermuxClaudeUsageSource.parseDirectUsage(jsonData: body, email: "x@y.z"))
        #expect(account.windows.count == 2)
    }

    @Test func percentNormalization() {
        #expect(SupermuxUsagePercent.normalized(nil) == nil)
        #expect(SupermuxUsagePercent.normalized(-1) == nil)
        #expect(SupermuxUsagePercent.normalized(0) == 0)
        #expect(SupermuxUsagePercent.normalized(150) == 100)
    }
}

@Suite
@MainActor
struct SupermuxUsageModelConcurrencyRegressionTests {
    /// A switch completing while a poll pass is in flight must still deliver
    /// the post-switch refresh, and the in-flight pass's pre-switch snapshot
    /// must not be published over the post-switch one.
    @Test func switchDuringInFlightPassStillRefreshes() async {
        let gate = AsyncGate()
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let preSwitch = SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 2, email: "old@example.com", displayName: nil,
                isActive: true, status: .ok, windows: [], fetchedAt: nil
            )],
            fetchedAt: Date(timeIntervalSinceNow: -10)
        )
        let postSwitch = SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 4, email: "new@example.com", displayName: nil,
                isActive: true, status: .ok, windows: [], fetchedAt: nil
            )],
            fetchedAt: Date()
        )
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                if fetches.count == 1 {
                    // First (pre-switch) pass: block until the switch is done.
                    await gate.wait()
                    return .ready(preSwitch)
                }
                return .ready(postSwitch)
            },
            codexFetch: { .notConfigured },
            claudeSwitch: { _ in .switched(toEmail: "new@example.com") },
            minimumRefreshInterval: 3600
        )
        // Start the pass; it suspends inside claudeFetch.
        let pass = Task { await model.refresh() }
        // Let the pass actually start before switching.
        while fetches.count == 0 { await Task.yield() }
        let switchTask = Task { await model.switchClaudeAccount(toSlot: 4) }
        _ = await switchTask.value
        await gate.open()
        _ = await pass.value
        // The queued forced follow-up runs inside the original pass.
        while model.isRefreshing { await Task.yield() }
        #expect(fetches.count == 2)
        #expect(model.claude.snapshot?.activeAccount?.email == "new@example.com")
    }

    /// An incoming ready snapshot older than the displayed one (degraded
    /// session-log fallback) must not replace it.
    @Test func olderReadySnapshotNeverReplacesNewer() {
        let newer = SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>.ready(
            SupermuxCodexUsageSnapshot(source: .api, planType: "pro", windows: [], fetchedAt: Date())
        )
        let older = SupermuxUsageProviderState<SupermuxCodexUsageSnapshot>.ready(
            SupermuxCodexUsageSnapshot(
                source: .sessionLog, planType: "pro", windows: [],
                fetchedAt: Date(timeIntervalSinceNow: -86400)
            )
        )
        #expect(SupermuxUsageModel.merging(current: newer, incoming: older) == newer)
        #expect(SupermuxUsageModel.merging(current: older, incoming: newer) == newer)
    }

    /// A degraded cswap pass carrying only cached lastGoodUsage parses "now"
    /// but MEASURED old; it must not overwrite fresher displayed data.
    @Test func staleCswapLastGoodNeverReplacesNewerMeasurement() {
        func claudeState(measured: Date, parsed: Date) -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
            .ready(SupermuxClaudeUsageSnapshot(
                source: .cswap,
                accounts: [SupermuxClaudeAccountUsage(
                    slot: 1, email: "a@b.c", displayName: nil, isActive: true,
                    status: .unavailable(reason: nil), windows: [], fetchedAt: measured
                )],
                fetchedAt: parsed
            ))
        }
        let now = Date()
        let fresh = claudeState(measured: now.addingTimeInterval(-60), parsed: now.addingTimeInterval(-60))
        // Parsed just now, but the accounts' data is a day old.
        let staleLastGood = claudeState(measured: now.addingTimeInterval(-86400), parsed: now)
        #expect(SupermuxUsageModel.merging(current: fresh, incoming: staleLastGood) == fresh)
        #expect(SupermuxUsageModel.merging(current: staleLastGood, incoming: fresh) == fresh)
    }

    /// The throttled outcome is reported so the UI can acknowledge the click.
    @Test func throttledRefreshReportsOutcome() async {
        let model = SupermuxUsageModel(
            claudeFetch: { .notConfigured },
            codexFetch: { .notConfigured },
            minimumRefreshInterval: 3600
        )
        #expect(await model.refresh() == .refreshed)
        #expect(await model.refresh() == .throttled)
    }

    actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}

@Suite
@MainActor
struct SupermuxUsageSwitchStalenessGateTests {
    private nonisolated static func claudeState(
        email: String, measured: Date
    ) -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        .ready(SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 1, email: email, displayName: nil, isActive: true,
                status: .ok, windows: [], fetchedAt: measured
            )],
            fetchedAt: Date()
        ))
    }

    /// Switching to an account whose cswap cache is OLDER than the previous
    /// account's must still show the switched-to account: the mutation-driven
    /// pass bypasses the cross-account staleness gate.
    @Test func switchToAccountWithOlderCacheStillLandsOnScreen() async {
        let now = Date()
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                // Pass 1: currently-active account, freshly measured.
                // Pass 2 (post-switch): new active account, older cache.
                return fetches.count == 1
                    ? Self.claudeState(email: "fresh@example.com", measured: now)
                    : Self.claudeState(email: "older-cache@example.com", measured: now.addingTimeInterval(-3600))
            },
            codexFetch: { .notConfigured },
            claudeSwitch: { _ in .switched(toEmail: "older-cache@example.com") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        #expect(model.claude.snapshot?.activeAccount?.email == "fresh@example.com")
        await model.switchClaudeAccount(toSlot: 2)
        #expect(model.claude.snapshot?.activeAccount?.email == "older-cache@example.com")
    }
}

@Suite
@MainActor
struct SupermuxUsageEnableToggleStalenessTests {
    private nonisolated static func claudeState(
        activeEmail: String, measured: Date
    ) -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        .ready(SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 1, email: activeEmail, displayName: nil, isActive: true,
                status: .ok, windows: [], fetchedAt: measured
            )],
            fetchedAt: Date()
        ))
    }

    /// Enable/disable toggles do NOT change the active account, so the
    /// post-toggle pass must keep honoring the staleness gate: a pass that
    /// comes back with an OLDER measurement for the SAME active account must
    /// not overwrite the fresher one on display.
    @Test func enableToggleDoesNotBypassStalenessGate() async {
        let now = Date()
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                // Pass 2 (post-toggle) serves an older cached measurement.
                return fetches.count == 1
                    ? Self.claudeState(activeEmail: "same@example.com", measured: now)
                    : Self.claudeState(activeEmail: "same@example.com", measured: now.addingTimeInterval(-3600))
            },
            codexFetch: { .notConfigured },
            claudeSetEnabled: { _, _ in .switched(toEmail: "") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        await model.setClaudeAccountEnabled(false, slot: 3)
        #expect(fetches.count == 2)
        // The stale post-toggle snapshot must not replace the fresh one.
        let shown = model.claude.snapshot?.activeAccount
        #expect(shown?.fetchedAt == now)
    }
}

@Suite
@MainActor
struct SupermuxUsageNoOpSwitchStalenessTests {
    private nonisolated static func claudeState(
        measured: Date
    ) -> SupermuxUsageProviderState<SupermuxClaudeUsageSnapshot> {
        .ready(SupermuxClaudeUsageSnapshot(
            source: .cswap,
            accounts: [SupermuxClaudeAccountUsage(
                slot: 1, email: "same@example.com", displayName: nil, isActive: true,
                status: .ok, windows: [], fetchedAt: measured
            )],
            fetchedAt: Date()
        ))
    }

    /// A no-op switch (.alreadyActive) leaves the active account unchanged,
    /// so the forced refresh must keep the staleness gate: an older cached
    /// snapshot must not regress the gauge.
    @Test func alreadyActiveSwitchKeepsStalenessGate() async {
        let now = Date()
        let fetches = SupermuxUsageModelThrottleTests.Counter()
        let model = SupermuxUsageModel(
            claudeFetch: {
                fetches.increment()
                return fetches.count == 1
                    ? Self.claudeState(measured: now)
                    : Self.claudeState(measured: now.addingTimeInterval(-3600))
            },
            codexFetch: { .notConfigured },
            claudeSwitch: { _ in .alreadyActive(email: "same@example.com") },
            minimumRefreshInterval: 3600
        )
        await model.refresh()
        await model.switchClaudeAccount(toSlot: 1)
        #expect(fetches.count == 2)
        #expect(model.claude.snapshot?.activeAccount?.fetchedAt == now)
    }
}
