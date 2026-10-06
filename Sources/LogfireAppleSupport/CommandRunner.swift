import Foundation
#if os(macOS)
import Darwin

struct CommandResult {
    let exitCode: Int32
    let timedOut: Bool
    let requestedStop: Bool
}

/// Each command owns a process group. Cancellation also reaches its subprocesses.
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], output: URL, errors: URL,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    seconds: Double, echo: Bool = false, onOutput: ((Data) throws -> Void)? = nil,
                    onLaunch: ((Int32) throws -> Void)? = nil,
                    onTick: (() throws -> Bool)? = nil) throws -> CommandResult {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errors.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM)
        var mask = sigset_t(); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults); posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { vars in
                posix_spawn(&pid, executable, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: vars.baseAddress!))
            }
        }
        guard spawned == 0 else { throw CompanionError.message("Cannot start \(URL(fileURLWithPath: executable).lastPathComponent) (\(spawned))") }
        var reaped = false
        defer { if !reaped { kill(-pid, SIGKILL); var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} } }
        try onLaunch?(pid)
        let cancel = CommandCancellation()
        let stdout = try FileHandle(forReadingFrom: output); let stderr = try FileHandle(forReadingFrom: errors)
        defer { try? stdout.close(); try? stderr.close(); cancel.finish() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var stopping: TimeInterval?
        var timedOut = false; var requestedStop = false; var interrupted: Int32 = 0
        func drain() throws {
            let data = stdout.readDataToEndOfFile(); let errorData = stderr.readDataToEndOfFile()
            if echo { try? FileHandle.standardOutput.write(contentsOf: data); try? FileHandle.standardError.write(contentsOf: errorData) }
            if !data.isEmpty { try onOutput?(data) }
        }
        while true {
            try drain()
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                try drain()
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return CommandResult(exitCode: interrupted == 0 ? code : 128 + interrupted,
                    timedOut: timedOut, requestedStop: requestedStop)
            }
            if waited < 0 && errno != EINTR { throw CompanionError.message("Cannot wait for the command") }
            let now = ProcessInfo.processInfo.systemUptime
            if stopping == nil {
                interrupted = cancel.signum
                timedOut = now >= deadline
                if interrupted == 0 && !timedOut { requestedStop = try onTick?() ?? false }
                if interrupted != 0 || timedOut || requestedStop {
                    kill(-pid, interrupted == 0 ? SIGTERM : interrupted)
                    stopping = ProcessInfo.processInfo.systemUptime + 3
                }
            } else if now >= stopping! { kill(-pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

private final class CommandCancellation {
    private let lock = NSLock()
    private var received: Int32 = 0
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, sig_t?)] = []
    var signum: Int32 { lock.lock(); defer { lock.unlock() }; return received }
    init() {
        for sig in [SIGINT, SIGTERM] {
            previous.append((sig, signal(sig, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }; lock.lock(); received = sig; lock.unlock()
            }
            source.resume(); sources.append(source)
        }
    }
    func finish() {
        for source in sources { source.cancel() }
        for (sig, handler) in previous { signal(sig, handler) }
        sources.removeAll(); previous.removeAll()
    }
}
#endif
