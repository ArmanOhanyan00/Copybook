import SwiftUI

/// Copybook's own push button: a soft capsule with hover, press and disabled states.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, destructive }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, kind: kind)
    }

    private struct CapsuleBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
                .shadow(color: .black.opacity(kind == .prominent ? 0.18 : 0.06), radius: kind == .prominent ? 6 : 2, y: 1)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 && enabled }
                .animation(PanelStyle.quick, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var foreground: Color {
            switch kind {
            case .normal: return PanelStyle.label
            case .prominent: return .white
            case .destructive: return Color(nsColor: .systemRed)
            }
        }

        private var fill: AnyShapeStyle {
            switch kind {
            case .normal:
                return AnyShapeStyle(PanelStyle.cardBackground.opacity(hovering ? 1 : 0.85))
            case .prominent:
                return AnyShapeStyle(PanelStyle.accent.gradient.opacity(configuration.isPressed ? 0.85 : (hovering ? 0.95 : 1)))
            case .destructive:
                return AnyShapeStyle(Color(nsColor: .systemRed).opacity(configuration.isPressed ? 0.2 : (hovering ? 0.15 : 0.1)))
            }
        }

        private var border: Color {
            kind == .normal ? PanelStyle.hairline.opacity(2) : .clear
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsuleProminent: CapsuleButtonStyle { CapsuleButtonStyle(kind: .prominent) }
    static var capsuleDestructive: CapsuleButtonStyle { CapsuleButtonStyle(kind: .destructive) }
}

/// Copybook's own segmented control: a soft track with a white pill that slides on a spring.
struct PillSegmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (label, value) = options[i]
                let on = value == selection
                Text(label)
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? PanelStyle.label : PanelStyle.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if on {
                            Capsule()
                                .fill(PanelStyle.cardBackground)
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "segment", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(PanelStyle.spring) { selection = value } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { selection = value }
            }
        }
        .padding(3)
        .background(Capsule().fill(PanelStyle.pill))
        .fixedSize()
    }
}

/// The same segmented control with an SF Symbol in each segment (and, optionally, its name).
struct PillIconSegmented<Value: Hashable>: View {
    let options: [(symbol: String, title: String, value: Value)]
    var showTitles = false
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                HStack(spacing: 6) {
                    Image(systemName: option.symbol)
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                    if showTitles {
                        Text(option.title).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    }
                }
                .foregroundStyle(on ? PanelStyle.label : PanelStyle.secondary)
                .padding(.horizontal, showTitles ? 13 : 12)
                .frame(minWidth: showTitles ? 0 : 38, minHeight: 28)
                .background {
                    if on {
                        Capsule()
                            .fill(PanelStyle.cardBackground)
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "segment", in: ns)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture { withAnimation(PanelStyle.spring) { selection = option.value } }
                .help(option.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { selection = option.value }
            }
        }
        .padding(3)
        .background(Capsule().fill(PanelStyle.pill))
        .fixedSize()
    }
}
