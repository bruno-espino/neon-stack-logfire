import Foundation

#if os(macOS)
    enum ThreadTimelineError: Error, Equatable, CustomStringConvertible {
        case identity
        case schema(String)
        case reference
        case field(String)
        case overlappingStates, missingMainThread

        var description: String {
            switch self {
            case .identity: return "The native timeline does not identify this retained session and executable interval"
            case .schema(let name): return "The native timeline has an unsupported or ambiguous \(name) table"
            case .reference: return "The native timeline has duplicate or unresolved XML references"
            case .field(let name): return "The native timeline has an invalid \(name) field"
            case .overlappingStates: return "Main-thread state intervals overlap"
            case .missingMainThread: return "The native timeline contains no identified main-thread intervals"
            }
        }
    }

    struct ThreadStateInterval: Codable {
        let state: String
        let startedAt: Double
        let endedAt: Double
        var milliseconds: Double { (endedAt - startedAt) * 1000 }
    }

    struct ThreadSyscall: Codable {
        let name: String
        var calls = 0
        var wallMilliseconds = 0.0
        var waitMilliseconds = 0.0
        var measuredWaitCalls = 0
        var longestMilliseconds = 0.0
    }

    struct TimelineWindowRequest: Codable {
        let findingID: String
        let source: String
        let startedAt: Double
        let endedAt: Double
    }

    struct ThreadTimelineWindow: Codable {
        let request: TimelineWindowRequest
        let observedMilliseconds: Double
        let coverageFraction: Double
        let statesMilliseconds: [String: Double]
    }

    /// States partition one thread's observed interval. Syscalls describe overlapping evidence within that interval.
    struct ThreadTimelineEvidence: Codable {
        let captureID: String
        let mainThreadID: UInt64
        let startedAt: Double
        let endedAt: Double
        let statesMilliseconds: [String: Double]
        let unobservedMilliseconds: Double
        let stateIntervals: Int
        let longestNonRunning: [ThreadStateInterval]
        let syscalls: [ThreadSyscall]
        let boundarySyscallsOmitted: Int
        let limitations: [String]
        var windows: [ThreadTimelineWindow]?
        var omittedWindowRequests: Int?
        var correlationGaps: [String]?
    }

    private struct TimelineTable {
        let columns: [String]
        let rows: [XMLElement]
        let references: [String: XMLElement]

        init(_ data: Data, name: String, required: [String: String]) throws {
            let document = try InstrumentsXML.document(data)
            guard let root = document.rootElement(), root.name == "trace-query-result",
                let node = root.elements(forName: "node").first, root.elements(forName: "node").count == 1,
                let schema = node.elements(forName: "schema").first, node.elements(forName: "schema").count == 1,
                schema.attribute(forName: "name")?.stringValue == name
            else { throw ThreadTimelineError.schema(name) }
            let definitions = schema.elements(forName: "col")
            columns = definitions.compactMap { $0.elements(forName: "mnemonic").first?.stringValue }
            guard columns.count == definitions.count, columns.count <= 64, Set(columns).count == columns.count,
                required.allSatisfy({ key, type in
                    definitions.contains {
                        $0.elements(forName: "mnemonic").first?.stringValue == key
                            && $0.elements(forName: "engineering-type").first?.stringValue == type
                    }
                })
            else { throw ThreadTimelineError.schema(name) }
            rows = node.elements(forName: "row")
            var pool: [String: XMLElement] = [:]
            for case let element as XMLElement in try root.nodes(forXPath: ".//*[@id]") {
                guard pool.count < 100_000, let id = element.attribute(forName: "id")?.stringValue,
                    pool.updateValue(element, forKey: id) == nil
                else { throw ThreadTimelineError.reference }
            }
            references = pool
        }

        func resolve(_ element: XMLElement) throws -> XMLElement {
            guard let id = element.attribute(forName: "ref")?.stringValue else { return element }
            guard let target = references[id], target.name == element.name,
                target.attribute(forName: "ref") == nil
            else { throw ThreadTimelineError.reference }
            return target
        }

        func values(_ row: XMLElement) throws -> [String: XMLElement] {
            let fields = (row.children ?? []).compactMap { $0 as? XMLElement }
            guard fields.count == columns.count else { throw ThreadTimelineError.field("row width") }
            return try Dictionary(uniqueKeysWithValues: zip(columns, fields).map { ($0, try resolve($1)) })
        }

        func number(_ element: XMLElement?, type: String) throws -> Double {
            guard let element, element.name == type, let value = Double(element.stringValue ?? ""),
                value.isFinite, value >= 0
            else { throw ThreadTimelineError.field(type) }
            return value
        }

        func integer(_ element: XMLElement?, type: String) throws -> UInt64 {
            guard let element, element.name == type, let value = UInt64(element.stringValue ?? "") else {
                throw ThreadTimelineError.field(type)
            }
            return value
        }

        func child(_ element: XMLElement?, name: String) throws -> XMLElement {
            guard let element, let child = element.elements(forName: name).first else {
                throw ThreadTimelineError.field(name)
            }
            return try resolve(child)
        }

        func mainThread(_ values: [String: XMLElement], pid: Int32) throws -> UInt64? {
            let process = try integer(child(values["process"], name: "pid"), type: "pid")
            guard process == UInt64(pid) else { return nil }
            guard let thread = values["thread"], thread.name == "thread" else {
                throw ThreadTimelineError.field("thread")
            }
            let threadProcess = try child(thread, name: "process")
            guard try integer(child(threadProcess, name: "pid"), type: "pid") == process else {
                throw ThreadTimelineError.identity
            }
            guard thread.attribute(forName: "fmt")?.stringValue?.hasPrefix("Main Thread (") == true else { return nil }
            return try integer(child(thread, name: "tid"), type: "tid")
        }
    }

    enum ThreadTimeline {
        static let limitations = [
            "This is an instrumented diagnostic interval. External host load was not controlled. Do not use it as a performance baseline.",
            "Blocked states include normal sleeps and event-loop waits. They do not identify a lock owner or prove a defect.",
            "Runnable and preempted intervals differ from blocked intervals. Host contention can delay a runnable thread.",
            "Syscall wall and Apple Wait Time fields overlap thread states. Do not add them to state durations or infer a blocking resource.",
            "Syscall summaries omit calls cut by an interval boundary. Missing Wait Time fields are counted, not filled with zero.",
            "The import matches PID, executable path, session marker and interval. The recording does not independently verify the reported binary hash.",
            "Absolute interval boundaries inherit the precision of Apple's exported recording start date.",
            "Window correlation uses all decoded state intervals. SDK windows are coarse observation periods, not exact stall timestamps. Overlap does not establish causation.",
            "Window coverage uses observed main-thread state time divided by the requested SDK window duration. Overlapping windows must not be added.",
            "No GPU scheduling, presentation deadline, synchronization owner, or complete frame timeline is inferred from these tables.",
        ]

        static func decode(
            states: Data, syscalls: Data, pid: Int32, recordingStart: Double,
            interval: ClosedRange<Double>, captureID: String, requests: [TimelineWindowRequest] = []
        ) throws -> ThreadTimelineEvidence {
            guard pid > 0, recordingStart.isFinite, interval.lowerBound.isFinite, interval.upperBound.isFinite,
                interval.upperBound > interval.lowerBound, interval.lowerBound >= recordingStart
            else {
                throw ThreadTimelineError.identity
            }
            let stateTable = try TimelineTable(
                states, name: "thread-state",
                required: [
                    "start": "start-time", "thread": "thread", "state": "thread-state",
                    "duration": "duration", "process": "process",
                ])
            var selected: [ThreadStateInterval] = []
            var tid: UInt64?
            for row in stateTable.rows {
                let values = try stateTable.values(row)
                guard let main = try stateTable.mainThread(values, pid: pid) else { continue }
                guard tid == nil || tid == main else { throw ThreadTimelineError.identity }
                tid = main
                let offset = try stateTable.number(values["start"], type: "start-time")
                let duration = try stateTable.number(values["duration"], type: "duration")
                let start = recordingStart + offset / 1e9
                let end = recordingStart + (offset + duration) / 1e9
                guard end.isFinite, let state = values["state"], state.name == "thread-state",
                    let name = state.stringValue,
                    name.range(of: "^[A-Za-z][A-Za-z0-9_ -]{0,63}$", options: .regularExpression) != nil
                else { throw ThreadTimelineError.field("state interval") }
                let lower = max(start, interval.lowerBound)
                let upper = min(end, interval.upperBound)
                if upper > lower { selected.append(ThreadStateInterval(state: name, startedAt: lower, endedAt: upper)) }
            }
            guard let tid, tid > 0, !selected.isEmpty else { throw ThreadTimelineError.missingMainThread }
            selected.sort { $0.startedAt < $1.startedAt }
            for pair in zip(selected, selected.dropFirst()) where pair.0.endedAt > pair.1.startedAt {
                throw ThreadTimelineError.overlappingStates
            }
            var totals: [String: Double] = [:]
            for state in selected { totals[state.state, default: 0] += state.milliseconds }
            guard totals.count <= 32 else { throw ThreadTimelineError.field("state count") }
            guard
                requests.allSatisfy({
                    ["slow_callback_intervals", "main_queue_delay"].contains($0.findingID)
                        && ["sdk.frame_recorder", "sdk.main_thread_monitor"].contains($0.source)
                        && $0.startedAt.isFinite && $0.endedAt.isFinite && $0.endedAt > $0.startedAt
                })
            else { throw ThreadTimelineError.field("window requests") }
            let windows = requests.prefix(20).map { request in
                var values: [String: Double] = [:]
                for state in selected {
                    let duration = min(state.endedAt, request.endedAt) - max(state.startedAt, request.startedAt)
                    if duration > 0 { values[state.state, default: 0] += duration * 1000 }
                }
                let observed = values.values.reduce(0, +)
                return ThreadTimelineWindow(
                    request: request, observedMilliseconds: observed,
                    coverageFraction: min(1, observed / ((request.endedAt - request.startedAt) * 1000)),
                    statesMilliseconds: values)
            }
            let syscallTable = try TimelineTable(
                syscalls, name: "syscall",
                required: [
                    "start": "start-time", "thread": "thread", "call": "syscall", "duration": "duration",
                    "process": "process", "waittime": "duration-waiting",
                ])
            var calls: [String: ThreadSyscall] = [:]
            var boundaryCalls = 0
            for row in syscallTable.rows {
                let values = try syscallTable.values(row)
                guard let main = try syscallTable.mainThread(values, pid: pid) else { continue }
                guard main == tid else { throw ThreadTimelineError.identity }
                let offset = try syscallTable.number(values["start"], type: "start-time")
                let nanoseconds = try syscallTable.number(values["duration"], type: "duration")
                let start = recordingStart + offset / 1e9
                let end = recordingStart + (offset + nanoseconds) / 1e9
                let duration = nanoseconds / 1e9
                guard end.isFinite else { throw ThreadTimelineError.field("syscall interval") }
                guard end > interval.lowerBound, start < interval.upperBound else { continue }
                guard start >= interval.lowerBound, end <= interval.upperBound else {
                    boundaryCalls += 1
                    continue
                }
                guard let call = values["call"], call.name == "syscall", let name = call.stringValue,
                    name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil
                else {
                    throw ThreadTimelineError.field("syscall name")
                }
                guard calls[name] != nil || calls.count < 512 else { throw ThreadTimelineError.field("syscall count") }
                var entry = calls[name] ?? ThreadSyscall(name: name)
                entry.calls += 1
                entry.wallMilliseconds += duration * 1000
                entry.longestMilliseconds = max(entry.longestMilliseconds, duration * 1000)
                if values["waittime"]?.name != "sentinel" {
                    entry.waitMilliseconds +=
                        (try syscallTable.number(values["waittime"], type: "duration-waiting")) / 1e6
                    entry.measuredWaitCalls += 1
                }
                guard entry.wallMilliseconds.isFinite, entry.waitMilliseconds.isFinite else {
                    throw ThreadTimelineError.field("syscall totals")
                }
                calls[name] = entry
            }
            let ordered = calls.values.sorted {
                if $0.wallMilliseconds != $1.wallMilliseconds { return $0.wallMilliseconds > $1.wallMilliseconds }
                return $0.name < $1.name
            }
            return ThreadTimelineEvidence(
                captureID: captureID, mainThreadID: tid,
                startedAt: interval.lowerBound, endedAt: interval.upperBound, statesMilliseconds: totals,
                unobservedMilliseconds: max(
                    0, (interval.upperBound - interval.lowerBound) * 1000 - totals.values.reduce(0, +)),
                stateIntervals: selected.count,
                longestNonRunning: Array(
                    selected.filter { $0.state != "Running" && $0.state != "Terminated" }
                        .sorted {
                            $0.milliseconds == $1.milliseconds
                                ? $0.startedAt < $1.startedAt : $0.milliseconds > $1.milliseconds
                        }.prefix(20)),
                syscalls: Array(ordered.prefix(20)), boundarySyscallsOmitted: boundaryCalls, limitations: limitations,
                windows: windows, omittedWindowRequests: max(0, requests.count - 20))
        }
    }
#endif
