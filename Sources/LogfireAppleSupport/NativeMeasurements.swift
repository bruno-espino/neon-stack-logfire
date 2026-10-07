import CoreFoundation
import Foundation

public enum NativeMeasurements {
    static func date(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

#if os(macOS)
    static func aggregationOffsets(_ interval: ClosedRange<Date>, origin: Date) throws -> ClosedRange<Int> {
        let start = max(0, interval.lowerBound.timeIntervalSince(origin))
        let end = interval.upperBound.timeIntervalSince(origin)
        guard end > start else { throw CompanionError.message("Native trace does not overlap the measurement window") }
        // Apple's CLI accepts whole seconds. Cover the requested interval and retain both date ranges.
        return Int(floor(start))...Int(ceil(end))
    }
#endif

    public static func stateSummaries(_ process: [String: Any], pid: Int32) -> [[String: Any]] {
        guard (process["PID"] as? NSNumber)?.int32Value == pid, let domain = process["Domain"] as? String else { return [] }
        return (process["Groups"] as? [[String: Any]] ?? []).flatMap { group in
            summaries(["PID": pid, "Layers": group["Layers"] ?? []], pid: pid).map { measurement in
                var result = measurement
                result["measurement.scope"] = "state_layer"
                result["state.domain"] = domain
                result["state.label"] = group["State Label"]
                result["state.duration_seconds"] = group["Total Duration (sec)"]
                let window = process["Aggregation Window"] as? [String: Any] ?? [:]
                result["aggregation.started_at"] = window["Start"]
                result["aggregation.ended_at"] = window["End"]
                let metadata = group["Stable State"] as? [String: Any] ?? [:]
                if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                    result["state.metadata"] = String(data: data, encoding: .utf8)
                }
                return result
            }
        }
    }

    public static func summaries(_ process: [String: Any], pid: Int32, stateDomains: Set<String> = []) -> [[String: Any]] {
        guard (process["PID"] as? NSNumber)?.int32Value == pid else { return [] }
        let resource = process["Resource Usage"] as? [String: Any] ?? [:]
        let resourceFields = [
            "Physical Footprint (MiB)": "process.memory_mib",
            "Peak Physical Footprint (MiB)": "process.peak_memory_mib",
            "Metal Device Allocated Size (MiB)": "process.metal_allocated_mib",
            "CPU User Time (Seconds)": "process.cpu_user_seconds",
            "CPU Sys Time (Seconds)": "process.cpu_system_seconds",
            "Disk Reads (MiB)": "process.disk_read_mib",
            "Disk Logical Writes (MiB)": "process.disk_logical_write_mib",
        ]
        var resources: [String: Any] = [:]
        for (native, attribute) in resourceFields {
            if let value = resource[native] as? NSNumber { resources[attribute] = value }
        }
        let resourceRecords = resources.isEmpty ? [] : [resources.merging([
            "measurement.source": "apple.metalperftrace", "measurement.scope": "process",
        ]) { _, metadata in metadata }]
        let layers = process["Layers"] as? [[String: Any]] ?? []
        return resourceRecords
            + layers.enumerated().map { index, layer in
                layerSummary(
                    layer, index: index,
                    states: (process["States"] as? [String: Any] ?? [:]).filter { stateDomains.contains($0.key) })
            }
    }

    public static func shaderTimelineSummaries(_ process: [String: Any], pid: Int32) -> [[String: Any]] {
        guard (process["PID"] as? NSNumber)?.int32Value == pid else { return [] }
        return (process["Layers"] as? [[String: Any]] ?? []).enumerated().flatMap { index, layer in
            (layer["Stats Timeline"] as? [[String: Any]] ?? []).compactMap { stats in
                guard let start = stats["Start Date"] as? String, let end = stats["End Date"] as? String,
                    let started = date(start), let ended = date(end), ended > started
                else { return nil }
                var timelineLayer: [String: Any] = ["Performance Stats": stats]
                timelineLayer["Layer ID"] = layer["Layer ID"]
                var result = layerSummary(timelineLayer, index: index)
                guard result["shader_compilations"] != nil else { return nil }
                result["measurement.scope"] = "shader_compiler_update"
                return result
            }
        }
    }

    private static func layerSummary(_ layer: [String: Any], index: Int, states: [String: Any] = [:]) -> [String: Any] {
        let stats =
            layer["Performance Stats"] as? [String: Any] ?? layer["Total Session Stats"] as? [String: Any] ?? [:]
        let presented = stats["Presented Frame Stats"] as? [String: Any] ?? [:]
        let skipped = stats["Skipped Frame Stats"] as? [String: Any] ?? [:]
        let configuration = layer["Configuration"] as? [String: Any] ?? [:]
        var result: [String: Any] = [
            "measurement.source": "apple.metalperftrace",
            "measurement.scope": "layer", "layer_index": index,
        ]
        result["layer_id"] = layer["Layer ID"]
        result["measurement.started_at"] = stats["Start Date"] as? String
        result["measurement.ended_at"] = stats["End Date"] as? String
        if !states.isEmpty, let data = try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            result["game.native.states"] = json
        }
        let fields: [(String, Any?)] = [
            ("presented_fps", presented["FPS"]), ("presented_frames", presented["Frame Count"]),
            ("skipped_frames", skipped["Frame Count"]), ("window_seconds", stats["Duration MCT Seconds"]),
            ("drawable_width", configuration["Width (pixels)"]), ("drawable_height", configuration["Height (pixels)"]),
            ("frame_on_glass_mean_ms", mean(stats["Frame-On-Glass Interval Stats"])),
            ("frame_on_glass_max_ms", maximum(stats["Frame-On-Glass Interval Stats"])),
            ("gpu_wall_mean_ms", mean(presented["On-GPU Walltime Stats"])),
            ("cpu_wall_mean_ms", mean(presented["End-to-end Walltime Stats (CPU)"])),
            ("drawable_wait_mean_ms", mean(presented["Next Drawable Wait Walltime Stats"])),
        ]
        for (key, value) in fields { if let number = value as? NSNumber { result[key] = number } }
        if let compiler = presented["Shader Compiler"] as? [String: Any] {
            for (native, attribute, count) in [
                ("Shader Compilations", "shader_compilations", true),
                ("Cached Shader Compilations", "cached_shader_compilations", true),
                ("Pipeline States", "pipeline_states", true),
                ("Shader Compilation Time", "shader_compilation_seconds", false),
                ("Total Shader Compilations", "shader_compilations_total", true),
                ("Total Cached Shader Compilations", "cached_shader_compilations_total", true),
                ("Total Pipeline States", "pipeline_states_total", true),
                ("Total Shader Compilation Time", "shader_compilation_seconds_total", false),
            ] {
                // Overview delta fields describe its last update, not the capture interval.
                if layer["Performance Stats"] == nil && !attribute.hasSuffix("_total") { continue }
                guard let value = compiler[native] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                    value.doubleValue.isFinite, value.doubleValue >= 0,
                    !count || value.doubleValue.rounded() == value.doubleValue
                else { continue }
                result[attribute] = value
            }
        }
        return result
    }

    private static func mean(_ value: Any?) -> NSNumber? {
        guard let stats = value as? [String: Any], let count = stats["Count"] as? NSNumber,
            count.doubleValue > 0
        else { return nil }
        return stats["Average (ms)"] as? NSNumber
    }

    private static func maximum(_ value: Any?) -> NSNumber? {
        guard let stats = value as? [String: Any], let count = stats["Count"] as? NSNumber,
            count.doubleValue > 0
        else { return nil }
        return stats["Max (ms)"] as? NSNumber
    }
}
