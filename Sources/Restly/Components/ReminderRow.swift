import SwiftUI

struct ReminderRow: View {
    let type: ReminderType
    let remaining: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: type.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            Text(type.shortTitle)
                .font(.system(size: 14, weight: .medium, design: .rounded))

            Spacer()

            Text(remaining)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch type {
        case .water: Color(red: 0.14, green: 0.55, blue: 0.92)
        case .eyeRest: Color(red: 0.43, green: 0.36, blue: 0.9)
        case .stand: Color(red: 0.14, green: 0.64, blue: 0.48)
        }
    }
}
