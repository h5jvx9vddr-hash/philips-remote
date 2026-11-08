import SwiftUI

/// Löst beim Berühren sofort aus (wie eine echte Fernbedienung); mit `repeats` wiederholt Dauerdruck.
struct PressBehavior: ViewModifier {
    var repeats: Bool
    let action: () -> Void
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.94 : 1)
            .opacity(pressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        guard repeats else { return }
                        repeater = Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(170))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

struct Pressable<Content: View>: View {
    @Environment(TVStore.self) private var store
    let key: PhilipsKey
    var repeats = false
    @ViewBuilder var content: Content

    var body: some View {
        content.modifier(PressBehavior(repeats: repeats) { store.press(key) })
    }
}

struct KeyFace: View {
    var title: String?
    var symbol: String?
    var height: CGFloat = 50

    var body: some View {
        VStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: title == nil ? 20 : 17, weight: .semibold))
            }
            if let title {
                Text(title)
                    .font(symbol == nil
                          ? .system(size: height >= 60 ? 26 : 15, weight: .semibold)
                          : .system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Standard-Taste: abgerundetes Feld, volle verfügbare Breite.
struct RKey: View {
    let key: PhilipsKey
    var title: String?
    var symbol: String?
    var tint: Color?
    var foreground: Color = .primary
    var height: CGFloat = 50
    var repeats = false

    init(_ key: PhilipsKey, title: String? = nil, symbol: String? = nil, tint: Color? = nil,
         foreground: Color = .primary, height: CGFloat = 50, repeats: Bool = false) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.foreground = foreground
        self.height = height
        self.repeats = repeats
    }

    var body: some View {
        Pressable(key: key, repeats: repeats) {
            KeyFace(title: title, symbol: symbol, height: height)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(tint ?? Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(Text(title ?? symbol ?? ""))
    }
}

struct DPad: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let zone = s * 0.3
            ZStack {
                Circle().fill(Color(.secondarySystemGroupedBackground))
                arrow(.up, "chevron.up", zone).position(x: s / 2, y: s * 0.15)
                arrow(.down, "chevron.down", zone).position(x: s / 2, y: s * 0.85)
                arrow(.left, "chevron.left", zone).position(x: s * 0.15, y: s / 2)
                arrow(.right, "chevron.right", zone).position(x: s * 0.85, y: s / 2)
                Pressable(key: .confirm) {
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Text("OK").font(.title3.weight(.bold)).foregroundStyle(.white))
                }
                .frame(width: s * 0.38, height: s * 0.38)
                .position(x: s / 2, y: s / 2)
                .accessibilityLabel("OK")
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arrow(_ key: PhilipsKey, _ symbol: String, _ size: CGFloat) -> some View {
        Pressable(key: key, repeats: true) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(symbol))
    }
}

/// Wippe für Lautstärke/Programm.
struct Rocker: View {
    let up: PhilipsKey
    let down: PhilipsKey
    let upSymbol: String
    let downSymbol: String
    let label: String
    var value: String?
    var onLabelTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            half(up, upSymbol)
            VStack(spacing: 0) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if let value {
                    Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(.rect)
            .onTapGesture { onLabelTap?() }
            half(down, downSymbol)
        }
        .frame(width: 78)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 39, style: .continuous))
    }

    private func half(_ key: PhilipsKey, _ symbol: String) -> some View {
        Pressable(key: key, repeats: true) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("\(label) \(symbol)"))
    }
}

struct ColorKeys: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([(PhilipsKey.red, Color.red), (.green, .green), (.yellow, .yellow), (.blue, .blue)], id: \.0) { item in
                Pressable(key: item.0) {
                    Capsule().fill(item.1.gradient).frame(height: 30).contentShape(Capsule())
                }
                .accessibilityLabel(Text(item.0.rawValue))
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}
