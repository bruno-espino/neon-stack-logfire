import Foundation
import LogfireSwift

enum PilotError: Error { case exportDisabled, exportUnacknowledged }

do {
    let client = try Logfire.development(serviceName: "swift-package-pilot", apple: .init(metricKit: false))
    guard client.delivery.enabled else { throw PilotError.exportDisabled }
    await client.withSpan("pilot.load") {
        await Task.yield()
        client.event("pilot.loaded")
    }
    client.flush()
    let delivery = client.delivery
    guard delivery.exportedSpans == 2, delivery.failedSpans == 0 else { throw PilotError.exportUnacknowledged }
    print("SDK-only pilot acknowledged two records. Session: \(client.sessionID)")
    print("Live View filter: attributes->>'session_id' = '\(client.sessionID)'")
} catch {
    FileHandle.standardError.write(Data("SDK pilot failed: \(error). Configure this Mac and enable LOGFIRE_DEV_DIRECT=1.\n".utf8))
    exit(2)
}
