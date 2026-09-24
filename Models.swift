import Foundation

enum WireGuardPaths {
    static let keysDirectory = "/opt/homebrew/etc/wireguard"
    static let expectedHelperVersion = 4
}

enum VPNKind: String, CaseIterable, Identifiable, Sendable {
    case wireguard

    var id: String { rawValue }
    var title: String { "WireGuard" }
    var summary: String { "Modern tunnels. Several connections can stay up at once." }
    var assetName: String { "VPNKindWireGuard" }
    var brewFormula: String { "wireguard-tools" }
}

struct PeerConfig: Identifiable, Equatable, Sendable {
    var id = UUID()
    var publicKey = ""
    var presharedKey = ""
    var allowedIPs = ""
    var endpoint = ""
    var persistentKeepalive = ""

    var hasPublicKey: Bool {
        !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WireGuardConfig: Equatable, Sendable {
    var privateKey = ""
    var address = ""
    var dns = ""
    var listenPort = ""
    var mtu = ""
    var peers: [PeerConfig] = []

    var isComplete: Bool {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return peers.contains { peer in
            !peer.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !peer.allowedIPs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasDefaultRoute: Bool {
        peers.contains { peer in
            peer.allowedIPs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { $0 == "0.0.0.0/0" || $0 == "::/0" }
        }
    }

    var primaryEndpoint: String {
        peers.first { !$0.endpoint.isEmpty }?.endpoint ?? "—"
    }

    func serialized(keyName: String) -> String {
        var lines: [String] = ["# Key = \(keyName)", "[Interface]"]
        func put(_ field: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lines.append("\(field) = \(trimmed)")
        }
        put("PrivateKey", privateKey)
        put("Address", address)
        put("DNS", dns)
        put("ListenPort", listenPort)
        put("MTU", mtu)
        for peer in peers where peer.hasPublicKey {
            lines.append("")
            lines.append("[Peer]")
            put("PublicKey", peer.publicKey)
            put("PresharedKey", peer.presharedKey)
            put("AllowedIPs", peer.allowedIPs)
            put("Endpoint", peer.endpoint)
            put("PersistentKeepalive", peer.persistentKeepalive)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> WireGuardConfig {
        var config = WireGuardConfig()
        var section = ""
        var current = PeerConfig()
        var hasPeer = false

        func flushPeer() {
            guard hasPeer, current.hasPublicKey else {
                current = PeerConfig()
                hasPeer = false
                return
            }
            config.peers.append(current)
            current = PeerConfig()
            hasPeer = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased() == "[interface]" {
                flushPeer()
                section = "interface"
                continue
            }
            if line.lowercased() == "[peer]" {
                flushPeer()
                section = "peer"
                hasPeer = true
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let field = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch (section, field.lowercased()) {
            case ("interface", "privatekey"): config.privateKey = value
            case ("interface", "address"):
                config.address = config.address.isEmpty ? value : config.address + ", " + value
            case ("interface", "dns"):
                config.dns = config.dns.isEmpty ? value : config.dns + ", " + value
            case ("interface", "listenport"): config.listenPort = value
            case ("interface", "mtu"): config.mtu = value
            case ("peer", "publickey"): current.publicKey = value
            case ("peer", "presharedkey"): current.presharedKey = value
            case ("peer", "allowedips"):
                current.allowedIPs = current.allowedIPs.isEmpty ? value : current.allowedIPs + ", " + value
            case ("peer", "endpoint"): current.endpoint = value
            case ("peer", "persistentkeepalive"): current.persistentKeepalive = value
            default: break
            }
        }
        flushPeer()
        return config
    }
}

struct PeerRuntime: Equatable, Sendable {
    var publicKey = ""
    var endpoint = "—"
    var handshake: Date?
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

struct TunnelRuntime: Equatable, Sendable {
    var liveInterface: String
    var listenPort: String = ""
    var publicKey: String = ""
    var peers: [PeerRuntime] = []

    var rx: UInt64 { peers.reduce(0) { $0 + $1.rx } }
    var tx: UInt64 { peers.reduce(0) { $0 + $1.tx } }
    var latestHandshake: Date? { peers.compactMap(\.handshake).max() }
    var endpoint: String { peers.first { $0.endpoint != "—" }?.endpoint ?? "—" }
}

struct Tunnel: Identifiable, Equatable, Sendable {
    var id: String { iface }
    var iface: String
    var keyName: String
    var config: WireGuardConfig
    var runtime: TunnelRuntime?
    var rxRate: Double = 0
    var txRate: Double = 0

    var displayName: String { keyName.isEmpty ? iface : keyName }
    var isUp: Bool { runtime != nil }
}

struct HelperSnapshot: Sendable {
    var helperVersion = 0
    var wgPath = ""
    var wgQuickPath = ""
    var toolsAvailable = false
    var tunnels: [Tunnel] = []
}

enum WGError: LocalizedError, Sendable {
    case helperMissing
    case helperNotBundled
    case helperFailed(String)
    case brewMissing
    case brewFailed(String)

    var isHelperMissing: Bool {
        if case .helperMissing = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The administrator helper is not installed."
        case .helperNotBundled:
            return "The helper script is missing from the app bundle."
        case .helperFailed(let message):
            return message
        case .brewMissing:
            return "Homebrew is not installed. Install it from https://brew.sh then try again."
        case .brewFailed(let message):
            return message
        }
    }
}

enum ByteFormat {
    static func bytes(_ value: UInt64) -> String {
        let n = Double(value)
        if n >= 1_073_741_824 { return String(format: "%.2f GiB", n / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.2f MiB", n / 1_048_576) }
        if n >= 1_024 { return String(format: "%.2f KiB", n / 1_024) }
        return "\(value) B"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond.rounded()))) + "/s"
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let diff = max(0, Int(Date().timeIntervalSince(date)))
        if diff < 60 { return "\(diff)s ago" }
        if diff < 3_600 { return "\(diff / 60)m \(diff % 60)s ago" }
        if diff < 86_400 { return "\(diff / 3_600)h \((diff % 3_600) / 60)m ago" }
        return "\(diff / 86_400)d ago"
    }
}
