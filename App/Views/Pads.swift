import SwiftUI

struct RemotePad: View {
    @Environment(TVStore.self) private var store
    @State private var volumeSheet = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                RKey(.standby, symbol: "power", tint: .red, foreground: .white)
                RKey(.source, title: "Quelle")
                RKey(.watchTV, title: "TV")
                RKey(.home, title: "Home", symbol: "house")
            }
            HStack(spacing: 12) {
                RKey(.options, title: "Optionen", height: 44)
                RKey(.info, symbol: "info.circle", height: 44)
                RKey(.adjust, title: "Bild/Ton", height: 44)
            }
            DPad()
                .frame(maxWidth: 230)
            HStack(spacing: 12) {
                RKey(.back, title: "Zurück", symbol: "arrow.uturn.backward", height: 44)
                RKey(.find, title: "Guide", height: 44)
                RKey(.online, title: "Smart TV", height: 44)
            }
            HStack(spacing: 14) {
                Rocker(up: .volumeUp, down: .volumeDown, upSymbol: "plus", downSymbol: "minus",
                       label: "VOL", value: store.volume.map { String($0.current) }) { volumeSheet = true }
                VStack(spacing: 10) {
                    let muted = store.volume?.muted == true
                    RKey(.mute, symbol: muted ? "speaker.slash.fill" : "speaker.slash",
                         foreground: muted ? .red : .primary, height: 46)
                    RKey(.ambilight, title: "Ambilight", symbol: "rays", height: 46)
                    RKey(.playPause, symbol: "playpause.fill", height: 46)
                }
                Rocker(up: .channelUp, down: .channelDown, upSymbol: "chevron.up", downSymbol: "chevron.down", label: "P")
            }
            .frame(height: 158)
            ColorKeys()
        }
        .sheet(isPresented: $volumeSheet) {
            VolumeSheet().presentationDetents([.height(230)])
        }
    }
}

struct VolumeSheet: View {
    @Environment(TVStore.self) private var store
    @State private var value: Double = 0

    var body: some View {
        let range = Double(store.volume?.min ?? 0)...Double(max(store.volume?.max ?? 60, (store.volume?.min ?? 0) + 1))
        VStack(spacing: 14) {
            Text("Lautstärke").font(.headline)
            Text("\(Int(value))")
                .font(.system(size: 46, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            HStack(spacing: 14) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $value, in: range, step: 1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .onAppear { value = Double(store.volume?.current ?? 0) }
        .onChange(of: value) { _, v in store.setVolume(Int(v)) }
    }
}

struct DigitsPad: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(1...3, id: \.self) { col in
                        let n = row * 3 + col
                        RKey(.digit(n), title: "\(n)", height: 64)
                    }
                }
            }
            HStack(spacing: 12) {
                RKey(.dot, title: "•", height: 64)
                RKey(.d0, title: "0", height: 64)
                RKey(.confirm, title: "OK", height: 64)
            }
            HStack(spacing: 12) {
                RKey(.channelDown, title: "P −", symbol: "chevron.down", repeats: true)
                RKey(.info, title: "Info", symbol: "info.circle")
                RKey(.channelUp, title: "P +", symbol: "chevron.up", repeats: true)
            }
            .padding(.top, 6)
            SectionLabel("Videotext")
            HStack(spacing: 12) {
                RKey(.teletext, title: "Videotext", symbol: "text.alignleft")
                RKey(.subtitle, title: "Untertitel", symbol: "captions.bubble")
                RKey(.find, title: "Guide", symbol: "list.bullet.rectangle")
            }
            ColorKeys()
        }
    }
}

struct MediaPad: View {
    var body: some View {
        VStack(spacing: 12) {
            SectionLabel("Wiedergabe")
            HStack(spacing: 10) {
                RKey(.previous, symbol: "backward.end.fill")
                RKey(.rewind, symbol: "backward.fill", repeats: true)
                RKey(.playPause, symbol: "playpause.fill")
                RKey(.fastForward, symbol: "forward.fill", repeats: true)
                RKey(.next, symbol: "forward.end.fill")
            }
            HStack(spacing: 10) {
                RKey(.play, symbol: "play.fill")
                RKey(.pause, symbol: "pause.fill")
                RKey(.stop, symbol: "stop.fill")
                RKey(.record, symbol: "record.circle", foreground: .red)
            }
            SectionLabel("Navigation")
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 10) {
                    RKey(.back, title: "Zurück", symbol: "arrow.uturn.backward", height: 46)
                    RKey(.options, title: "Optionen", height: 46)
                }
                DPad().frame(maxWidth: 170)
                VStack(spacing: 10) {
                    RKey(.home, title: "Home", symbol: "house", height: 46)
                    RKey(.source, title: "Quelle", height: 46)
                }
            }
            SectionLabel("Bild & Extras")
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    RKey(.ambilight, title: "Ambilight", symbol: "rays")
                    RKey(.viewMode, title: "Format", symbol: "aspectratio")
                    RKey(.adjust, title: "Bild/Ton", symbol: "slider.horizontal.3")
                }
                GridRow {
                    RKey(.online, title: "Smart TV", symbol: "square.grid.2x2")
                    RKey(.watchTV, title: "TV", symbol: "tv")
                    RKey(.source, title: "Eingang", symbol: "rectangle.on.rectangle")
                }
            }
        }
    }
}
