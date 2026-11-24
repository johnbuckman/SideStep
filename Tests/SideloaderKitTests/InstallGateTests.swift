// Tests for parallel beacon updates (0.2.74): installs to the same device stay one-at-a-time,
// different devices run concurrently, and each beacon task keeps its own device IP.
// No device, no network, no Apple servers involved.

import XCTest
@testable import SideloaderKit

private actor Recorder {
    var running = 0, maxRunning = 0, order: [String] = []
    func enter(_ s: String) { running += 1; maxRunning = max(maxRunning, running); order.append("+" + s) }
    func leave(_ s: String) { running -= 1; order.append("-" + s) }
}

final class InstallGateTests: XCTestCase {
    private func hold(_ gate: KeyedGate, _ key: String, _ tag: String, _ rec: Recorder) async {
        await gate.acquire(key)
        await rec.enter(tag)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await rec.leave(tag)
        await gate.release(key)
    }

    func testSameKeyIsSerialised() async {
        let gate = KeyedGate(), rec = Recorder()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<4 { g.addTask { await self.hold(gate, "udidA", "\(i)", rec) } }
        }
        let maxRunning = await rec.maxRunning
        XCTAssertEqual(maxRunning, 1, "two installs to one device overlapped")
        let held = await gate.isHeld("udidA")
        XCTAssertFalse(held, "gate not released after the last waiter")
    }

    func testDifferentKeysRunInParallel() async {
        let gate = KeyedGate(), rec = Recorder()
        let start = Date()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<4 { g.addTask { await self.hold(gate, "udid\(i)", "\(i)", rec) } }
        }
        let maxRunning = await rec.maxRunning
        XCTAssertEqual(maxRunning, 4, "different devices were queued behind each other")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
    }

    func testFIFOWithinAKey() async {
        let gate = KeyedGate(), rec = Recorder()
        await gate.acquire("k")                       // hold it so the next three queue up
        let t = Task {
            await withTaskGroup(of: Void.self) { g in
                for i in 0..<3 {
                    g.addTask { await self.hold(gate, "k", "\(i)", rec) }
                    try? await Task.sleep(nanoseconds: 20_000_000)   // enqueue in order 0,1,2
                }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.release("k")
        await t.value
        let order = await rec.order
        XCTAssertEqual(order, ["+0", "-0", "+1", "-1", "+2", "-2"])
    }

    func testBeaconIPIsPerTask() async {
        XCTAssertNil(Sideloader.beaconIP)
        await withTaskGroup(of: (String, String?).self) { g in
            for ip in ["10.0.0.1", "10.0.0.2", "10.0.0.3"] {
                g.addTask {
                    await Sideloader.$beaconIP.withValue(ip) {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        // An unstructured Task (as inside withTimeout) must still see its own IP.
                        let inner = await Task { Sideloader.hintIP() }.value
                        return (ip, inner)
                    }
                }
            }
            for await (ip, seen) in g { XCTAssertEqual(seen, ip, "beacon IP leaked between parallel installs") }
        }
        XCTAssertNil(Sideloader.beaconIP, "beacon IP leaked out of its task")
    }
}
