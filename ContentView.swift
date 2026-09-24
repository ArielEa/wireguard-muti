import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var importPanel = false
    @State private var pendingDelete: Tunnel?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            tunnelList
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let tunnel = model.selectedTunnel {
                TunnelDetailView(tunnel: tunnel, pendingDelete: $pendingDelete)
            } else {
                emptyDetail
            }
        }
        .navigationTitle("wireguard-muti")
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.hasDefaultRouteOverlap {
                banner(
                    "Two connected tunnels both claim 0.0.0.0/0. Traffic may only follow one default route.",
                    tint: .orange
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBanners
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "this tunnel")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let tunnel = pendingDelete {
                    Task { await model.delete(tunnel) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The config and key files will be removed from \(WireGuardPaths.keysDirectory).")
        }
        .sheet(isPresented: $model.showNewTunnel) {
            NewTunnelSheet()
        }
        .sheet(isPresented: $model.showEditor) {
            if let tunnel = model.editingTunnel {
                TunnelEditorView(tunnel: tunnel)
            }
        }
        .fileImporter(
            isPresented: $importPanel,
            allowedContentTypes: confTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importTunnel)) { _ in
            importPanel = true
        }
    }

    private var confTypes: [UTType] {
        [UTType(filenameExtension: "conf") ?? .plainText, .plainText, .item]
    }

    private var tunnelList: some View {
        List {
            Section("Tunnels") {
                if model.tunnels.isEmpty {
                    ContentUnavailableView(
                        "No keys yet",
                        systemImage: "network.slash",
                        description: Text("Keys are stored in /opt/homebrew/etc/wireguard, same as wgshell. Generate, import, or drop a .conf here.")
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(model.tunnels) { tunnel in
                        TunnelRow(tunnel: tunnel)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = tunnel.id }
                            .listRowBackground(sidebarRowBackground(selected: model.selectedID == tunnel.id))
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .contextMenu {
                                Button(model.isEnabled(tunnel) ? "Disconnect" : "Connect") {
                                    Task { await model.setConnected(tunnel, !model.isEnabled(tunnel)) }
                                }
                                Button("Edit") {
                                    model.editingTunnel = tunnel
                                    model.showEditor = true
                                }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    pendingDelete = tunnel
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Color.accentColor)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(WireGuardPaths.keysDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: WireGuardPaths.keysDirectory))
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private func sidebarRowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.10) : Color.clear)
            .padding(.horizontal, 4)
    }

    private var emptyDetail: some View {
        ContentUnavailableView(
            "wireguard-muti",
            systemImage: "lock.shield",
            description: Text("Keys live in /opt/homebrew/etc/wireguard. Each key can be connected on its own, and several can be up together.")
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.connectAll() }
            } label: {
                Label("Connect All", systemImage: "play.fill")
            }
            .help("Bring every tunnel up")
            .disabled(model.tunnels.allSatisfy(\.isUp) || model.tunnels.isEmpty)

            Button {
                Task { await model.disconnectAll() }
            } label: {
                Label("Disconnect All", systemImage: "stop.fill")
            }
            .help("Take every tunnel down")
            .disabled(model.connectedCount == 0)

            Button {
                importPanel = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Button {
                model.showNewTunnel = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if model.needsHelperUpdate {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app")
                Text("Update the helper to read every key in /opt/homebrew/etc/wireguard.")
                    .font(.callout)
                Spacer()
                Button(model.isInstallingHelper ? "Updating…" : "Update Helper") {
                    Task { await model.installHelper() }
                }
                .disabled(model.isInstallingHelper)
            }
            .padding(10)
            .foregroundStyle(Color(nsColor: .labelColor))
            .background(Color.yellow.opacity(0.35))
        } else if !model.toolsAvailable && model.helperInstalled {
            banner("WireGuard tools were not found. Install with: brew install wireguard-tools", tint: .red)
        } else if !model.helperInstalled {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                Text("Install a one-time administrator helper so tunnels can start and stop without a password each time.")
                    .font(.callout)
                Spacer()
                Button(model.isInstallingHelper ? "Installing…" : "Install Helper") {
                    Task { await model.installHelper() }
                }
                .disabled(model.isInstallingHelper)
            }
            .padding(10)
            .foregroundStyle(Color(nsColor: .labelColor))
            .background(Color.yellow.opacity(0.35))
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(10)
        .background(tint.opacity(0.22))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.lastError = error.localizedDescription
        case .success(let urls):
            Task { await importURLs(urls) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    DispatchQueue.main.async { model.lastError = error.localizedDescription }
                    return
                }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    await importURLs([url])
                }
            }
        }
        return true
    }

    private func importURLs(_ urls: [URL]) async {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: " ", with: "-")
                await model.importConfig(name: sanitizedName(name), text: text)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    private func sanitizedName(_ raw: String) -> String {
        let kept = raw.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return kept.isEmpty ? "imported" : kept
    }
}

struct TunnelRow: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isEnabled(tunnel) ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.displayName)
                    .font(.headline)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle(
                "Connected",
                isOn: model.connectionBinding(for: tunnel)
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(Color.accentColor)
            .help(model.isEnabled(tunnel) ? "Disconnect this tunnel" : "Start this tunnel")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var subtitle: String {
        if model.isEnabled(tunnel) {
            let live = tunnel.runtime?.liveInterface ?? tunnel.iface
            return "\(live) · \(ByteFormat.rate(tunnel.rxRate)) down"
        }
        if !tunnel.config.isComplete {
            return "\(tunnel.iface) · no address/peer"
        }
        return "\(tunnel.iface) · disconnected"
    }
}
