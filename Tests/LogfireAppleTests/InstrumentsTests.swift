import Foundation
import CryptoKit
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
final class InstrumentsTests: XCTestCase {
    private let samples = """
    <trace-query-result><node><schema name="time-profile"/>
    <row><process id="p"><pid id="pid">42</pid></process><thread-state id="s">Running</thread-state>
    <thread id="t" fmt="Main Thread (0x1)"/><weight id="w">1000000</weight>
    <tagged-backtrace id="stack"><frame id="leaf" name="render"><binary id="b" name="SyntheticGame" UUID="image-one" path="/private/source"/></frame>
    <frame name="caller"><binary ref="b"/></frame></tagged-backtrace></row>
    <row><process ref="p"/><thread-state ref="s"/><thread ref="t"/><weight ref="w"/><tagged-backtrace ref="stack"/></row>
    <row><process ref="p"/><thread-state ref="s"/><thread fmt="worker"/><weight>2000000</weight>
    <tagged-backtrace><frame name="update"><binary ref="b"/></frame></tagged-backtrace></row>
    <row><process><pid>99</pid></process></row>
    <row><process ref="p"/><thread-state>Waiting</thread-state></row>
    <row><process ref="p"/><thread-state ref="s"/><thread ref="t"/><weight ref="w"/>
    <tagged-backtrace><frame name="0x1234"><binary ref="b"/></frame></tagged-backtrace></row>
    </node></trace-query-result>
    """

    func testCPUWeightsResolveReferencesAndKeepSelfTimeAndProcessScope() throws {
        let summary = try InstrumentsXML.cpu(Data(samples.utf8), pid: 42)
        XCTAssertEqual(summary.samples, 4)
        XCTAssertEqual(summary.weightNanoseconds, 5_000_000)
        XCTAssertEqual(summary.mainThreadWeightNanoseconds, 3_000_000)
        XCTAssertEqual(summary.otherProcessSamples, 1)
        XCTAssertEqual(summary.nonRunningSamples, 1)
        XCTAssertEqual(summary.unresolvedSamples, 1)
        XCTAssertEqual(summary.functions.map(\.symbol), ["render", "update"])
        XCTAssertEqual(summary.functions.first?.samples, 2)
        XCTAssertEqual(summary.functions.first?.weightNanoseconds, 2_000_000)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self).contains("/private/source"))
        XCTAssertFalse(summary.functions.contains { $0.symbol == "caller" })
    }

    func testCPUParserRejectsUnknownSchemaBrokenReferencesAndInvalidWeights() throws {
        XCTAssertThrowsError(try InstrumentsXML.cpu(Data(samples.replacingOccurrences(of: "time-profile", with: "other").utf8), pid: 42))
        XCTAssertThrowsError(try InstrumentsXML.cpu(Data(samples.replacingOccurrences(of: "ref=\"w\"", with: "ref=\"missing\"").utf8), pid: 42))
        XCTAssertThrowsError(try InstrumentsXML.cpu(Data(samples.replacingOccurrences(of: ">1000000<", with: ">nan<").utf8), pid: 42))
        XCTAssertThrowsError(try InstrumentsXML.cpu(Data(samples.replacingOccurrences(of: "<weight>2000000</weight>", with: "<weight id=\"w\">2000000</weight>").utf8), pid: 42))
    }

    func testRecordingIdentityUsesActualDatesWithoutExportingEnvironment() throws {
        let toc = """
        <trace-toc><run number="1"><info><target><process pid="42"/><environment><item key="SECRET" value="private"/></environment></target>
        <summary><start-date>2026-01-01T00:00:00Z</start-date><end-date>2026-01-01T00:00:05Z</end-date>
        <duration>5</duration><instruments-version>27</instruments-version></summary></info></run></trace-toc>
        """
        let recording = try InstrumentsXML.recording(Data(toc.utf8), pid: 42)
        XCTAssertEqual(recording["profile.duration_seconds"] as? Double, 5)
        XCTAssertEqual(recording["profile.started_at"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: recording), as: UTF8.self).contains("private"))
        XCTAssertThrowsError(try InstrumentsXML.recording(Data(toc.utf8), pid: 99))
        XCTAssertThrowsError(try InstrumentsXML.recording(Data(toc.replacingOccurrences(of: "<duration>5", with: "<duration>7").utf8), pid: 42))
        XCTAssertThrowsError(try InstrumentsXML.recording(Data(toc.replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "invalid").utf8), pid: 42))
    }

    func testTimeLimitUsesIntegerMillisecondsAcceptedByXctrace() {
        XCTAssertEqual(InstrumentsProfile.timeLimit(seconds: 5), "5000ms")
        XCTAssertEqual(InstrumentsProfile.timeLimit(seconds: 1.25), "1250ms")
    }

    func testArtifactHashMatchesSHA256AcrossReadBoundaries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data((0..<131_073).map { UInt8($0 % 251) })
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try Companion.fileHash(file), expected)
    }
}
#endif
