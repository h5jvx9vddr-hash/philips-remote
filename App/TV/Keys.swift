/// Tastennamen der Philips-JointSPACE-API (`POST /<api>/input/key {"key": …}`), gleich für API 1 (2011–2015) und 6 (Android/Saphi).
enum PhilipsKey: String, CaseIterable {
    case standby = "Standby"
    case source = "Source"
    case watchTV = "WatchTV"
    case home = "Home"
    case online = "Online"

    case options = "Options"
    case info = "Info"
    case adjust = "Adjust"
    case find = "Find"
    case back = "Back"

    case up = "CursorUp", down = "CursorDown", left = "CursorLeft", right = "CursorRight"
    case confirm = "Confirm"

    case volumeUp = "VolumeUp", volumeDown = "VolumeDown", mute = "Mute"
    case channelUp = "ChannelStepUp", channelDown = "ChannelStepDown"

    case red = "RedColour", green = "GreenColour", yellow = "YellowColour", blue = "BlueColour"

    case d0 = "Digit0", d1 = "Digit1", d2 = "Digit2", d3 = "Digit3", d4 = "Digit4"
    case d5 = "Digit5", d6 = "Digit6", d7 = "Digit7", d8 = "Digit8", d9 = "Digit9"
    case dot = "Dot"

    case teletext = "Teletext", subtitle = "Subtitle"

    case playPause = "PlayPause", play = "Play", pause = "Pause", stop = "Stop", record = "Record"
    case rewind = "Rewind", fastForward = "FastForward"
    case previous = "Previous", next = "Next"

    case ambilight = "AmbilightOnOff", viewMode = "Viewmode"

    static func digit(_ n: Int) -> PhilipsKey {
        [.d0, .d1, .d2, .d3, .d4, .d5, .d6, .d7, .d8, .d9][n]
    }
}

extension PhilipsKey {
    /// Android-Keycode für Android-/Google-TV-Geräte (z. B. MagentaTV-Box); nil = gibt es dort nicht.
    var androidKeyCode: Int? {
        switch self {
        case .standby: 26
        case .source: 178
        case .watchTV: 170
        case .home: 3
        case .online: 284
        case .options: 82
        case .info: 165
        case .adjust: 176
        case .find: 172
        case .back: 4
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .confirm: 23
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .channelUp: 166
        case .channelDown: 167
        case .red: 183
        case .green: 184
        case .yellow: 185
        case .blue: 186
        case .d0, .d1, .d2, .d3, .d4, .d5, .d6, .d7, .d8, .d9: 7 + Int(rawValue.last!.wholeNumberValue!)
        case .dot: 56
        case .teletext: 233
        case .subtitle: 175
        case .playPause: 85
        case .play: 126
        case .pause: 127
        case .stop: 86
        case .record: 130
        case .rewind: 89
        case .fastForward: 90
        case .previous: 88
        case .next: 87
        case .viewMode: 255
        case .ambilight: nil
        }
    }
}
