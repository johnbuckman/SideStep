// Tests for ReauthGate: which unattended re-login failures pause automatic sign-in until the
// user signs in again, which only back off, and that the state survives across launches.
// No device, no network, no Apple servers involved.

import XCTest
import AltSign
@testable import SideloaderKit

final class ReauthGateTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName = ""
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "sidestep.tests.reauthgate.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        ReauthGate.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        ReauthGate.defaults = .standard
        super.tearDown()
    }

    /// A fresh Apple ID per test, because the in-flight set is process-wide.
    private func freshID() -> String { "test-\(UUID().uuidString)@example.com" }

    private func isBlocked(_ v: ReauthGate.Verdict) -> Bool {
        if case .blocked = v { return true }
        return false
    }

    private func fail(_ id: String, _ error: Error, at date: Date) {
        XCTAssertEqual(ReauthGate.begin(id, now: date), .allowed, "attempt should be allowed before failing it")
        ReauthGate.finish(id, error: error, now: date)
    }

    // MARK: classification

    func testTwoFactorRequiredPausesUntilSignIn() {
        XCTAssertNotNil(ReauthGate.needsUser(ALTAppleAPIError.requiresTwoFactorAuthentication))
    }

    func testTwoFactorRequiredAsNSErrorPausesUntilSignIn() {
        let ns = NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.requiresTwoFactorAuthentication.rawValue)
        XCTAssertNotNil(ReauthGate.needsUser(ns))
    }

    func testLockedAccountPausesUntilSignIn() {
        XCTAssertNotNil(ReauthGate.needsUser(NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: -20209)))
    }

    func testRejectedCredentialsPauseUntilSignIn() {
        XCTAssertNotNil(ReauthGate.needsUser(ALTAppleAPIError.incorrectCredentials))
        for code in [-20101, -20970, -22406] {
            XCTAssertNotNil(ReauthGate.needsUser(NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: code)), "code \(code)")
        }
    }

    func testTwoFactorAskedAgainPausesUntilSignIn() {
        XCTAssertNotNil(ReauthGate.needsUser(NSError(domain: ALTAppleAPI.twoFactorAskedAgainErrorDomain, code: 1)))
    }

    func testTransientErrorsOnlyBackOff() {
        XCTAssertNil(ReauthGate.needsUser(URLError(.notConnectedToInternet)))
        XCTAssertNil(ReauthGate.needsUser(NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: -36607)))
        XCTAssertNil(ReauthGate.needsUser(ALTAppleAPIError.invalidAnisetteData))
    }

    // MARK: attempts

    func testFirstAttemptIsAllowedAndSuccessClearsState() {
        let id = freshID()
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
        XCTAssertNil(suite.data(forKey: "sidestep.reauthGate"), "success should leave no stored state")
    }

    func testOnlyOneAttemptAtATime() {
        let id = freshID()
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: t0)), "a second concurrent attempt must be refused")
        ReauthGate.finish(id, error: nil, now: t0)
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
    }

    func testCheckReservesNothing() {
        let id = freshID()
        XCTAssertEqual(ReauthGate.check(id, now: t0), .allowed)
        XCTAssertEqual(ReauthGate.check(id, now: t0), .allowed, "check must not mark an attempt as running")
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
    }

    func testCheckReportsPauseAndRunningAttempt() {
        let paused = freshID(), running = freshID()
        fail(paused, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        XCTAssertTrue(isBlocked(ReauthGate.check(paused, now: t0)))
        XCTAssertEqual(ReauthGate.begin(running, now: t0), .allowed)
        XCTAssertTrue(isBlocked(ReauthGate.check(running, now: t0)))
        ReauthGate.finish(running, error: nil, now: t0)
        XCTAssertEqual(ReauthGate.check(running, now: t0), .allowed)
    }

    func testOtherAppleIDsAreNotAffected() {
        let a = freshID(), b = freshID()
        fail(a, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        XCTAssertTrue(isBlocked(ReauthGate.begin(a, now: t0)))
        XCTAssertEqual(ReauthGate.begin(b, now: t0), .allowed)
        ReauthGate.finish(b, error: nil, now: t0)
    }

    func testTwoFactorPauseDoesNotExpire() {
        let id = freshID()
        fail(id, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: t0.addingTimeInterval(60))))
        XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: t0.addingTimeInterval(30 * 86400))), "must stay paused until sign-in")
    }

    func testClearEndsPause() {
        let id = freshID()
        fail(id, NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: -20209), at: t0)
        XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: t0)))
        ReauthGate.clear(id)
        XCTAssertEqual(ReauthGate.begin(id, now: t0), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
    }

    func testBackoffDoublesUpToCap() {
        let id = freshID()
        let err = URLError(.timedOut)
        var now = t0
        var expected = ReauthGate.baseDelay
        for _ in 0..<8 {
            fail(id, err, at: now)
            XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: now.addingTimeInterval(expected - 1))), "still waiting just before \(expected)s")
            now = now.addingTimeInterval(expected)
            expected = min(expected * 2, ReauthGate.maxDelay)
        }
        XCTAssertEqual(expected, ReauthGate.maxDelay, "delay should have reached the cap")
    }

    func testBackoffAllowsRetryAfterDelay() {
        let id = freshID()
        fail(id, URLError(.timedOut), at: t0)
        XCTAssertTrue(isBlocked(ReauthGate.begin(id, now: t0.addingTimeInterval(ReauthGate.baseDelay - 1))))
        XCTAssertEqual(ReauthGate.begin(id, now: t0.addingTimeInterval(ReauthGate.baseDelay)), .allowed)
        ReauthGate.finish(id, error: nil, now: t0)
    }

    // MARK: status and change notifications (for the UI)

    func testStatusReportsPauseKind() {
        let paused = freshID(), backoff = freshID()
        XCTAssertNil(ReauthGate.status(paused, now: t0))
        fail(paused, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        fail(backoff, URLError(.timedOut), at: t0)
        XCTAssertEqual(ReauthGate.status(paused, now: t0)?.needsUser, true)
        XCTAssertNil(ReauthGate.status(paused, now: t0)?.until)
        XCTAssertEqual(ReauthGate.status(backoff, now: t0)?.needsUser, false)
        XCTAssertEqual(ReauthGate.status(backoff, now: t0)?.until, t0.addingTimeInterval(ReauthGate.baseDelay))
        XCTAssertNil(ReauthGate.status(backoff, now: t0.addingTimeInterval(ReauthGate.baseDelay)), "an expired backoff is no longer a problem")
        ReauthGate.clear(paused)
        XCTAssertNil(ReauthGate.status(paused, now: t0))
    }

    func testStatusReasonIsPlainText() {
        let id = freshID()
        let err = NSError(domain: "SideStepTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "server didn't answer"])
        fail(id, err, at: t0)
        let reason = ReauthGate.status(id, now: t0)?.reason ?? ""
        XCTAssertEqual(reason, "sign-in failed: server didn't answer", "domain/code belong in the log, not the panel")
    }

    private func expectChange(_ id: String, pauseStarted: Bool) -> XCTestExpectation {
        expectation(forNotification: ReauthGate.changed, object: nil) { note in
            (note.userInfo?["appleID"] as? String) == id
                && (note.userInfo?[ReauthGate.pauseStartedKey] as? Bool) == pauseStarted
        }
    }

    func testPauseStartIsAnnouncedOnce() {
        let id = freshID()
        let first = expectChange(id, pauseStarted: true)
        fail(id, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        wait(for: [first], timeout: 2)
        // Ending the pause is announced as a plain change; a new pause after that is a new start.
        ReauthGate.clear(id)
        let cleared = expectChange(id, pauseStarted: false)
        wait(for: [cleared], timeout: 2)
        let again = expectChange(id, pauseStarted: true)
        fail(id, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        wait(for: [again], timeout: 2)
    }

    func testBackoffIsAnnouncedWithoutPauseStart() {
        let id = freshID()
        let change = expectChange(id, pauseStarted: false)
        fail(id, URLError(.timedOut), at: t0)
        wait(for: [change], timeout: 2)
    }

    func testPauseIsStoredInDefaults() {
        let id = freshID()
        fail(id, ALTAppleAPIError.requiresTwoFactorAuthentication, at: t0)
        // A relaunch starts with an empty in-flight set but reads the same defaults domain.
        let data = suite.data(forKey: "sidestep.reauthGate")
        XCTAssertNotNil(data)
        let stored = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
        XCTAssertNotNil(stored?[id], "the pause for this Apple ID must be persisted")
    }
}
