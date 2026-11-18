import XCTest
@testable import omux

final class UsageParseTests: XCTestCase {
    func testWindowsForm() throws {
        let json = #"{"five_hour":{"utilization":12.4,"resets_at":"2026-11-18T04:59:59.943648+00:00"},"seven_day":{"utilization":35.0,"resets_at":"2026-11-21T10:00:00+00:00"},"seven_day_opus":null,"seven_day_oauth_apps":null}"#
        let limits = try XCTUnwrap(UsageMonitor.parse(Data(json.utf8)))
        XCTAssertEqual(limits.map(\.label), ["5h", "Week"])
        XCTAssertEqual(limits.map(\.percent), [12, 35])
        XCTAssertNotNil(limits[0].resetsAt)
        XCTAssertNotNil(limits[1].resetsAt)
    }

    func testListForm() throws {
        let json = #"{"limits":[{"kind":"session","percent":3,"resets_at":"2026-11-18T04:00:00.000Z"},{"kind":"weekly_all","percent":40}]}"#
        let limits = try XCTUnwrap(UsageMonitor.parse(Data(json.utf8)))
        XCTAssertEqual(limits.map(\.label), ["5h", "Week"])
        XCTAssertEqual(limits.map(\.percent), [3, 40])
    }

    func testUnknownForm() {
        XCTAssertNil(UsageMonitor.parse(Data(#"{"error":"nope"}"#.utf8)))
    }
}
