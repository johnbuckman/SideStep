import XCTest
@testable import AltSign
@testable import SideloaderKit

/// Apple's GSA edge answers HTTP 503 to "macOS;" in X-MMe-Client-Info since 2026-11-20.
final class ClientInfoTests: XCTestCase {
    func testMacOSLabelIsRewritten() {
        XCTAssertEqual(ALTAnisetteData.appleAcceptedClientInfo("<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"),
                       "<Mac15,7> <Mac OS X;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>")
    }

    func testOtherClientInfoUnchanged() {
        for s in ["<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
                  "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iCloudHelper/1.0)>",
                  "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"] {
            XCTAssertEqual(ALTAnisetteData.appleAcceptedClientInfo(s), s)
        }
    }

    func testEveryIdentitySendsAnAcceptedLabel() {
        for s in [Anisette.thisMacClientInfo, Anisette.iloaderClientInfo] {
            XCTAssertFalse(ALTAnisetteData.appleAcceptedClientInfo(s).contains("macOS;"), s)
        }
    }
}
