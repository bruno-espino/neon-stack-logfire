import Foundation

public enum NativeMeasurements {
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
        return resourceRecords + layers.enumerated().map { index, layer in
            let stats = layer["Performance Stats"] as? [String: Any] ?? layer["Total Session Stats"] as? [String: Any] ?? [:]
            let presented = stats["Presented Frame Stats"] as? [String: Any] ?? [:]
            let skipped = stats["Skipped Frame Stats"] as? [String: Any] ?? [:]
            let configuration = layer["Configuration"] as? [String: Any] ?? [:]
            var result: [String: Any] = ["measurement.source": "apple.metalperftrace",
                "measurement.scope": "layer", "layer_index": index]
            let states = (process["States"] as? [String: Any] ?? [:]).filter { stateDomains.contains($0.key) }
            if !states.isEmpty, let data = try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { result["game.native.states"] = json }
            let fields: [(String, Any?)] = [
                ("presented_fps", presented["FPS"]), ("presented_frames", presented["Frame Count"]),
                ("skipped_frames", skipped["Frame Count"]), ("window_seconds", stats["Duration MCT Seconds"]),
                ("drawable_width", configuration["Width (pixels)"]), ("drawable_height", configuration["Height (pixels)"]),
                ("frame_on_glass_mean_ms", mean(stats["Frame-On-Glass Interval Stats"])),
                ("gpu_wall_mean_ms", mean(presented["On-GPU Walltime Stats"])),
                ("cpu_wall_mean_ms", mean(presented["End-to-end Walltime Stats (CPU)"])),
                ("drawable_wait_mean_ms", mean(presented["Next Drawable Wait Walltime Stats"])),
            ]
            for (key, value) in fields { if let number = value as? NSNumber { result[key] = number } }
            return result
        }
    }

    private static func mean(_ value: Any?) -> NSNumber? {
        guard let stats = value as? [String: Any], let count = stats["Count"] as? NSNumber,
              count.doubleValue > 0 else { return nil }
        return stats["Average (ms)"] as? NSNumber
    }
}
