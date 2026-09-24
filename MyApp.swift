import SwiftUI

@main
struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("wireguard-muti", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 920, height: 600)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tunnel…") {
                    model.showNewTunnel = true
                }
                .keyboardShortcut("n")
                .disabled(model.vpnKind != .wireguard)
                Button("Import Config…") {
                    NotificationCenter.default.post(name: .importTunnel, object: nil)
                }
                .keyboardShortcut("i")
                .disabled(model.vpnKind != .wireguard)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await model.refresh(interactive: true) }
                }
                .keyboardShortcut("r")
                .disabled(model.vpnKind != .wireguard)
                Button("Connect All") {
                    Task { await model.connectAll() }
                }
                .disabled(model.vpnKind != .wireguard)
                Button("Disconnect All") {
                    Task { await model.disconnectAll() }
                }
                .disabled(model.vpnKind != .wireguard)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Label("wireguard-muti", image: "MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

extension Notification.Name {
    static let importTunnel = Notification.Name("WGMulti.importTunnel")
}
