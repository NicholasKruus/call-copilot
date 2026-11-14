import AppIntents
import SwiftUI

@main
struct CallCopilotApp: App {
    @StateObject private var copilot = PhoneCopilot.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        IntentHooks.stop = { PhoneCopilot.shared.stop("Stopped from the Lock Screen") }
        LiveActivityController.endLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(copilot)
                .onAppear { copilot.runTestIfAsked() }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { copilot.appBecameActive() } }
    }
}

/// "Start listening" for Siri, Shortcuts, Spotlight and the Action Button. It opens the app, because iOS lets an app
/// start recording only while it's open.
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start listening"
    static let description = IntentDescription("Opens Call Copilot and starts listening.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneCopilot.shared.start()
        return .result()
    }
}

struct CopilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartListeningIntent(),
                    phrases: ["Start \(.applicationName)", "Start listening with \(.applicationName)"],
                    shortTitle: "Start listening", systemImageName: "waveform")
        AppShortcut(intent: StopListeningIntent(),
                    phrases: ["Stop \(.applicationName)"],
                    shortTitle: "Stop listening", systemImageName: "stop.circle")
    }
}
