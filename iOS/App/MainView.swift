import SwiftUI
import UIKit

struct MainView: View {
    @EnvironmentObject private var copilot: PhoneCopilot
    @State private var showSettings = false
    @State private var query = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Hairline()
                header
                Hairline()
                ForEach(problems, id: \.self) { note in
                    Text(note).font(K.sans(13)).foregroundStyle(K.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    Hairline()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if copilot.cards.isEmpty { empty }
                        ForEach(copilot.cards) { card in
                            CardRow(card: card)
                            Hairline()
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                if copilot.asking || copilot.answer != nil {
                    Hairline()
                    answer
                }
                Hairline()
                askBar
            }
            .background(K.paper)
            .toolbar {
                ToolbarItem(placement: .principal) { MonoLabel(text: "Call Copilot", size: 12, bullet: K.ink) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(K.ink)
                        .accessibilityLabel("Settings")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings, onDismiss: { copilot.refreshKey() }) { SettingsView() }
            .onAppear { if Config.isTestRun && ProcessInfo.processInfo.arguments.contains("--test-settings") { showSettings = true } }
            .sensoryFeedback(.success, trigger: copilot.cards.count) { old, new in new > old }
        }
    }

    private var problems: [String] {
        var out = copilot.notes
        if let t = copilot.turnNote { out.append(t) }
        if case .failed(let why) = copilot.phase { out.append(why) }
        return out
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(dotColor).frame(width: 8, height: 8)
                Text(copilot.statusText.uppercased()).font(K.mono(12, bold: true)).tracking(0.6)
                    .foregroundStyle(K.ink).lineLimit(2)
                Spacer(minLength: 8)
                if copilot.isListening, let start = copilot.startedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(K.mono(12)).monospacedDigit().foregroundStyle(K.muted)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if copilot.isListening {
                Button("Stop") { copilot.toggle() }.buttonStyle(KButton(filled: true, tint: K.ink, wide: true))
            } else {
                Button(copilot.hasKey ? "Listen" : "Add your API key") {
                    if copilot.hasKey { copilot.toggle() } else { showSettings = true }
                }
                .buttonStyle(KButton(filled: true, wide: true))
            }
            HStack(spacing: 12) {
                if copilot.isListening {
                    HStack(spacing: 5) {
                        Rectangle().fill(copilot.micActive ? K.green : K.line).frame(width: 7, height: 7)
                        Text("MIC").font(K.mono(10.5)).tracking(0.5).foregroundStyle(K.muted)
                    }
                }
                if let cost = copilot.cost {
                    Text(String(format: "≈ $%.2f", cost)).font(K.mono(10.5)).foregroundStyle(K.muted)
                        .accessibilityLabel(String(format: "About %.2f dollars so far", cost))
                }
                Spacer(minLength: 8)
                if !copilot.watchStatus.isEmpty {
                    Text(copilot.watchStatus.uppercased()).font(K.mono(10.5)).tracking(0.5)
                        .foregroundStyle(K.muted).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            if copilot.isListening {
                Text("Cards from your watchers appear here as the conversation gives them a reason. They also show on the Lock Screen.")
            } else if !copilot.hasKey {
                Text("Call Copilot listens to a meeting through this iPhone's microphone and shows what your watchers ask for: evidence for claims, tools that fit a task, or anything you describe.")
                Text("It uses your own Anthropic API key. Add one in Settings to start.")
            } else {
                Text("Press Listen when a meeting starts, or say “Start Call Copilot” to Siri. It hears everyone in the room, or a call on a nearby speaker.")
                Text("Tell the people you're meeting that it's running.")
            }
        }
        .font(K.sans(14)).foregroundStyle(K.muted)
        .padding(16)
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MonoLabel(text: copilot.asking ? "Asking…" : "Answer", size: 10.5, color: K.accentInk, bullet: K.accent)
                Spacer()
                if let a = copilot.answer {
                    Button("Copy") { UIPasteboard.general.string = a }.font(K.mono(11)).tint(K.accentInk)
                    Button("Clear") { copilot.answer = nil }.font(K.mono(11)).tint(K.accentInk).padding(.leading, 8)
                }
            }
            if let a = copilot.answer {
                ScrollView {
                    Text(a).font(K.sans(15)).foregroundStyle(K.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(K.accentTint)
        .overlay(alignment: .leading) { Rectangle().fill(K.accent).frame(width: 3) }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            Text(">").font(K.mono(16, bold: true)).foregroundStyle(K.accent)
            TextField("", text: $query, prompt: Text("ASK ABOUT THIS MEETING").font(K.mono(12)).foregroundStyle(K.muted))
                .font(K.sans(16))
                .focused($askFocused)
                .submitLabel(.send)
                .onSubmit(send)
            if !query.isEmpty {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)) }
                    .tint(K.accent)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private func send() {
        copilot.ask(query)
        query = ""
        askFocused = false
    }

    private var dotColor: Color {
        switch copilot.phase {
        case .listening: return K.green
        case .starting, .paused: return K.amber
        case .failed: return K.red
        default: return K.line
        }
    }
}

struct CardRow: View {
    let card: Card
    @Environment(\.openURL) private var openURL

    private var color: Color { Palette.watcher(card.watcherIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel(text: card.watcher, size: 10.5, color: K.muted, bullet: color)
            Text(card.title.uppercased()).font(K.display(18)).tracking(-0.3).foregroundStyle(K.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !card.body.isEmpty {
                Text(card.body).font(K.sans(15, weight: .medium)).foregroundStyle(K.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            }
            if !card.quote.isEmpty {
                Text("“\(card.quote)”").font(K.sans(14)).foregroundStyle(K.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.links.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { links }
                    VStack(alignment: .leading, spacing: 6) { links }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") { UIPasteboard.general.string = "\(card.title)\n\(card.body)\n" + card.links.map(\.absoluteString).joined(separator: "\n") }
            if let u = card.links.first { Button("Open \(u.host ?? "link")") { openURL(u) } }
        }
    }

    @ViewBuilder private var links: some View {
        ForEach(card.links, id: \.self) { url in
            Link(destination: url) {
                Text(((url.host ?? "link").replacingOccurrences(of: "www.", with: "") + " ↗").uppercased())
                    .font(K.mono(11)).tracking(0.4).foregroundStyle(K.accentInk).underline()
                    .frame(minHeight: 28)
            }
        }
    }
}
