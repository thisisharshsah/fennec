import SwiftUI

struct CreatureFace: View {
    let state: BodyState

    private let cream = Color(red: 0.98, green: 0.93, blue: 0.82)
    private let creamShade = Color(red: 0.86, green: 0.78, blue: 0.64)
    private let ink = Color(red: 0.16, green: 0.13, blue: 0.12)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let head = size * 0.56
            let cheek = Color(hex: state.cheekHex)
            ZStack {
                tail(length: head * 0.42)
                    .offset(y: head * 0.55)
                headGroup(head: head, cheek: cheek)
                    .offset(x: state.pan * head / 180, y: -state.tilt * head / 180)
                    .rotationEffect(.degrees(state.pan * 0.08))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: state)
        .accessibilityLabel("Creature face, mood \(state.mood)")
    }

    private func headGroup(head: CGFloat, cheek: Color) -> some View {
        ZStack {
            ear(angle: state.earLeft, mirrored: false, head: head)
                .offset(x: -head * 0.34, y: -head * 0.42)
            ear(angle: state.earRight, mirrored: true, head: head)
                .offset(x: head * 0.34, y: -head * 0.42)
            Circle()
                .fill(cream.gradient)
                .overlay(Circle().strokeBorder(creamShade, lineWidth: 2))
                .frame(width: head, height: head)
            eyes(head: head)
            cheekLight(cheek, size: head * 0.2)
                .offset(x: -head * 0.3, y: head * 0.12)
            cheekLight(cheek, size: head * 0.2)
                .offset(x: head * 0.3, y: head * 0.12)
            Circle()
                .fill(ink)
                .frame(width: head * 0.07, height: head * 0.07)
                .offset(y: head * 0.1)
        }
    }

    private func ear(angle: Double, mirrored: Bool, head: CGFloat) -> some View {
        let direction: Double = mirrored ? -1 : 1
        let rest: Double = mirrored ? 18 : -18
        return RoundedRectangle(cornerRadius: head * 0.16, style: .continuous)
            .fill(cream.gradient)
            .overlay(RoundedRectangle(cornerRadius: head * 0.16, style: .continuous).strokeBorder(creamShade, lineWidth: 2))
            .frame(width: head * 0.3, height: head * 0.58)
            .rotationEffect(.degrees(rest - angle * direction), anchor: .bottom)
    }

    private func eyes(head: CGFloat) -> some View {
        let sleepy = state.mood == "sleepy"
        let wide = state.mood == "surprised" || state.mood == "alert"
        return HStack(spacing: head * 0.26) {
            ForEach(0..<2, id: \.self) { _ in
                Ellipse()
                    .fill(ink)
                    .frame(width: head * (wide ? 0.13 : 0.1), height: head * (wide ? 0.17 : 0.13))
                    .scaleEffect(y: sleepy ? 0.18 : 1, anchor: .center)
            }
        }
        .offset(y: -head * 0.08)
    }

    private func cheekLight(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(color).blur(radius: size * 0.6).opacity(0.7))
            .shadow(color: color.opacity(0.6), radius: size * 0.4)
    }

    private func tail(length: CGFloat) -> some View {
        Capsule()
            .fill(creamShade.gradient)
            .frame(width: length * 0.28, height: length)
            .rotationEffect(.degrees(180 + state.tail), anchor: .top)
            .offset(y: -length / 2)
    }
}
