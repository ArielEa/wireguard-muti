import Foundation
import SwiftUI

@Observable
final class AppModel {
    private static let vpnKindKey = "vpnKind"

    var vpnKind: VPNKind?
    var tunnels: [Tunnel] = []
    var selectedID: String?
    var helperInstalled = PrivilegedRunner.isHelperInstalled
    var toolsAvailable = false
    var localToolsAvailable = false
    var brewAvailable = Homebrew.isInstalled
    var helperVersion = 0
    var wgPath = ""
    var wgQuickPath = ""
    var lastError: String?
    var busyIDs: Set<String> = []
    var pendingEnabled: [String: Bool] = [:]
    var isInstallingHelper = false
    var isInstallingTools = false
    var toolsInstallLog = ""
    var showNewTunnel = false
    var showEditor = false
    var editingTunnel: Tunnel?

    private var pollTask: Task<Void, Never>?
    private var previousCounters: [String: (rx: UInt64, tx: UInt64, at: Date)] = [:]

    var selectedTunnel: Tunnel? {
        tunnels.first { $0.id == selectedID } ?? tunnels.first
    }

    var connectedCount: Int {
        tunnels.filter(\.isUp).count
    }

    var needsHelperUpdate: Bool {
        helperInstalled && helperVersion > 0 && helperVersion < WireGuardPaths.expectedHelperVersion
    }

    var hasDefaultRouteOverlap: Bool {
        tunnels.filter(\.isUp).filter(\.config.hasDefaultRoute).count > 1
    }

    var needsToolsSetup: Bool {
        vpnKind == .wireguard && !localToolsAvailable
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.vpnKindKey) {
            vpnKind = VPNKind(rawValue: raw)
        }
        refreshLocalTools()
        if vpnKind == .wireguard {
            start()
        }
    }

    deinit {
        stop()
    }

    private func start() {
        helperInstalled = PrivilegedRunner.isHelperInstalled
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.busyIDs.isEmpty {
                    await self.refresh()
                }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(interactive: Bool = false) async {
        helperInstalled = PrivilegedRunner.isHelperInstalled
        do {
            let snapshot = try await HelperClient.snapshot(interactive: interactive)
            apply(snapshot)
            lastError = nil
        } catch let error as WGError where error.isHelperMissing && !interactive {
            helperInstalled = PrivilegedRunner.isHelperInstalled
        } catch {
            if tunnels.isEmpty {
                lastError = error.localizedDescription
            }
        }
    }

    func selectVPN(_ kind: VPNKind) {
        vpnKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: Self.vpnKindKey)
        lastError = nil
        toolsInstallLog = ""
        refreshLocalTools()
        if kind == .wireguard {
            start()
        } else {
            stop()
            tunnels = []
            selectedID = nil
        }
    }

    func changeVPN() {
        stop()
        tunnels = []
        selectedID = nil
        pendingEnabled = [:]
        busyIDs = []
        vpnKind = nil
        toolsInstallLog = ""
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.vpnKindKey)
        refreshLocalTools()
    }

    func refreshLocalTools() {
        brewAvailable = Homebrew.isInstalled
        if let vpnKind {
            localToolsAvailable = Homebrew.toolsInstalled(for: vpnKind)
            if vpnKind == .wireguard {
                toolsAvailable = localToolsAvailable
                wgPath = Homebrew.binary("wg") ?? wgPath
                wgQuickPath = Homebrew.binary("wg-quick") ?? wgQuickPath
            }
        } else {
            localToolsAvailable = false
        }
    }

    func installSelectedTools() async {
        guard let formula = vpnKind?.brewFormula else { return }
        isInstallingTools = true
        toolsInstallLog = ""
        lastError = nil
        defer { isInstallingTools = false }
        do {
            for try await chunk in Homebrew.install(formula: formula) {
                toolsInstallLog.append(chunk)
            }
            refreshLocalTools()
            if vpnKind == .wireguard {
                await refresh()
            }
        } catch {
            lastError = error.localizedDescription
            toolsInstallLog.append("\n\(error.localizedDescription)\n")
            refreshLocalTools()
        }
    }

    func installHelper() async {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        do {
            try await HelperClient.installHelper()
            helperInstalled = true
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isEnabled(_ tunnel: Tunnel) -> Bool {
        if let pending = pendingEnabled[tunnel.id] {
            return pending
        }
        return tunnels.first(where: { $0.id == tunnel.id })?.isUp ?? tunnel.isUp
    }

    func connectionBinding(for tunnel: Tunnel) -> Binding<Bool> {
        Binding(
            get: { self.isEnabled(tunnel) },
            set: { on in
                if self.pendingEnabled[tunnel.id] == nil, on == tunnel.isUp { return }
                self.pendingEnabled[tunnel.id] = on
                Task { await self.setConnected(tunnel, on) }
            }
        )
    }

    func setConnected(_ tunnel: Tunnel, _ on: Bool) async {
        pendingEnabled[tunnel.id] = on
        if busyIDs.contains(tunnel.id) { return }
        busyIDs.insert(tunnel.id)
        defer { busyIDs.remove(tunnel.id) }

        while let desired = pendingEnabled[tunnel.id] {
            let current = tunnels.first(where: { $0.id == tunnel.id })?.isUp ?? false
            if desired == current {
                pendingEnabled.removeValue(forKey: tunnel.id)
                break
            }
            do {
                if desired {
                    try await HelperClient.up(tunnel.iface)
                } else {
                    try await HelperClient.down(tunnel.iface)
                }
                lastError = nil
                await refresh()
            } catch {
                lastError = error.localizedDescription
                pendingEnabled.removeValue(forKey: tunnel.id)
                await refresh()
                break
            }
        }
    }

    func connectAll() async {
        for tunnel in tunnels where !tunnel.isUp {
            await setConnected(tunnel, true)
        }
    }

    func disconnectAll() async {
        for tunnel in tunnels where tunnel.isUp {
            await setConnected(tunnel, false)
        }
    }

    func createGenerated(name: String) async {
        do {
            try await HelperClient.genkey(name: name)
            lastError = nil
            await refresh()
            if let created = tunnels.first(where: { $0.keyName == name }) {
                selectedID = created.id
                editingTunnel = created
                showEditor = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerExisting(name: String, privateKey: String) async {
        do {
            try await HelperClient.registerExisting(name: name, privateKey: privateKey)
            lastError = nil
            await refresh()
            if let created = tunnels.first(where: { $0.keyName == name }) {
                selectedID = created.id
                editingTunnel = created
                showEditor = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importConfig(name: String, text: String) async {
        let config = WireGuardConfig.parse(text)
        if config.privateKey.isEmpty {
            lastError = "That file has no PrivateKey."
            return
        }
        do {
            try await HelperClient.upsert(name: name, config: config)
            lastError = nil
            await refresh()
            selectedID = tunnels.first { $0.keyName == name }?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveEditor(name: String, config: WireGuardConfig, original: Tunnel) async {
        var config = config
        config.peers.removeAll { !$0.hasPublicKey }
        do {
            if original.isUp {
                try await HelperClient.down(original.iface)
            }
            try await HelperClient.upsert(name: name, config: config)
            if name != original.keyName {
                try await HelperClient.delete(original.keyName)
            }
            if original.isUp {
                await refresh()
                if let updated = tunnels.first(where: { $0.keyName == name }) {
                    try await HelperClient.up(updated.iface)
                }
            }
            lastError = nil
            showEditor = false
            await refresh()
            selectedID = tunnels.first { $0.keyName == name }?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ tunnel: Tunnel) async {
        busyIDs.insert(tunnel.id)
        defer { busyIDs.remove(tunnel.id) }
        do {
            try await HelperClient.delete(tunnel.keyName)
            if selectedID == tunnel.id { selectedID = nil }
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var pollInterval: Duration {
        if !helperInstalled || !toolsAvailable { return .seconds(4) }
        return tunnels.contains(where: \.isUp) ? .seconds(1) : .seconds(3)
    }

    private func apply(_ snapshot: HelperSnapshot) {
        toolsAvailable = snapshot.toolsAvailable || Homebrew.hasWireGuardTools
        localToolsAvailable = vpnKind == .wireguard ? toolsAvailable : localToolsAvailable
        helperVersion = snapshot.helperVersion
        wgPath = snapshot.wgPath.isEmpty ? (Homebrew.binary("wg") ?? "") : snapshot.wgPath
        wgQuickPath = snapshot.wgQuickPath.isEmpty ? (Homebrew.binary("wg-quick") ?? "") : snapshot.wgQuickPath
        let now = Date()
        var next: [Tunnel] = []
        for var tunnel in snapshot.tunnels {
            if let runtime = tunnel.runtime, let previous = previousCounters[tunnel.iface] {
                let dt = max(now.timeIntervalSince(previous.at), 0.001)
                let rxDelta = runtime.rx >= previous.rx ? runtime.rx - previous.rx : 0
                let txDelta = runtime.tx >= previous.tx ? runtime.tx - previous.tx : 0
                tunnel.rxRate = Double(rxDelta) / dt
                tunnel.txRate = Double(txDelta) / dt
            }
            if let runtime = tunnel.runtime {
                previousCounters[tunnel.iface] = (runtime.rx, runtime.tx, now)
            } else {
                previousCounters.removeValue(forKey: tunnel.iface)
            }
            next.append(tunnel)
        }
        tunnels = next
        if selectedID == nil || !tunnels.contains(where: { $0.id == selectedID }) {
            selectedID = tunnels.first?.id
        }
        previousCounters = previousCounters.filter { key, _ in tunnels.contains { $0.iface == key } }
    }
}
