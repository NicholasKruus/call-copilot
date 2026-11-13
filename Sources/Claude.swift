import Foundation
import Security

/// Splits a pipe's output into JSON lines.
private final class LineReader {
    private var buffer = Data()
    func feed(_ data: Data, _ each: ([String: Any]) -> Void) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { each(obj) }
        }
    }
}

/// Finds Claude Code and checks that it is signed by Anthropic. The app's microphone and system-audio permissions
/// pass to every process it spawns, so a swapped or unsigned binary must not run.
enum ClaudeBinary {
    /// The last file that passed, by path, device, inode, size and change time (ctime, which unlike mtime can't be
    /// set back by a user). A swapped or rewritten file is checked again (a check takes ~0.7 s).
    private static var verified: (path: String, key: [Int])?

    static func verifiedPath() throws -> String {
        let fm = FileManager.default
        let found = Config.claudeCandidates.filter { fm.fileExists(atPath: $0) }
        guard !found.isEmpty else {
            throw CaptureError("Claude Code isn't installed. Install it with Anthropic's native installer and sign in.")
        }
        var lastError: Error?
        for candidate in found {
            do { return try check(URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path) } catch { lastError = error }
        }
        throw lastError!
    }

    private static func check(_ path: String) throws -> String {
        var st = stat()
        let key = stat(path, &st) == 0
            ? [Int(st.st_dev), Int(st.st_ino), Int(st.st_size), st.st_ctimespec.tv_sec, st.st_ctimespec.tv_nsec]
            : [-1]
        if let v = verified, v.path == path, v.key == key { return path }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Config.claudeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw CaptureError("couldn't read the signature of \(path)")
        }
        let status = SecStaticCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            verified = nil
            throw CaptureError("\(path) isn't Claude Code signed by Anthropic (\(status)), so it wasn't run. "
                + "Install Claude Code with Anthropic's native installer.")
        }
        verified = (path, key)
        return path
    }
}

/// One headless Claude conversation for a call, fed through stdin as stream-json. Every callback runs on the main
/// queue.
///
/// It reads other people's speech, so it gets no connectors, files, shell or settings. With web on it gets exactly
/// two tools: web search, and opening pages, which the permission rules limit to the trusted sites (plus a few
/// documentation sites Claude Code always allows). Every turn must start with an init event listing only those tools;
/// if one lists anything else, or none comes (say, after a Claude Code update), the session stops itself.
final class ClaudeSession {
    var onReady: (() -> Void)?
    /// Final text of each turn, or an error string.
    var onResult: ((String?, String?) -> Void)?
    var onToolUse: ((_ id: String, _ name: String, _ input: [String: Any]) -> Void)?
    var onToolResult: ((_ toolUseID: String, _ content: Any?, _ isError: Bool) -> Void)?
    /// The process exited, or the session stopped itself for a reason a restart wouldn't fix.
    var onExit: ((_ reason: String, _ restartable: Bool) -> Void)?
    private(set) var ready = false

    private let settings: Settings
    private var process: Process?
    private var stdin: FileHandle?
    private let reader = LineReader()
    private var sawInit = false

    init(settings: Settings) { self.settings = settings }

    private var expectedTools: Set<String> { settings.usesWeb ? ["WebSearch", "WebFetch"] : [] }

    func start(systemPrompt: String) throws {
        let path = try ClaudeBinary.verifiedPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--model", settings.modelName, "--effort", settings.effortLevel,
                    "--permission-mode", "dontAsk", // anything not explicitly allowed is refused
                    "--no-session-persistence", // nothing from the call is saved by claude
                    "--setting-sources", "", // none of the user's settings, hooks, plugins or instructions
                    "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, // no connectors
                    "--system-prompt", systemPrompt]
        if settings.usesWeb {
            args += ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch"] + settings.fetchRules
        } else {
            args += ["--tools", ""]
        }
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = childEnvironment()
        p.standardError = FileHandle.nullDevice
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.reader.feed(data) { self?.handle($0) } }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.onExit?("exited (\(proc.terminationStatus))", true) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        DispatchQueue.main.async { [weak self] in
            guard let self, self.process != nil else { return }
            self.ready = true
            self.onReady?()
        }
    }

    private func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "system" where ev["subtype"] as? String == "init":
            // A missing or renamed tool list fails closed too.
            guard let tools = ev["tools"] as? [String], Set(tools).isSubset(of: expectedTools) else {
                log("claude: the call session was given unexpected tools; stopping it")
                let exit = onExit
                stop()
                exit?("it was given tools it shouldn't have", false)
                return
            }
            sawInit = true
        case "assistant":
            guard let msg = ev["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where c["type"] as? String == "tool_use" {
                onToolUse?(c["id"] as? String ?? "", c["name"] as? String ?? "", c["input"] as? [String: Any] ?? [:])
            }
        case "user":
            guard let msg = ev["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where c["type"] as? String == "tool_result" {
                onToolResult?(c["tool_use_id"] as? String ?? "", c["content"], c["is_error"] as? Bool == true)
            }
        case "result":
            guard sawInit else { // a turn whose tools weren't checked
                log("claude: a turn came without its init event; stopping the session")
                let exit = onExit
                stop()
                exit?("its tools couldn't be checked", false)
                return
            }
            sawInit = false
            let isError = ev["is_error"] as? Bool == true
            let text = ev["result"] as? String
            let cost = (ev["total_cost_usd"] as? Double).map { String(format: ", $%.3f so far at API prices", $0) } ?? ""
            log("claude: turn done in \(ev["duration_ms"] as? Int ?? -1) ms\(isError ? " (error)" : "")\(cost)")
            onResult?(isError ? nil : text, isError ? (text ?? "error") : nil)
        default:
            break
        }
    }

    func send(_ text: String) {
        guard ready else { log("claude: send before ready, dropped"); return }
        let msg: [String: Any] = ["type": "user",
                                  "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        do { try stdin?.write(contentsOf: data + Data([0x0A])) } catch { log("claude: write failed: \(error)") }
    }

    func stop() {
        onExit = nil; onResult = nil; onReady = nil; onToolUse = nil; onToolResult = nil
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { // a hung process may ignore SIGTERM
                if p.isRunning { log("claude: didn't quit; killing it"); kill(pid, SIGKILL) }
            }
        }
        process = nil
        ready = false
    }
}
