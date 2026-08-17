import SwiftUI

struct ReminderOverlayView: View {
    @ObservedObject var session: EyeRestSession

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topLabel

                Spacer(minLength: 32)

                VStack(spacing: 26) {
                    Text("把目光从屏幕移开")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .tracking(-1)

                    Text("望向窗外，或者轻轻闭上眼睛\n让视线真正休息一会儿")
                        .font(.system(size: 19, weight: .regular, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineSpacing(7)

                    countdown
                        .padding(.vertical, 12)

                    actions
                }

                Spacer(minLength: 32)

                Text("Restly 会在倒计时结束后自动返回")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.vertical, 44)
            .padding(.horizontal, 32)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.035, green: 0.055, blue: 0.11)
                .opacity(0.88)

            RadialGradient(
                colors: [
                    Color(red: 0.18, green: 0.42, blue: 0.72).opacity(0.48),
                    .clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 720
            )

            RadialGradient(
                colors: [
                    Color(red: 0.33, green: 0.24, blue: 0.62).opacity(0.32),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 680
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var topLabel: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: .semibold))
            Text("RESTLY · 眼睛休息")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(1.3)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var countdown: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: 7)

            Circle()
                .trim(from: 0, to: session.progress)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.42, green: 0.78, blue: 1),
                            Color(red: 0.65, green: 0.55, blue: 1),
                            Color(red: 0.42, green: 0.78, blue: 1)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: session.progress)

            VStack(spacing: 2) {
                Text("\(session.remainingSeconds)")
                    .font(.system(size: 72, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("秒")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("剩余 \(session.remainingSeconds) 秒")
        }
        .frame(width: 220, height: 220)
        .shadow(color: Color.blue.opacity(0.18), radius: 36)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("跳过") {
                session.skip()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(RestlyOverlayButtonStyle(isProminent: false))

            Button("10 分钟后提醒") {
                session.snooze()
            }
            .buttonStyle(RestlyOverlayButtonStyle(isProminent: true))
        }
    }
}

private struct RestlyOverlayButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundStyle(isProminent ? Color(red: 0.06, green: 0.08, blue: 0.14) : .white.opacity(0.82))
            .background(
                isProminent ? .white.opacity(configuration.isPressed ? 0.72 : 0.92) : .white.opacity(configuration.isPressed ? 0.14 : 0.08),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.white.opacity(isProminent ? 0 : 0.12), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
