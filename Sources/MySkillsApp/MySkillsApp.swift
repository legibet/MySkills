import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MySkillsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("MySkills", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    store.load()
                }
        }
        .defaultSize(width: 1040, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Folder…") {
                    store.importLocalFolder()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Reload") {
                    store.load()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        WindowGroup("Skill Reader", id: "reader", for: SkillReaderRequest.self) { $request in
            if let request {
                SkillReaderView(store: store, request: request)
                    .frame(minWidth: 720, minHeight: 560)
            } else {
                Text("No skill selected.")
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
        .defaultSize(width: 880, height: 680)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(store: store)
        }
    }
}
