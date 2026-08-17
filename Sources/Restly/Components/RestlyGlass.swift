import SwiftUI

extension View {
    @ViewBuilder
    func restlyGlassSurface(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    func restlyClearGlassSurface(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                tint.map { Glass.clear.tint($0) } ?? .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    func restlyWindowGlass(cornerRadius: CGFloat = 24) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .containerBackground(.clear, for: .window)
            .background(.clear)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.38), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
        } else if #available(macOS 15.0, *) {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .containerBackground(.clear, for: .window)
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func restlyGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
    }
}
