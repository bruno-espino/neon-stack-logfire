import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if canImport(StateReporting)
import StateReporting
#endif

public struct AppleMonitoring {
    public var metricKit: Bool
    public var stateDomains: Set<String>
    public var metadataKeys: Set<String>

    public init(metricKit: Bool = true, stateDomains: Set<String> = [], metadataKeys: Set<String> = []) {
        self.metricKit = metricKit
        self.stateDomains = stateDomains
        self.metadataKeys = metadataKeys
    }
}

extension Logfire {
    /// Configure one client for a trusted development run. Apple reports retain their historical context.
    public static func development(serviceName: String, apple: AppleMonitoring = .init()) throws -> Logfire {
        let configuration = try LogfireConfiguration.development()
        let client = Logfire(serviceName: serviceName, configuration: configuration)
        client.startAppleMonitoring(serviceName: serviceName, configuration: configuration, options: apple)
        return client
    }

    public static var developmentSessionsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/logfire-swift/sessions")
    }

    /// Use a dedicated domain. The SDK owns its StateReporting metadata types.
    public func state(domain: String, label: String, metadata: [String: LogfireAttribute] = [:]) {
        var attributes = metadata
        attributes["state.domain"] = .string(domain)
        attributes["state.label"] = .string(label)
        event("app.state", attributes: attributes)
#if canImport(StateReporting)
        if #available(macOS 27.0, iOS 27.0, *) {
            let stable = SDKStateMetadata(values: metadata)
            let volatile = SDKStateMetadata(values: ["sessionID": .string(sessionID),
                "buildID": .string(Self.buildMetadata(bundle: .main)["build.id"] ?? "unknown")])
            StateReporter.reporter(for: domain, stableMetadata: SDKStateMetadata.self,
                volatileMetadata: SDKStateMetadata.self).reportTransition(to: label,
                    stableMetadata: stable, volatileMetadata: volatile)
        }
#endif
    }
}

#if canImport(StateReporting)
@available(macOS 27.0, iOS 27.0, *)
private struct SDKStateMetadata: ReportableMetadata {
    let values: [String: LogfireAttribute]
    var metadataDictionary: [String: ReportableMetadataValue] {
        values.compactMapValues { value in
            switch value {
            case .string(let value): return .string(value)
            case .int(let value): return .integer(Int128(value))
            case .double(let value): return .floatingPoint(value)
            case .bool(let value): return ReportableMetadataValue(value)
            default: return nil
            }
        }
    }
}
#endif

final class AppleLifecycle {
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "dev.logfire.swift.lifecycle")

    init(flush: @escaping () -> Void) {
#if os(macOS)
        let names = [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification]
#elseif os(iOS)
        let names = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification]
#else
        let names: [Notification.Name] = []
#endif
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async(execute: flush)
            })
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
