import Foundation
import Darwin

/// Queue delay and CPU activity describe different responsiveness conditions.
final class MainThreadMonitor {
    private weak var client: Logfire?
    private let queue = DispatchQueue(label: "dev.logfire.swift.responsiveness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var port: mach_port_t = 0
    private var probe: TimeInterval?
    private var window = ResponsivenessWindow()

    init(client: Logfire) {
        self.client = client
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let port = mach_thread_self()
            queue.async { [weak self] in
                guard let self else { mach_port_deallocate(mach_task_self_, port); return }
                self.port = port
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
            }
        }
    }

    private func tick() {
        guard let client else { timer?.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let age = probe.map { (now - $0) * 1000 } ?? 0
        if probe == nil {
            probe = now
            DispatchQueue.main.async { [weak self] in
                let completed = ProcessInfo.processInfo.systemUptime
                self?.queue.async { [weak self] in
                    guard let self, let began = self.probe else { return }
                    self.window.delays.append((completed - began) * 1000)
                    self.client?.metrics?.record(.mainQueueDelay, value: (completed - began) * 1000)
                    self.probe = nil
                }
            }
        }
        if let values = window.sample(now: now, mainCPU: cpuTime(), process: Self.processUsage(), pendingAge: age) {
            client.event("app.responsiveness.window", attributes: values)
            if case .double(let value) = values["main_queue.pending_age_max_ms"] { client.metrics?.record(.mainQueuePending, value: value) }
            if case .double(let value) = values["main_thread.cpu.utilization"] { client.metrics?.record(.mainThreadCPU, value: value) }
            if case .double(let value) = values["process.cpu.utilization"] { client.metrics?.record(.processCPU, value: value) }
            if case .double(let value) = values["process.memory.footprint_bytes"] { client.metrics?.record(.processMemory, value: value) }
        }
    }

    private func cpuTime() -> Double? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    static func processUsage() -> (cpu: Double, memory: Double)? {
#if os(macOS)
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return nil }
        var cpu = rusage()
        guard getrusage(RUSAGE_SELF, &cpu) == 0 else { return nil }
        let seconds = Double(cpu.ru_utime.tv_sec + cpu.ru_stime.tv_sec) + Double(cpu.ru_utime.tv_usec + cpu.ru_stime.tv_usec) / 1_000_000
        return (seconds, Double(usage.ri_phys_footprint))
#else
        return nil
#endif
    }

    deinit { timer?.cancel(); if port != 0 { mach_port_deallocate(mach_task_self_, port) } }
}

struct ResponsivenessWindow {
    var delays: [Double] = []
    private var began: Double?
    private var pendingMaximum = 0.0
    private var mainCPU: Double?
    private var processCPU: Double?
    mutating func sample(now: Double, mainCPU: Double?, process: (cpu: Double, memory: Double)?, pendingAge: Double) -> [String: LogfireAttribute]? {
        pendingMaximum = max(pendingMaximum, pendingAge)
        guard let began else { self.began = now; self.mainCPU = mainCPU; processCPU = process?.cpu; return nil }
        let seconds = now - began
        guard seconds >= 5 else { return nil }
        var values: [String: LogfireAttribute] = ["window_seconds": .double(seconds), "main_queue.pending_age_ms": .double(pendingAge),
            "main_queue.pending_age_max_ms": .double(pendingMaximum), "main_queue.completed_probes": .int(delays.count), "measurement.source": .string("sdk.main_thread_monitor"),
            "measurement.scope": .string("main_queue_delay_and_thread_cpu"), "cpu.utilization_denominator": .string("one_core_wall_time")]
        if let cpu = mainCPU, let previous = self.mainCPU, cpu >= previous { values["main_thread.cpu.utilization"] = .double((cpu - previous) / seconds) }
        if let cpu = process?.cpu, let previous = processCPU, cpu >= previous { values["process.cpu.utilization"] = .double((cpu - previous) / seconds) }
        if let memory = process?.memory { values["process.memory.footprint_bytes"] = .double(memory) }
        if !delays.isEmpty {
            let sorted = delays.sorted()
            values["main_queue.delay_p95_ms"] = .double(sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)])
            values["main_queue.delay_max_ms"] = .double(sorted.last!)
        }
        self.began = now; self.mainCPU = mainCPU; processCPU = process?.cpu; pendingMaximum = 0; delays.removeAll(keepingCapacity: true)
        return values
    }
}
