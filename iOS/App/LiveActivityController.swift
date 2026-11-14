import ActivityKit
import Foundation

/// Starts, updates and ends the session's Live Activity (Lock Screen and Dynamic Island). If the user has turned
/// Live Activities off for the app, listening works without it.
@MainActor
final class LiveActivityController {
    private var activity: Activity<CopilotActivityAttributes>?

    func start(startedAt: Date, state: CopilotActivityAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("live activity: turned off for this app")
            return
        }
        do {
            activity = try Activity.request(attributes: CopilotActivityAttributes(startedAt: startedAt),
                                            content: .init(state: state, staleDate: nil), pushType: nil)
        } catch {
            log("live activity: couldn't start: \(error)")
        }
    }

    func update(_ state: CopilotActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends any left from an earlier run that didn't stop cleanly.
    static func endLeftovers() {
        for a in Activity<CopilotActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
