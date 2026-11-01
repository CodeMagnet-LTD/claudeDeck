import SwiftUI

/// The sidebar's own text size and row spacing (Settings → Sidebar), apart from the system's.
enum SidebarStyle {
    static let scaleKey = "sidebar.textScale"
    static let densityKey = "sidebar.density"
    /// Steps of 10 %: -4 is 60 %, +6 is 160 %.
    static let range = -4...6

    static func scale(_ step: Int) -> CGFloat { 1 + 0.1 * CGFloat(min(max(step, range.lowerBound), range.upperBound)) }
    /// A row's vertical padding at a density: normal, compact (half), tight (none).
    static func padding(_ base: CGFloat, density: Int) -> CGFloat { density <= 0 ? base : density == 1 ? base / 2 : 0 }

    /// macOS text style sizes (macOS has no Dynamic Type).
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10  // footnote, caption, caption2
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarScale: CGFloat = 1
    @Entry var sidebarDensity = 0
}

private struct SidebarFont: ViewModifier {
    @Environment(\.sidebarScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        var font: Font = scale == 1 ? .system(style).weight(weight)
            : .system(size: SidebarStyle.baseSize(style) * scale, weight: style == .headline && weight == .regular ? .semibold : weight)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}

private struct SidebarRowPadding: ViewModifier {
    @Environment(\.sidebarDensity) private var density
    let base: CGFloat

    func body(content: Content) -> some View {
        content.padding(.vertical, SidebarStyle.padding(base, density: density))
    }
}

extension View {
    /// A text style scaled by the sidebar's text size.
    func sidebarFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, monospacedDigit: Bool = false) -> some View {
        modifier(SidebarFont(style: style, weight: weight, monospacedDigit: monospacedDigit))
    }

    /// A row's vertical padding, less at a tighter sidebar density.
    func sidebarRowPadding(_ base: CGFloat) -> some View {
        modifier(SidebarRowPadding(base: base))
    }

    /// The sidebar's settings, for the list and the rows in it.
    func sidebarStyle(scale step: Int, density: Int) -> some View {
        let scale = SidebarStyle.scale(step)
        return self
            .environment(\.sidebarScale, scale)
            .environment(\.sidebarDensity, density)
            .font(.system(size: SidebarStyle.baseSize(.body) * scale))
    }
}

/// Settings → Sidebar.
struct SidebarSettingsSection: View {
    @AppStorage(SidebarStyle.scaleKey) private var step = 0
    @AppStorage(SidebarStyle.densityKey) private var density = 0

    var body: some View {
        Section("Sidebar") {
            LabeledContent("Text Size") {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(step) }, set: { step = Int($0.rounded()) }),
                           in: Double(SidebarStyle.range.lowerBound)...Double(SidebarStyle.range.upperBound), step: 1)
                        .frame(maxWidth: 220)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    Text("\(Int((SidebarStyle.scale(step) * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                    Button("Default") { step = 0 }.disabled(step == 0)
                }
            }
            Picker("Rows", selection: $density) {
                Text("Normal").tag(0)
                Text("Compact").tag(1)
                Text("Tight").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }
}
