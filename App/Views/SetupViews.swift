import SwiftUI

/// Ablauf „TV gewählt → ggf. PIN am TV → gespeichert“, gemeinsam für Ersteinrichtung und Neu-Koppeln.
@MainActor @Observable
final class PairingFlow {
    var busy = false
    var error: String?
    var pinFor: FoundTV?
    var pin = ""
    private var session: PairingSession?
    private var atvPairing: ATVPairing?

    /// Android-/Google-TV: 6-stelliger Code aus 0–9 und A–F statt 4-stelliger PIN.
    var isAndroidTV: Bool { pinFor?.endpoint.isAndroidTV == true }
    var codeComplete: Bool {
        isAndroidTV ? pin.filter(\.isHexDigit).count == 6 : pin.filter(\.isNumber).count >= 4
    }

    func choose(_ tv: FoundTV, store: TVStore) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        guard tv.info.needsPairing else {
            await store.adopt(tv, credentials: nil)
            return
        }
        do {
            if tv.endpoint.isAndroidTV {
                atvPairing?.cancel()
                atvPairing = try await store.startATVPairing(tv)
            } else {
                session = try await store.startPairing(tv)
            }
            pin = ""
            pinFor = tv
        } catch {
            self.error = error.localizedDescription
        }
    }

    func confirm(store: TVStore) async {
        guard let tv = pinFor, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if tv.endpoint.isAndroidTV, let atvPairing {
                try await store.finishATVPairing(tv, pairing: atvPairing, code: pin.filter(\.isHexDigit))
                self.atvPairing = nil
            } else if let session {
                try await store.finishPairing(tv, session: session, pin: pin)
            }
            pinFor = nil
        } catch ATVError.badCode {
            // Tippfehler: Verbindung bleibt offen, nochmal eingeben
            pin = ""
            self.error = ATVError.badCode.localizedDescription
        } catch {
            pinFor = nil
            atvPairing = nil
            self.error = error.localizedDescription
        }
    }

    /// Sheet weggewischt → offene Android-TV-Kopplung beenden.
    func dismissed() {
        guard !busy else { return }
        atvPairing?.cancel()
        atvPairing = nil
    }

    func cancel() {
        atvPairing?.cancel()
        atvPairing = nil
        pinFor = nil
    }
}

struct PinSheet: View {
    @Environment(TVStore.self) private var store
    @Bindable var flow: PairingFlow
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(flow.isAndroidTV ? "Code" : "PIN", text: $flow.pin)
                        .keyboardType(flow.isAndroidTV ? .asciiCapable : .numberPad)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .focused($focused)
                } footer: {
                    if flow.isAndroidTV {
                        Text("Das Gerät zeigt jetzt einen 6-stelligen Code aus Ziffern und Buchstaben (A–F). Genau so eingeben.")
                    } else {
                        Text("Der Fernseher zeigt jetzt eine 4-stellige PIN. Bitte innerhalb einer Minute eingeben.")
                    }
                }
                if let error = flow.error, flow.isAndroidTV {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Section {
                    Button {
                        Task { await flow.confirm(store: store) }
                    } label: {
                        HStack {
                            Spacer()
                            if flow.busy { ProgressView() } else { Text("Koppeln").bold() }
                            Spacer()
                        }
                    }
                    .disabled(flow.busy || !flow.codeComplete)
                }
            }
            .navigationTitle(flow.pinFor?.info.name ?? "PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { flow.cancel() }
                }
            }
            .onAppear { focused = true }
        }
    }
}

struct SetupView: View {
    @Environment(TVStore.self) private var store
    @State private var flow = PairingFlow()
    @State private var found: [FoundTV] = []
    @State private var scanning = false
    @State private var scanRun = 0
    @State private var ip = UserDefaults.standard.string(forKey: "philips.lastIP") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "av.remote.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(Color.accentColor)
                        Text("Fernseher suchen").font(.title2.weight(.bold))
                        Text("Die App sucht deinen Philips-TV oder dein Android-/Google-TV-Gerät (z. B. MagentaTV-Box) automatisch – im WLAN und im Hotspot deines iPhones.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(found) { tv in
                        Button {
                            Task { await flow.choose(tv, store: store) }
                        } label: {
                            HStack {
                                Image(systemName: "tv").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.info.name).foregroundStyle(.primary)
                                    Text("\(tv.endpoint.host) · \(tv.endpoint.isAndroidTV ? "Android TV, Kopplung per Code" : tv.info.needsPairing ? "Philips, Kopplung per PIN" : "Philips, ohne PIN")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if flow.busy { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                        }
                        .disabled(flow.busy)
                    }
                    HStack {
                        if scanning {
                            ProgressView()
                            Text("Suche im Netz …").foregroundStyle(.secondary).padding(.leading, 6)
                        } else {
                            Text(found.isEmpty ? "Kein Fernseher gefunden." : "Suche abgeschlossen.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Erneut suchen") { scanRun += 1 }
                            .disabled(scanning)
                    }
                    .font(.subheadline)
                } header: {
                    Text("Gefundene Fernseher")
                } footer: {
                    Text("Hotspot: Am TV unter Einstellungen → Netzwerk → WLAN mit dem Hotspot deines iPhones verbinden. Am iPhone „Maximale Kompatibilität“ einschalten, falls der TV den Hotspot nicht sieht.")
                }

                if let error = flow.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("192.168.178.40", text: $ip)
                        .keyboardType(.decimalPad)
                        .font(.title3.monospacedDigit())
                    Button("Mit dieser IP verbinden") {
                        Task {
                            do {
                                let tv = try await store.probe(manualIP: ip)
                                await flow.choose(tv, store: store)
                            } catch {
                                flow.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(flow.busy || ip.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Oder IP von Hand")
                } footer: {
                    Text("Steht am TV unter Einstellungen → Netzwerk → Netzwerkeinstellungen anzeigen.")
                }

                Section("Vorher am Fernseher") {
                    HelpSteps()
                }

                DiagnoseSection()
            }
            .navigationTitle("Philips TV")
            .sheet(item: $flow.pinFor, onDismiss: { flow.dismissed() }) { _ in
                PinSheet(flow: flow).presentationDetents([.medium])
            }
            .task(id: scanRun) { await scan() }
        }
    }

    /// Sucht, bis etwas gefunden wurde (der erste Lauf scheitert oft an der „Lokales Netzwerk“-Abfrage von iOS).
    private func scan() async {
        guard !store.demo else { return }
        for attempt in 0..<4 {
            scanning = true
            for await tv in Discovery.scan() where !found.contains(where: { $0.id == tv.id }) {
                found.append(tv)
            }
            scanning = false
            if !found.isEmpty || Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 6))
        }
    }
}

struct HelpSteps: View {
    private let steps = [
        ("power", "Fernseher einschalten. iPhone und TV müssen im selben WLAN sein – oder der TV hängt im Hotspot des iPhones."),
        ("lock.shield", "Beim ersten Start fragt iOS nach „Lokales Netzwerk“ → Erlauben. Die Suche läuft danach von selbst weiter."),
        ("number", "Android-/Google-TVs (ab 2016) zeigen beim Koppeln eine PIN auf dem Bildschirm – die in der App eingeben."),
        ("wifi", "Zum Einschalten übers Netz am TV „Mit WLAN einschalten“ (WoWLAN) bzw. „Mit Chromecast einschalten“ aktivieren."),
        ("tv.and.mediabox", "Android-/Google-TV-Boxen (z. B. MagentaTV) werden auch gefunden: Beim Koppeln erscheint ein 6-stelliger Code am Fernseher. Ist am TV HDMI-CEC an (Philips: „EasyLink“), steuert die Box auch Ein/Aus und Lautstärke des Fernsehers."),
        ("keyboard", "Ältere TVs (2011–2013) ohne Treffer: Mit der Fernbedienung im Fernsehbild 5646877223 eintippen, um JointSPACE freizuschalten."),
    ]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            Label {
                Text(step.1).font(.subheadline)
            } icon: {
                Image(systemName: step.0).foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(TVStore.self) private var store
    @State private var flow = PairingFlow()
    @State private var mac = ""
    @State private var testing = false
    @State private var confirmRemove = false

    private var macInvalid: Bool {
        !mac.trimmingCharacters(in: .whitespaces).isEmpty && PhilipsClient.formatMAC(mac) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let tv = store.tv {
                    Section("Fernseher") {
                        LabeledContent("Name", value: tv.info.name)
                        LabeledContent("IP-Adresse", value: tv.endpoint.host)
                        LabeledContent("Schnittstelle", value: tv.endpoint.isAndroidTV ? "Android-TV-Fernbedienung · 6466" : "JointSPACE \(tv.endpoint.api) · \(tv.endpoint.secure ? "HTTPS 1926" : "HTTP 1925")")
                        LabeledContent("Status", value: store.statusText)
                        Button {
                            Task {
                                testing = true
                                await store.test()
                                testing = false
                            }
                        } label: {
                            HStack {
                                Text("Verbindung testen")
                                Spacer()
                                if testing { ProgressView() }
                            }
                        }
                        .disabled(testing || store.searching)
                        Button {
                            Task { await store.search(force: true) }
                        } label: {
                            HStack {
                                Text("Im Netz neu suchen")
                                Spacer()
                                if store.searching { ProgressView() }
                            }
                        }
                        .disabled(store.searching)
                        if tv.info.needsPairing {
                            Button(tv.endpoint.isAndroidTV ? "Neu koppeln (Code)" : "Neu koppeln (PIN)") {
                                Task { await flow.choose(FoundTV(endpoint: tv.endpoint, info: tv.info), store: store) }
                            }
                            .disabled(flow.busy)
                        }
                        if let error = flow.error {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                    }

                    Section {
                        TextField("AA:BB:CC:DD:EE:FF", text: $mac)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        if macInvalid {
                            Text("Keine gültige MAC-Adresse.").font(.footnote).foregroundStyle(.red)
                        }
                        Button {
                            Task { await store.wake() }
                        } label: {
                            HStack {
                                Text("Einschalten versuchen")
                                Spacer()
                                if store.waking { ProgressView() }
                            }
                        }
                        .disabled(store.waking)
                    } header: {
                        Text("Einschalten übers Netzwerk")
                    } footer: {
                        Text("Ist der TV im Standby, schaltet ihn die Ein/Aus-Taste übers Netz ein (Wake-on-LAN an diese MAC, wird beim Koppeln ausgelesen). Dafür am TV „Mit WLAN einschalten“ bzw. „Mit Chromecast einschalten“ aktivieren.")
                    }

                    Section {
                        Text("Wechselst du das WLAN oder nutzt den Hotspot, sucht die App den Fernseher automatisch und übernimmt die neue IP. Die Kopplung bleibt erhalten.")
                            .font(.subheadline)
                    } header: {
                        Text("Anderes Netz")
                    }

                    Section {
                        Text("In der Kurzbefehle-App gibt es die Aktion „TV-Taste drücken“ – z. B. für Siri: „Philips TV Ein/Aus“ oder „Philips TV Stumm“.")
                            .font(.subheadline)
                    } header: {
                        Text("Kurzbefehle & Siri")
                    }

                    Section {
                        Button("Fernseher entfernen", role: .destructive) { confirmRemove = true }
                    } footer: {
                        Text("Danach kannst du einen anderen Fernseher suchen und koppeln.")
                    }
                }

                Section("Hilfe") {
                    HelpSteps()
                }

                DiagnoseSection()
            }
            .navigationTitle("Einstellungen")
            .onAppear { mac = store.tv?.mac ?? "" }
            .onChange(of: mac) { _, v in store.setMAC(v) }
            .sheet(item: $flow.pinFor, onDismiss: { flow.dismissed() }) { _ in
                PinSheet(flow: flow).presentationDetents([.medium])
            }
            .confirmationDialog("Fernseher entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Entfernen", role: .destructive) { store.remove() }
            }
        }
    }
}

/// Zeigt, was die Suche im Netz sieht – zum Weitergeben, wenn kein TV gefunden wird.
struct DiagnoseSection: View {
    @State private var report: String?
    @State private var running = false

    var body: some View {
        Section {
            Button {
                Task {
                    running = true
                    report = await Discovery.diagnose()
                    running = false
                }
            } label: {
                HStack {
                    Text("Netz-Diagnose starten")
                    Spacer()
                    if running { ProgressView() }
                }
            }
            .disabled(running)
            if let report {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                ShareLink("Ergebnis teilen", item: report)
                Button("Kopieren") { UIPasteboard.general.string = report }
            }
        } header: {
            Text("Diagnose")
        } footer: {
            Text("Dauert bis zu 30 Sekunden. Das Ergebnis zeigt alle Geräte im Netz mit TV-typischen Ports.")
        }
    }
}
