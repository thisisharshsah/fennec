import SwiftUI

/// The live conversation beside the 3D creature: the latest messages and thoughts, what is happening
/// right now (listening, thinking, talking), a voice button for hands-free talk and a text field.
struct LiveTalkPanel: View {
    @Environment(AppModel.self) private var model
    let unitID: String
    let name: String
    var height: CGFloat = 250
    @State private var text = ""
    @FocusState private var isTyping: Bool

    private static let endID = "live.end"
    /// A reply this long after the owner's message counts as still coming.
    private static let replyWaitS: TimeInterval = 45

    private var recent: [CreatureMessage] {
        Array(model.store.messages.messages(for: unitID).suffix(8))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            if recent.isEmpty {
                                SecondaryText("Say hello to \(name).", font: Theme.Text.callout)
                                    .padding(.top, Theme.Spacing.s)
                            }
                            ForEach(recent) { message in
                                MiniBubble(message: message)
                            }
                            Color.clear.frame(height: 1).id(Self.endID)
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: recent.last?.id) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.endID, anchor: .bottom) }
                    }
                }
                statusLine(at: context.date)
                controls
            }
        }
        .padding(Theme.Spacing.m)
        .frame(height: height)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .onDisappear {
            #if os(iOS)
            if model.companion.unitID == unitID { model.companion.stop() }
            #endif
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StatusDot(color: model.isHubConnected ? Theme.positive : Theme.inactive, size: 6)
            Text("Talk")
                .font(Theme.Text.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if let brain = model.store.brain, !(brain.hasKey ?? false) {      // known to be off, not just unknown
                SecondaryText("can't answer yet")
            }
        }
    }

    /// One line on what is happening right now, empty when nothing is.
    @ViewBuilder
    private func statusLine(at now: Date) -> some View {
        if let status = status(at: now) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: status.symbol)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(status.tint)
                Text(status.text)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            .transition(.opacity)
        }
    }

    private func status(at now: Date) -> (text: String, symbol: String, tint: Color)? {
        #if os(iOS)
        if model.companion.isOn && model.companion.unitID == unitID {
            switch model.companion.phase {
            case .listening:
                let heard = model.listener.transcript
                return (heard.isEmpty ? "Listening…" : heard, "waveform", Theme.negative)
            case .waiting: return ("\(name) is thinking…", "ellipsis", Theme.MoodColor.color(for: .curious))
            case .speaking: return ("\(name) is talking…", "speaker.wave.2.fill", Theme.accent)
            case .off: break
            }
        }
        #endif
        let said = recent.last { !$0.isThought }
        if let said, !said.isFromCreature, model.store.brain?.hasKey ?? true,
           now.timeIntervalSince(said.time) < Self.replyWaitS {
            return ("\(name) is thinking…", "ellipsis", Theme.MoodColor.color(for: .curious))
        }
        return nil
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            #if os(iOS)
            voiceButton
            #endif
            TextField("Message", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Text.callout)
                .focused($isTyping)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.surfaceElevated, in: Capsule())
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
            }
        }
        .disabled(!model.isHubConnected)
    }

    #if os(iOS)
    /// Starts or stops the hands-free conversation.
    private var voiceButton: some View {
        let on = model.companion.isOn && model.companion.unitID == unitID
        return Button {
            Haptics.light()
            if on { model.companion.stop() } else { isTyping = false; model.companion.start(unit: unitID) }
        } label: {
            Image(systemName: on ? "stop.fill" : "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(on ? Theme.negative : Theme.MoodColor.color(for: .curious), in: Circle())
                .symbolEffect(.variableColor.iterative, isActive: on && model.companion.phase == .listening)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop talking with \(name)" : "Talk with \(name) by voice")
    }
    #endif

    private func send() {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        Haptics.light()
        model.sendMessage(said, to: unitID)
        text = ""
    }
}

/// A small bubble for the live panel: the owner's on the right, the creature's on the left, thoughts
/// quieter and dashed.
private struct MiniBubble: View {
    let message: CreatureMessage

    var body: some View {
        let mine = !message.isFromCreature
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        HStack {
            if mine { Spacer(minLength: Theme.Spacing.l) }
            Text(message.text)
                .font(message.isThought ? Theme.Text.caption.italic() : Theme.Text.callout)
                .foregroundStyle(mine ? Theme.onAccent : message.isThought ? Theme.textSecondary : Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.s + 2)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .background {
                    if mine {
                        shape.fill(Theme.accent)
                    } else if message.isThought {
                        shape.strokeBorder(Theme.MoodColor.color(for: .curious).opacity(0.5),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    } else {
                        shape.fill(Theme.surfaceElevated)
                    }
                }
                .opacity(message.delivery == .sending ? 0.6 : 1)
            if !mine { Spacer(minLength: Theme.Spacing.l) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : message.isThought ? "Thought" : "Crawl"): \(message.text)")
    }
}
