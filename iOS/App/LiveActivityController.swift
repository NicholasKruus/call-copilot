import ActivityKit
import Foundation

/// Starts, updates and ends the session's Live Activity (Lock Screen and Dynamic Island). If the user has turned
/// Live Activities off for the app, listening works without it.
@MainActor
final class LiveActivityController {
    /// Each update is valid this long. The app refreshes it while it runs, so if the app is killed or suspended the
    /// Lock Screen shows "not running" instead of a listening session that isn't happening.
    static let freshFor: TimeInterval = 150
    private var activity: Activity<CopilotActivityAttributes>?
    private var lastState: CopilotActivityAttributes.ContentState?
    private(set) var lastUpdate = Date.distantPast

    func start(startedAt: Date, state: CopilotActivityAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("live activity: turned off for this app")
            return
        }
        do {
            activity = try Activity.request(attributes: CopilotActivityAttributes(startedAt: startedAt),
                                            content: .init(state: state, staleDate: Date() + Self.freshFor),
                                            pushType: nil)
            lastState = state
            lastUpdate = Date()
        } catch {
            log("live activity: couldn't start: \(error)")
        }
    }

    func update(_ state: CopilotActivityAttributes.ContentState) {
        guard let activity else { return }
        lastState = state
        lastUpdate = Date()
        Task { await activity.update(.init(state: state, staleDate: Date() + Self.freshFor)) }
    }

    /// Called every second; renews the stale date once a minute.
    func keepFresh() {
        guard let lastState, Date().timeIntervalSince(lastUpdate) > 60 else { return }
        update(lastState)
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        lastState = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends any left from an earlier run that didn't stop cleanly.
    static func endLeftovers() {
        for a in Activity<CopilotActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
