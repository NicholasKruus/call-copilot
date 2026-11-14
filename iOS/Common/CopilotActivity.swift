import ActivityKit
import AppIntents
import SwiftUI

/// The Lock Screen and Dynamic Island view of a listening session (a Live Activity). Shared by the app, which starts
/// and updates it, and the widget extension, which draws it.
struct CopilotActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Listening", or why it's paused.
        var status: String
        var listening: Bool
        var cardCount: Int
        /// The newest card.
        var watcher: String?
        var colorIndex: Int
        var title: String?
        var body: String?
    }

    var startedAt: Date
}

/// "Stop" on the Live Activity, and the "Stop listening" shortcut. A LiveActivityIntent runs in the app's process,
/// where the app sets `IntentHooks.stop`; the widget extension only shows the button.
struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop listening"
    static let description = IntentDescription("Stops Call Copilot listening.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { IntentHooks.stop?() }
        return .result()
    }
}

enum IntentHooks {
    @MainActor static var stop: (() -> Void)?
}

/// The colours of the AI Automations database's look, shared with the widget.
enum Palette {
    static let accent = Color(red: 0, green: 0x7F / 255, blue: 1)
    static let amber = Color(red: 0xE9 / 255, green: 0xB8 / 255, blue: 0x0F / 255)
    static let green = Color(red: 0x3F / 255, green: 0xCF / 255, blue: 0x86 / 255)
    static let purple = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    static let red = Color(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x36 / 255)
    /// One colour per watcher, in settings order.
    static let watchers = [accent, amber, green, purple, red]

    static func watcher(_ index: Int) -> Color { watchers[((index % watchers.count) + watchers.count) % watchers.count] }
}
