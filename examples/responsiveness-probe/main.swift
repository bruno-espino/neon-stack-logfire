import Foundation
import CoreFoundation
import LogfireSwift

let client = try Logfire.development(serviceName: "apple-responsiveness-experiment", apple: .init(metricKit: false, responsiveness: true))
let started = ProcessInfo.processInfo.systemUptime
DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
    client.withSpan("experiment.main_thread.sleep", attributes: ["experiment.condition": .string("blocked"), "experiment.controlled": .bool(true)]) {
        Thread.sleep(forTimeInterval: 1.2)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
    client.withSpan("experiment.main_thread.busy", attributes: ["experiment.condition": .string("cpu_busy"), "experiment.controlled": .bool(true)]) {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var value = 0.0
        while ProcessInfo.processInfo.systemUptime < deadline { value += sqrt(Double.random(in: 1...100)) }
        print("Controlled computation checksum: \(value)")
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 17) {
    DispatchQueue.global(qos: .utility).async {
        client.event("experiment.completed", attributes: ["experiment.controlled": .bool(true), "duration_seconds": .double(ProcessInfo.processInfo.systemUptime - started)])
        client.flush()
        print("Session \(client.sessionID). Exported spans \(client.delivery.exportedSpans), failed \(client.delivery.failedSpans). Metrics \(client.metrics!.delivery.exportedMetrics), failed \(client.metrics!.delivery.failedMetrics).")
        exit(client.delivery.failedSpans == 0 && client.metrics!.delivery.failedMetrics == 0 ? 0 : 2)
    }
}
CFRunLoopRun()
