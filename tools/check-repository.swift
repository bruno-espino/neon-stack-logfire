import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
var failures: [String] = []

func run(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "RepositoryCheck", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "A repository check command failed"])
    }
    return data
}

let names = String(
    decoding: try run("/usr/bin/git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]), as: UTF8.self
)
.split(separator: "\0").map(String.init)
let secret = try NSRegularExpression(
    pattern: #"pylf_v[0-9]+_[a-z]+_[A-Za-z0-9_-]{40,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#)
let links = try NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)]+)\)"#)
for name in names {
    let file = root.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
    let range = NSRange(text.startIndex..., in: text)
    if secret.firstMatch(in: text, range: range) != nil {
        failures.append("Known credential pattern in \(name). The value is not printed.")
    }
    if name.hasSuffix(".md") {
        // Fenced examples can contain illustrative Markdown rather than document links.
        let sections = text.components(separatedBy: "```")
        for (index, section) in sections.enumerated() where index.isMultiple(of: 2) {
            for match in links.matches(in: section, range: NSRange(section.startIndex..., in: section)) {
                guard let targetRange = Range(match.range(at: 1), in: section) else { continue }
                let target = String(section[targetRange]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if target.contains(":") || target.hasPrefix("#") { continue }
                let path = String(target.split(separator: "#", maxSplits: 1).first ?? "")
                if !manager.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(path).path) {
                    failures.append("Missing local document target in \(name): \(path)")
                }
            }
        }
    }
}

var queries: [String] = []
func collectQueries(_ object: Any) {
    if let dictionary = object as? [String: Any] {
        if let query = dictionary["query"] as? String { queries.append(query) }
        dictionary.values.forEach(collectQueries)
    } else if let array = object as? [Any] {
        array.forEach(collectQueries)
    }
}
let dashboardDirectory = root.appendingPathComponent("dashboards")
for file in try manager.contentsOfDirectory(at: dashboardDirectory, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path })
{
    let dashboard = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
    let previousCount = queries.count
    collectQueries(dashboard)
    if queries.count == previousCount { failures.append("A dashboard contains no queries: \(file.lastPathComponent)") }
}
if queries.isEmpty { failures.append("The dashboard contains no queries") }
for query in queries
where query.range(of: #"\bFROM\s+metrics\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
    if query.range(of: #"\b(scalar_value|histogram_[a-z_]+)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    {
        failures.append("A dashboard metric query bypasses the metric value functions")
    }
}

// A renamed app must affect its fingerprint. Generated scratch sources must not.
let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: fixture) }
let app = fixture.appendingPathComponent("WidgetProject")
let package = fixture.appendingPathComponent("Package")
try manager.createDirectory(at: app.appendingPathComponent("Widget"), withIntermediateDirectories: true)
try manager.createDirectory(at: package, withIntermediateDirectories: true)
let source = app.appendingPathComponent("Widget/App.swift")
try "struct Widget {}".write(to: source, atomically: true, encoding: .utf8)
func fingerprint(_ name: String) throws -> String {
    let output = fixture.appendingPathComponent(name + ".json")
    _ = try run(
        "/usr/bin/xcrun",
        ["swift", root.appendingPathComponent("tools/embed-build.swift").path, app.path, package.path, output.path])
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: String],
        let digest = value["build.source_digest"]
    else {
        throw NSError(
            domain: "RepositoryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Build fingerprint is missing"])
    }
    return digest
}
let original = try fingerprint("original")
try "struct Widget { let version = 2 }".write(to: source, atomically: true, encoding: .utf8)
let changed = try fingerprint("changed")
if original == changed { failures.append("The renamed app's source change did not affect its build fingerprint") }
try manager.createDirectory(at: app.appendingPathComponent("tmp"), withIntermediateDirectories: true)
try "struct Scratch {}".write(to: app.appendingPathComponent("tmp/Scratch.swift"), atomically: true, encoding: .utf8)
if try fingerprint("scratch") != changed { failures.append("Ignored scratch sources changed the build fingerprint") }

if !failures.isEmpty {
    for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
    exit(1)
}
print(
    "Repository checks passed: local document targets, known credential patterns, dashboard JSON and metric columns, generic build fingerprint."
)
