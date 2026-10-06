import Foundation
import LogfireAppleSupport

do { exit(try Companion.run(arguments: Array(CommandLine.arguments.dropFirst()))) }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
