import Foundation

#if os(macOS)
    struct DrawableWaitSummary: Codable {
        let calls: Int
        let wallMilliseconds: Double
        let longestMilliseconds: Double
        let boundaryCallsOmitted: Int
    }

    enum DrawableWaits {
        static let schema = "ca-client-buffer-wait-interval"
        static let filename = "drawable-waits.xml"
        static let unavailable =
            "Native next-drawable waits are unavailable. Missing evidence does not mean zero wait time."
        static let limitations = [
            "Next-drawable waits describe the selected main thread's request for an available drawable. They do not identify a GPU scheduling cause or a missed presentation deadline.",
            "Complete next-drawable calls contribute to capture totals. SDK windows use clipped overlapping wait intervals, including boundary calls. These durations overlap thread states and syscalls. Do not add them together.",
        ]

        static func attach(_ data: Data, pid: Int32, recordingStart: Double, evidence: inout ThreadTimelineEvidence)
            throws
        {
            let table = try TimelineTable(
                data, name: schema,
                required: ["start": "start-time", "duration": "duration", "thread": "thread"])
            var waits: [(startedAt: Double, endedAt: Double)] = []
            var calls = 0
            var omitted = 0
            var wall = 0.0
            var longest = 0.0
            for row in table.rows {
                let values = try table.values(row)
                let thread = values["thread"]
                let process = try table.child(thread, name: "process")
                let processID = try table.integer(table.child(process, name: "pid"), type: "pid")
                guard processID == UInt64(pid) else { continue }
                let tid = try table.integer(table.child(thread, name: "tid"), type: "tid")
                guard tid == evidence.mainThreadID else { continue }
                let offset = try table.number(values["start"], type: "start-time")
                let duration = try table.number(values["duration"], type: "duration")
                let start = recordingStart + offset / 1e9
                let end = recordingStart + (offset + duration) / 1e9
                guard end.isFinite else { throw ThreadTimelineError.field("drawable wait interval") }
                guard end > evidence.startedAt, start < evidence.endedAt else { continue }
                if end > start {
                    waits.append((startedAt: max(start, evidence.startedAt), endedAt: min(end, evidence.endedAt)))
                }
                if start >= evidence.startedAt, end <= evidence.endedAt {
                    calls += 1
                    wall += duration / 1e6
                    longest = max(longest, duration / 1e6)
                } else {
                    omitted += 1
                }
            }
            waits.sort { $0.startedAt < $1.startedAt }
            guard wall.isFinite else { throw ThreadTimelineError.field("drawable wait totals") }
            for pair in zip(waits, waits.dropFirst()) where pair.0.endedAt > pair.1.startedAt {
                throw ThreadTimelineError.field("overlapping drawable waits")
            }
            if var windows = evidence.windows {
                for index in windows.indices {
                    let request = windows[index].request
                    windows[index].drawableWaitMilliseconds = waits.reduce(0) { total, wait in
                        total + max(0, min(wait.endedAt, request.endedAt) - max(wait.startedAt, request.startedAt))
                            * 1000
                    }
                }
                evidence.windows = windows
            }
            evidence.drawableWaits = DrawableWaitSummary(
                calls: calls, wallMilliseconds: wall,
                longestMilliseconds: longest, boundaryCallsOmitted: omitted)
        }
    }
#endif
