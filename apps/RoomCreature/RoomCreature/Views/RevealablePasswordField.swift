import SwiftUI

/// A password field with an eye button to show or hide the text and a paste button,
/// focused as soon as it appears so the keyboard is up straight away.
struct RevealablePasswordField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @State private var isRevealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Group {
                if isRevealed {
                    TextField("Password", text: $text)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                    #endif
                } else {
                    SecureField("Password", text: $text)
                    #if os(iOS)
                        .textContentType(.password)
                    #endif
                }
            }
            .focused($focused)
            .onSubmit(onSubmit)
            .submitLabel(.join)

            if text.isEmpty {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first {
                        text = first.trimmingCharacters(in: .newlines)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Paste password")
            }

            Button {
                isRevealed.toggle()
                focused = true
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))   // after the step transition
                focused = true
            }
        }
    }
}
