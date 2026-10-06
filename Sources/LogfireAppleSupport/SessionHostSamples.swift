import Foundation
import LogfireSwift
#if os(macOS)

/// Whole-host load supplies session context. It does not attribute that load to the game.
struct SessionHostSamples {
    private var host = HostSamples()
    private let began = ProcessInfo.processInfo.systemUptime
    private var next = ProcessInfo.processInfo.systemUptime + 1
    private(set) var records: [[String: Any]] = []
    var isDue: Bool { ProcessInfo.processInfo.systemUptime >= next }

    mutating func tick(client: Logfire, context: [String: Any]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= next else { return }
        next = now + 1
        var sample = host.sample(elapsed: now - began)
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        sample["recorded_at"] = date.string(from: Date())
        sample["measurement.source"] = "darwin.host"
        let record = context.merging(sample) { _, measured in measured }
        records.append(record)
        client.event("game.host.sample", attributes: Companion.attributes(record))
    }

    func write(to url: URL) throws {
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
}
#endif
