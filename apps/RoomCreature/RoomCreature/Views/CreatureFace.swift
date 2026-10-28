import SwiftUI

/// A live creature bot in large views, with a lightweight portrait in lists.
struct CreatureFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let state: BodyState
    var animates = true

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Group {
                if side < 100 {
                    portrait(side: side)
                } else {
                    FennecModelView(
                        state: state,
                        animates: animates && !reduceMotion && scenePhase == .active
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fennec, feeling \(state.mood)")
    }

    private func portrait(side: CGFloat) -> some View {
        Image("CreatureBotPortrait")
            .resizable()
            .scaledToFit()
            .frame(width: side * 1.38, height: side * 1.38)
            .offset(y: side * 0.15)
            .rotationEffect(.degrees(reduceMotion || !state.pan.isFinite ? 0 : min(5, max(-5, state.pan * 0.08))))
            .frame(width: side, height: side)
            .clipped()
            .animation(reduceMotion || !animates ? nil : .easeInOut(duration: 0.25), value: state.pan)
    }
}
