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
