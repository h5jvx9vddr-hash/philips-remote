import SwiftUI
import Observation

struct SavedTV: Codable, Equatable {
    var endpoint: TVEndpoint
    var info: TVInfo
    var credentials: Credentials?
    /// Für Wake-on-LAN; beim Koppeln aus dem TV gelesen, in den Einstellungen änderbar.
    var mac: String?

    var client: PhilipsClient { PhilipsClient(endpoint: endpoint, credentials: credentials) }
}

extension SavedTV {
    static let key = "philips.tv"

    static func load() -> SavedTV? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedTV.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Den gespeicherten TV im aktuellen Netz wiederfinden (gleicher Name, sonst der einzige gefundene).
    /// Bei gekoppelten TVs zählt nur einer, der die Zugangsdaten annimmt.
    func locate() async -> SavedTV? {
        let found = await Discovery.findAll()
        let ordered = found.filter { $0.info.name == info.name } + found.filter { $0.info.name != info.name }
        for (i, tv) in ordered.enumerated() {
            if tv.info.name != info.name && (found.count > 1 || i > 0) { continue }
            var moved = self
            moved.endpoint = tv.endpoint
            if credentials != nil {
                do { _ = try await moved.client.volume() } catch PhilipsError.unauthorized { continue } catch {}
            }
            return moved
        }
        return nil
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

@MainActor @Observable
final class TVStore {
    var tv: SavedTV? {
        didSet {
            guard !demo else { return }
            if let tv { tv.save() } else { UserDefaults.standard.removeObject(forKey: SavedTV.key) }
        }
    }
    var online: Bool?
    var volume: Volume?
    var power: String?
    var waking = false
    var searching = false
    /// TV lehnt die gespeicherte Kopplung ab (z. B. zurückgesetzt) → neu koppeln.
    var unauthorized = false
    var toast: String?

    let demo: Bool
    private var queue: Task<Void, Never>?
    private var pending = 0
    private var failures = 0
    private var lastSearch = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var volumeSetAt = Date.distantPast

    init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo")
        if demo {
            if !args.contains("-setup") {
                tv = SavedTV(endpoint: TVEndpoint(host: "172.20.10.4", secure: true, api: 6),
                             info: TVInfo(name: "55PUS8505/12", needsPairing: true, os: "MSAF_2020"),
                             credentials: Credentials(user: "demo", password: "demo"),
                             mac: "70:AF:24:1C:5E:A2")
                online = true
                power = "On"
                volume = Volume(current: 18, min: 0, max: 60, muted: false)
            }
        } else {
            tv = SavedTV.load()
        }
    }

    private var client: PhilipsClient? { tv?.client }

    var statusText: String {
        if waking { return "wird eingeschaltet …" }
        if searching && online != true { return "suche im Netz …" }
        if unauthorized { return "bitte neu koppeln" }
        switch online {
        case .some(true): return power == "On" || power == nil ? "verbunden" : "Standby"
        case .some(false): return "nicht erreichbar"
        case .none: return "verbinde …"
        }
    }

    // MARK: Koppeln

    /// TV ohne PIN übernehmen (ältere Modelle) bzw. nach erfolgreicher PIN-Kopplung.
    func adopt(_ found: FoundTV, credentials: Credentials?) async {
        let keepMAC = tv?.info.name == found.info.name ? tv?.mac : nil
        if let host = tv?.endpoint.host { DigestAuth.forget(host) }
        tv = SavedTV(endpoint: found.endpoint, info: found.info, credentials: credentials, mac: keepMAC)
        online = true
        failures = 0
        if let mac = try? await client?.mac() { tv?.mac = mac }
        await refresh()
    }

    func startPairing(_ found: FoundTV) async throws -> PairingSession {
        try await PhilipsClient(endpoint: found.endpoint).pairRequest(deviceName: UIDevice.current.name)
    }

    func finishPairing(_ found: FoundTV, session: PairingSession, pin: String) async throws {
        let creds = try await PhilipsClient(endpoint: found.endpoint).pairGrant(session, pin: pin)
        unauthorized = false
        await adopt(found, credentials: creds)
    }

    func probe(manualIP raw: String) async throws -> FoundTV {
        guard let host = PhilipsClient.normalize(raw) else { throw PhilipsError.invalidHost }
        UserDefaults.standard.set(host, forKey: "philips.lastIP")
        guard let found = await PhilipsClient.probe(host) else {
            throw PhilipsError.unreachable("keine Philips-Antwort auf Port 1925/1926")
        }
        return found
    }

    func remove() {
        if let host = tv?.endpoint.host { DigestAuth.forget(host) }
        tv = nil
        online = nil
        unauthorized = false
        volume = nil
        power = nil
    }

    func setMAC(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { tv?.mac = nil } else if let mac = PhilipsClient.formatMAC(trimmed) { tv?.mac = mac }
    }

    // MARK: Tasten

    func press(_ key: PhilipsKey) {
        Haptics.tap()
        guard !demo, tv != nil else { return }
        // Bei Dauerdruck auf einen langsamen/aus­geschalteten TV keinen Rückstau aufbauen.
        guard pending < 4 else { return }
        pending += 1
        let previous = queue
        queue = Task {
            await previous?.value
            defer { pending -= 1 }
            guard let client else { return }
            do {
                if key == .standby, power != nil, power != "On" {
                    try await client.setPower(true)
                    power = "On"
                    return
                }
                try await client.send(key.rawValue)
                online = true
                if key == .volumeUp || key == .volumeDown || key == .mute { await refreshVolume() }
                if key == .standby { power = nil }
            } catch {
                switch error {
                case PhilipsError.unreachable:
                    online = false
                    if key == .standby {
                        await wake()
                        return
                    }
                    show("Fernseher nicht erreichbar – ich suche ihn im Netz …")
                    await search(force: true)
                default:
                    show(error.localizedDescription)
                }
            }
        }
    }

    func setVolume(_ n: Int) {
        guard n != volume?.current else { return }
        volume?.current = n
        volumeSetAt = .now
        guard !demo, let client else { return }
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do { try await client.setVolume(n, muted: volume?.muted ?? false) } catch { show(error.localizedDescription) }
        }
    }

    /// Wake-on-LAN (bzw. „powerstate On“, falls der TV im Standby noch antwortet), dann bis zu 20 s warten.
    func wake() async {
        guard let tv else { return }
        if demo { return }
        waking = true
        defer { waking = false }
        if (try? await tv.client.setPower(true)) != nil {
            power = "On"
            online = true
            return
        }
        guard let mac = tv.mac else {
            show("Der Fernseher ist aus oder nicht erreichbar. Zum Einschalten übers Netz in den Einstellungen die MAC-Adresse eintragen.")
            return
        }
        for _ in 0..<3 { await WakeOnLAN.send(mac: mac, host: tv.endpoint.host) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(2))
            if (try? await tv.client.info()) != nil {
                try? await tv.client.setPower(true)
                online = true
                show("Fernseher ist an.")
                await refresh()
                return
            }
        }
        show("Keine Antwort. Am TV „Mit WLAN einschalten“ bzw. „Mit Chromecast einschalten“ aktivieren – sonst einmal mit der normalen Fernbedienung einschalten.")
    }

    // MARK: Suchen

    /// Sucht den gekoppelten TV im aktuellen Netz (anderes WLAN, Hotspot) und übernimmt die neue IP.
    @discardableResult
    func search(force: Bool = false) async -> Bool {
        guard !demo, let tv, !searching else { return false }
        guard force || Date.now.timeIntervalSince(lastSearch) > 30 else { return false }
        searching = true
        lastSearch = .now
        defer { searching = false }
        guard let moved = await tv.locate() else {
            if force { show(PhilipsError.notFound.localizedDescription) }
            return false
        }
        self.tv?.endpoint = moved.endpoint
        failures = 0
        online = true
        if moved.endpoint.host != tv.endpoint.host { show("Fernseher gefunden unter \(moved.endpoint.host).") }
        await refresh()
        return true
    }

    // MARK: Status

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                // Nicht erreichbar → anderes Netz? Dann selbst suchen.
                if online == false, failures >= 2 { await search() }
                try? await Task.sleep(for: .seconds(online == true ? 4 : 6))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard !demo, let client else { return }
        do {
            let v = try await client.volume()
            // Gerade per Regler gesetzt → nicht vom alten Wert überschreiben lassen.
            if Date.now.timeIntervalSince(volumeSetAt) > 1.5 { volume = v } else { volume?.muted = v.muted }
            power = try? await client.powerState()
            online = true
            failures = 0
            unauthorized = false
        } catch PhilipsError.unauthorized {
            online = true
            if !unauthorized { show(PhilipsError.unauthorized.localizedDescription) }
            unauthorized = true
        } catch {
            // Im Standby antworten manche TVs noch auf system/powerstate, aber nicht auf audio.
            if let p = try? await client.powerState() {
                power = p
                online = true
                failures = 0
            } else {
                online = (try? await client.info()) != nil
                failures = online == true ? 0 : failures + 1
            }
        }
    }

    func test() async {
        await refresh()
        if online != true { await search(force: true) }
        show(online == true ? "Verbindung steht." : "Fernseher antwortet nicht.")
    }

    private func refreshVolume() async {
        guard let client else { return }
        if let v = try? await client.volume() { volume = v }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
