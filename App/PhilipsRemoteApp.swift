import SwiftUI

@main
struct PhilipsRemoteApp: App {
    @State private var store = TVStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.tv == nil { SetupView() } else { MainView() }
            }
            .environment(store)
            .onChange(of: phase, initial: true) { _, p in
                if p == .active { store.startPolling() } else { store.stopPolling() }
            }
        }
    }
}

enum AppTab: String {
    case remote, digits, media, settings
}

struct MainView: View {
    @Environment(TVStore.self) private var store
    // "-tab media" als Startargument landet automatisch in den UserDefaults (Screenshots)
    @State private var tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .remote

    var body: some View {
        TabView(selection: $tab) {
            Tab("Fernbedienung", systemImage: "av.remote", value: .remote) {
                Page { RemotePad() }
            }
            Tab("Ziffern", systemImage: "circle.grid.3x3", value: .digits) {
                Page { DigitsPad() }
            }
            Tab("Wiedergabe", systemImage: "play.rectangle", value: .media) {
                Page { MediaPad() }
            }
            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 96) }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}

/// Gemeinsamer Rahmen der Tasten-Seiten: Titel mit Status, Ein/Aus oben rechts.
struct Page<Content: View>: View {
    @Environment(TVStore.self) private var store
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TVTitle() }
            }
        }
    }
}

struct TVTitle: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        VStack(spacing: 1) {
            Text(store.tv?.info.name ?? "Fernseher")
                .font(.headline)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(store.statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        if store.waking || store.searching || store.unauthorized { return .orange }
        switch store.online {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }
}

struct ToastView: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        if let text = store.toast {
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(in: .rect(cornerRadius: 20))
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { store.toast = nil }
        }
    }
}
