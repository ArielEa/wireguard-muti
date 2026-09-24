import Foundation

enum PrivilegedRunner: Sendable {
    nonisolated static let installedHelperPath = "/Library/PrivilegedHelperTools/wgmulti-helper"
    nonisolated static let sudoersPath = "/etc/sudoers.d/wgmulti"

    nonisolated static var bundledHelperURL: URL? {
        Bundle.main.url(forResource: "wghelper", withExtension: "sh")
    }

    nonisolated static var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedHelperPath)
    }

    nonisolated static func runHelper(arguments: [String], stdin: String? = nil, interactive: Bool = true) throws -> String {
        if isHelperInstalled {
            do {
                return try run(
                    executable: "/usr/bin/sudo",
                    arguments: ["-n", installedHelperPath] + arguments,
                    stdin: stdin
                )
            } catch {
                if helperAllowsSudo() || !interactive {
                    throw error
                }
            }
        } else if !interactive {
            throw WGError.helperMissing
        }
        return try runViaAppleScript(arguments: arguments, stdin: stdin)
    }

    nonisolated static func installHelper() throws {
        guard let bundled = bundledHelperURL else { throw WGError.helperNotBundled }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "wgmulti-helper-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: bundled, to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)

        let dest = installedHelperPath
        let sudoers = sudoersPath
        let script = [
            "umask 022",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(appleQuote(tmp.path)) \(appleQuote(dest))",
            "chown root:wheel \(appleQuote(dest))",
            "chmod 755 \(appleQuote(dest))",
            "tmp_sudoers=$(mktemp)",
            "printf '%s\\n' '%admin ALL=(root) NOPASSWD: \(dest)' > \"$tmp_sudoers\"",
            "visudo -c -f \"$tmp_sudoers\" >/dev/null",
            "mv \"$tmp_sudoers\" \(sudoers)",
            "chmod 440 \(sudoers)",
            "chown root:wheel \(sudoers)"
        ].joined(separator: "; ")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try runOsascriptAdmin(script)
    }

    nonisolated private static func helperAllowsSudo() -> Bool {
        guard isHelperInstalled else { return false }
        let result = Result {
            try run(executable: "/usr/bin/sudo", arguments: ["-n", installedHelperPath, "version"], stdin: nil)
        }
        return (try? result.get()) != nil
    }

    nonisolated private static func runViaAppleScript(arguments: [String], stdin: String?) throws -> String {
        guard let bundled = bundledHelperURL else { throw WGError.helperNotBundled }
        let work = FileManager.default.temporaryDirectory.appending(path: "wgmulti-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let helper = work.appending(path: "wghelper.sh")
        try FileManager.default.copyItem(at: bundled, to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        var command = appleQuote(helper.path)
        for argument in arguments {
            command += " " + appleQuote(argument)
        }

        if let stdin, !stdin.isEmpty {
            let input = work.appending(path: "stdin.txt")
            try stdin.write(to: input, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            command = "cat \(appleQuote(input.path)) | " + command
        }

        return try runOsascriptAdmin(command)
    }

    nonisolated private static func runOsascriptAdmin(_ shell: String) throws -> String {
        let apple = "do shell script \(appleString(shell)) with administrator privileges"
        return try run(executable: "/usr/bin/osascript", arguments: ["-e", apple], stdin: nil)
    }

    nonisolated private static func run(executable: String, arguments: [String], stdin: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WGError.helperFailed(message.isEmpty ? (fallback.isEmpty ? "Command failed." : fallback) : message)
        }
        return stdout
    }

    nonisolated private static func appleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

enum HelperClient {
    static func snapshot(interactive: Bool = false) async throws -> HelperSnapshot {
        let raw = try await invoke(["snapshot"], interactive: interactive)
        return parseSnapshot(raw)
    }

    static func up(_ iface: String) async throws {
        _ = try await invoke(["up", iface])
    }

    static func down(_ iface: String) async throws {
        _ = try await invoke(["down", iface])
    }

    static func upsert(name: String, config: WireGuardConfig) async throws {
        _ = try await invoke(["upsert", name], stdin: config.serialized(keyName: name))
    }

    static func delete(_ nameOrIface: String) async throws {
        _ = try await invoke(["delete", nameOrIface])
    }

    static func genkey(name: String) async throws {
        _ = try await invoke(["genkey", name])
    }

    static func registerExisting(name: String, privateKey: String) async throws {
        _ = try await invoke(["exist", name], stdin: privateKey)
    }

    static func installHelper() async throws {
        try await Task.detached(priority: .userInitiated) {
            try PrivilegedRunner.installHelper()
        }.value
    }

    nonisolated private static func invoke(_ arguments: [String], stdin: String? = nil, interactive: Bool = true) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try PrivilegedRunner.runHelper(arguments: arguments, stdin: stdin, interactive: interactive)
        }.value
    }

    private static func parseSnapshot(_ raw: String) -> HelperSnapshot {
        var snapshot = HelperSnapshot()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var currentIface = ""
        var currentLive = ""
        var currentKey = ""
        var currentConf = ""
        var currentDump = ""
        var inTunnel = false

        func flushTunnel() {
            guard inTunnel else { return }
            var tunnel = Tunnel(
                iface: currentIface,
                keyName: currentKey.isEmpty ? currentIface : currentKey,
                config: WireGuardConfig.parse(currentConf)
            )
            if currentLive != "-", !currentLive.isEmpty {
                tunnel.runtime = parseDump(currentDump, liveInterface: currentLive)
            }
            snapshot.tunnels.append(tunnel)
            inTunnel = false
            currentIface = ""
            currentLive = ""
            currentKey = ""
            currentConf = ""
            currentDump = ""
        }

        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.hasPrefix("WGHELPER_SNAPSHOT ") {
                snapshot.helperVersion = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
            } else if line.hasPrefix("WGQUICK=") {
                snapshot.wgQuickPath = String(line.dropFirst(8))
            } else if line.hasPrefix("WG=") {
                snapshot.wgPath = String(line.dropFirst(3))
            } else if line.hasPrefix("TOOLS=") {
                snapshot.toolsAvailable = String(line.dropFirst(6)) == "ok"
            } else if line.hasPrefix("TUNNEL ") {
                flushTunnel()
                inTunnel = true
                let fields = Dictionary(
                    uniqueKeysWithValues: line
                        .dropFirst(7)
                        .split(separator: " ")
                        .compactMap { field -> (String, String)? in
                            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                            guard parts.count == 2 else { return nil }
                            return (parts[0], parts[1])
                        }
                )
                currentIface = fields["iface"] ?? ""
                currentLive = fields["live"] ?? "-"
                currentKey = fields["key"] ?? currentIface
            } else if line.hasPrefix("CONF ") {
                currentConf = decodeBase64(String(line.dropFirst(5)))
            } else if line.hasPrefix("DUMP ") {
                currentDump = decodeBase64(String(line.dropFirst(5)))
            } else if line == "END" {
                flushTunnel()
            }
        }
        flushTunnel()
        return snapshot
    }

    private static func decodeBase64(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = Data(base64Encoded: trimmed) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseDump(_ dump: String, liveInterface: String) -> TunnelRuntime {
        var runtime = TunnelRuntime(liveInterface: liveInterface)
        let rows = dump.split(whereSeparator: \.isNewline)
        guard let first = rows.first else { return runtime }
        let header = first.split(separator: "\t", omittingEmptySubsequences: false)
        if header.count >= 3 {
            runtime.publicKey = String(header[1])
            runtime.listenPort = String(header[2])
        }
        for row in rows.dropFirst() {
            let cols = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 8 else { continue }
            let handshakeRaw = UInt64(cols[4]) ?? 0
            runtime.peers.append(
                PeerRuntime(
                    publicKey: cols[0],
                    endpoint: cols[2].isEmpty ? "—" : cols[2],
                    handshake: handshakeRaw == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(handshakeRaw)),
                    rx: UInt64(cols[5]) ?? 0,
                    tx: UInt64(cols[6]) ?? 0
                )
            )
        }
        return runtime
    }
}
