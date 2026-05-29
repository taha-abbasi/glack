import Testing
import Foundation
@testable import Glack

@Suite("APIDate parsing")
struct APIDateTests {
    @Test("parses RFC 3339 with fractional seconds (Google Chat's default)")
    func parsesFractional() {
        let date = APIDate.parse("2026-05-28T18:30:45.123Z")
        #expect(date != nil)
        let expected = Self.utc(year: 2026, month: 5, day: 28,
                                hour: 18, minute: 30, second: 45,
                                nanos: 123_000_000)
        #expect(abs(date!.timeIntervalSince(expected)) < 0.001)
    }

    @Test("parses RFC 3339 without fractional seconds")
    func parsesNoFractional() {
        let date = APIDate.parse("2026-05-28T18:30:45Z")
        #expect(date != nil)
        let expected = Self.utc(year: 2026, month: 5, day: 28,
                                hour: 18, minute: 30, second: 45)
        #expect(abs(date!.timeIntervalSince(expected)) < 0.001)
    }

    private static func utc(year: Int, month: Int, day: Int,
                            hour: Int, minute: Int, second: Int,
                            nanos: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        c.nanosecond = nanos
        c.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("returns nil for nil / empty / malformed input", arguments: [
        nil as String?,
        "",
        "not a date",
        "2026-13-99T99:99:99Z",
    ])
    func rejectsBadInput(input: String?) {
        #expect(APIDate.parse(input) == nil)
    }

    @Test("parses non-UTC offsets correctly")
    func parsesOffsets() {
        let utc = APIDate.parse("2026-05-28T12:00:00Z")
        let pst = APIDate.parse("2026-05-28T05:00:00-07:00")
        #expect(utc != nil && pst != nil)
        #expect(abs(utc!.timeIntervalSince(pst!)) < 0.01,
                "UTC and PST-equivalent strings should land at the same instant")
    }
}
