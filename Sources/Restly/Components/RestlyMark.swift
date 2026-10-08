import AppKit
import SwiftUI

/// 应用图标只从磁盘读一次。
/// 从前这是 `RestlyBrandMark` 的计算属性，每次 SwiftUI 求值 body 都会重新
/// 读 PNG 并解码 —— 菜单栏和设置窗每次重绘都要走一遍主线程磁盘 IO。
enum RestlyAppIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "RestlyIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

struct RestlyBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let appIcon = RestlyAppIcon.image {
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
}
