import AppIntents

enum TVCommand: String, AppEnum {
    case power, volumeUp, volumeDown, mute, channelUp, channelDown, source, ambilight

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "TV-Taste"
    static var caseDisplayRepresentations: [TVCommand: DisplayRepresentation] = [
        .power: "Ein/Aus",
        .volumeUp: "Lauter",
        .volumeDown: "Leiser",
        .mute: "Stumm",
        .channelUp: "Programm hoch",
        .channelDown: "Programm runter",
        .source: "Quelle",
        .ambilight: "Ambilight",
    ]

    var key: PhilipsKey {
        switch self {
        case .power: .standby
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .mute: .mute
        case .channelUp: .channelUp
        case .channelDown: .channelDown
        case .source: .source
        case .ambilight: .ambilight
        }
    }
}

struct PressTVKeyIntent: AppIntent {
    static var title: LocalizedStringResource = "TV-Taste drücken"
    static var description = IntentDescription("Drückt eine Taste am gekoppelten Philips-Fernseher.")

    @Parameter(title: "Taste")
    var command: TVCommand

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command) am Fernseher drücken")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard var tv = SavedTV.load() else { throw PhilipsError.notPaired }
        // Anderes WLAN/Hotspot → TV unter neuer IP suchen und merken.
        let reachable: Bool
        if tv.endpoint.isAndroidTV {
            reachable = await !Discovery.openHosts([tv.endpoint.host], ports: [ATV.remotePort]).isEmpty
        } else {
            reachable = (try? await tv.client.info()) != nil
        }
        if !reachable, let moved = await tv.locate() {
            tv = moved
            tv.save()
        }
        if tv.endpoint.isAndroidTV {
            guard let code = command.key.androidKeyCode else { return .result(dialog: "Diese Taste gibt es hier nicht.") }
            try await ATVRemote.pressOnce(host: tv.endpoint.host, keyCode: code)
            return .result(dialog: "Erledigt.")
        }
        if command == .power, let state = try? await tv.client.powerState(), state != "On" {
            try await tv.client.setPower(true)
            return .result(dialog: "Fernseher wird eingeschaltet.")
        }
        do {
            try await tv.client.send(command.key.rawValue)
        } catch PhilipsError.unreachable(let why) where command == .power {
            guard let mac = tv.mac else { throw PhilipsError.unreachable(why) }
            for _ in 0..<3 { await WakeOnLAN.send(mac: mac, host: tv.endpoint.host) }
            return .result(dialog: "Einschaltsignal gesendet.")
        }
        return .result(dialog: "Erledigt.")
    }
}

struct PhilipsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PressTVKeyIntent(),
            phrases: [
                "\(.applicationName) \(\.$command)",
                "\(\.$command) mit \(.applicationName)",
            ],
            shortTitle: "TV-Taste",
            systemImageName: "av.remote"
        )
    }
}
