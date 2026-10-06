import CryptoKit
import Foundation

// Xcode runs this host-only script. The app resource contains build metadata without credentials.
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fatalError("Usage: embed-build.swift SOURCE_DIRECTORY PACKAGE_DIRECTORY OUTPUT_JSON")
}
let source = URL(fileURLWithPath: arguments[1])
let package = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])
let environment = ProcessInfo.processInfo.environment
let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
git.arguments = ["-C", source.path, "rev-parse", "HEAD"]
let pipe = Pipe()
git.standardOutput = pipe
git.standardError = FileHandle.nullDevice
try git.run()
let commit = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(
    in: .whitespacesAndNewlines)
git.waitUntilExit()

var digest = SHA256()
let roots = [
    source, package.appendingPathComponent("Sources"), package.appendingPathComponent("Package.swift"),
    package.appendingPathComponent("Package.resolved"),
]
for (index, root) in roots.enumerated() {
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else { continue }
    let files: [URL]
    if directory.boolValue {
        var selected: [URL] = []
        let ignored = Set(["DerivedData", "node_modules", "tmp", "video", "xcuserdata"])
        let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let file = entries?.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                if ignored.contains(file.lastPathComponent) { entries?.skipDescendants() }
            } else if ["swift", "metal", "pbxproj"].contains(file.pathExtension)
                || file.lastPathComponent == "Package.resolved"
            {
                selected.append(file)
            }
        }
        files = selected.sorted { $0.path < $1.path }
    } else {
        files = [root]
    }
    for file in files {
        let name = directory.boolValue ? String(file.path.dropFirst(root.path.count + 1)) : file.lastPathComponent
        digest.update(data: Data("\(index)/\(name)\0".utf8))
        digest.update(data: try Data(contentsOf: file))
    }
}
var metadata = [
    "build.id": environment["LOGFIRE_BUILD_ID"].flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
        ?? UUID().uuidString.lowercased(),
    "git.commit": git.terminationStatus == 0 ? commit ?? "unknown" : "unknown",
    "build.source_digest": digest.finalize().map { String(format: "%02x", $0) }.joined(),
    "build.configuration": environment["CONFIGURATION"] ?? "unknown",
    "build.sdk": environment["SDK_NAME"] ?? "unknown",
    "xcode.version": environment["XCODE_VERSION_ACTUAL"] ?? "unknown",
]
if let trace = environment["LOGFIRE_BUILD_TRACE_ID"] { metadata["build.trace_id"] = trace }
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: output, options: .atomic)
print("App build identity: \(metadata["build.id"]!)")
