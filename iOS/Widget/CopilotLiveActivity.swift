import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct CopilotWidgets: WidgetBundle {
    var body: some Widget { CopilotLiveActivity() }
}

/// The newest card on the Lock Screen and in the Dynamic Island while Call Copilot listens, with a Stop button.
struct CopilotLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CopilotActivityAttributes.self) { context in
            LockScreenView(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusLabel(state: context.state).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.cardCount) cards").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        CardSummary(state: context.state, lines: 3)
                        StopButton()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.listening ? "waveform" : "pause.fill")
                    .foregroundStyle(context.state.listening ? Palette.green : Palette.amber)
            } compactTrailing: {
                Text("\(context.state.cardCount)").font(.caption.monospacedDigit().bold())
                    .foregroundStyle(context.state.cardCount > 0 ? Palette.watcher(context.state.colorIndex) : .secondary)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(context.state.listening ? Palette.green : Palette.amber)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: CopilotActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusLabel(state: state)
                Spacer()
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            CardSummary(state: state, lines: 3)
            HStack {
                Text("\(state.cardCount) card\(state.cardCount == 1 ? "" : "s")")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                StopButton()
            }
        }
        .padding(14)
    }
}

private struct StatusLabel: View {
    let state: CopilotActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(state.listening ? Palette.green : Palette.amber).frame(width: 6, height: 6)
            Text(state.status.uppercased()).font(.caption2.monospaced().weight(.semibold)).lineLimit(1)
        }
    }
}

private struct CardSummary: View {
    let state: CopilotActivityAttributes.ContentState
    let lines: Int
    var body: some View {
        if let title = state.title {
            VStack(alignment: .leading, spacing: 3) {
                if let w = state.watcher {
                    HStack(spacing: 5) {
                        Rectangle().fill(Palette.watcher(state.colorIndex)).frame(width: 5, height: 5)
                        Text(w.uppercased()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(title).font(.subheadline.weight(.heavy)).lineLimit(2)
                if let body = state.body, !body.isEmpty {
                    Text(body).font(.caption).lineLimit(lines).foregroundStyle(.primary.opacity(0.85))
                }
            }
        } else {
            Text("Cards appear here as the conversation gives a reason.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopListeningIntent()) {
            Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
        }
        .tint(Palette.red)
    }
}
