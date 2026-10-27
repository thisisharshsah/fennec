import SwiftUI

struct SayField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    private var target: UnitState? { model.store.speechUnit }

    private var canSpeak: Bool {
        guard let target, target.isConnected, model.client.status == .connected else { return false }
        return true
    }

    private var canSend: Bool {
        canSpeak && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "speaker.wave.2.bubble")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Say something out loud", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .onSubmit(send)
                    .disabled(!canSpeak)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Theme.accent : Theme.inactive, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
            .padding(.leading, Theme.Spacing.l)
            .padding(.trailing, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            SecondaryText(footnote)
                .padding(.leading, Theme.Spacing.l)
        }
    }

    private var footnote: String {
        guard let target else { return "No unit can speak right now" }
        guard target.isConnected else { return "\(target.id) is offline" }
        return "Spoken by \(target.id)"
    }

    private func send() {
        guard canSend, let target else { return }
        model.client.send(.speak(text.trimmingCharacters(in: .whitespaces), unit: target.id))
        text = ""
    }
}
