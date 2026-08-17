import AppKit
import SwiftUI

struct RestlyBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        LinearGradient(
                            colors: [.teal, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.teal.opacity(0.2), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "RestlyIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
