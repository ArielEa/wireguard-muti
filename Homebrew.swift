import Foundation

enum Homebrew: Sendable {
    nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    nonisolated static var isInstalled: Bool { brewPath != nil }

    nonisolated static func binary(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/\(name)" }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    nonisolated static var hasWireGuardTools: Bool {
        binary("wg") != nil && binary("wg-quick") != nil
    }

    nonisolated static func toolsInstalled(for kind: VPNKind) -> Bool {
        switch kind {
        case .wireguard: hasWireGuardTools
        }
    }

    static func install(formula: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                guard let brewPath else {
                    continuation.finish(throwing: WGError.brewMissing)
                    return
                }
                do {
                    try runBrew(brewPath: brewPath, arguments: ["install", formula]) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated private static func runBrew(
        brewPath: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                onOutput(chunk)
            }
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw WGError.brewFailed("brew \(arguments.joined(separator: " ")) failed (exit \(process.terminationStatus)).")
        }
    }
}
