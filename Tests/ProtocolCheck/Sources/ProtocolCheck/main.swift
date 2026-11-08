import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let v6Port = Int(CommandLine.arguments[1])!
let v1Port = Int(CommandLine.arguments[2])!
let closedPort = 1
let v6Ports = PhilipsPorts(http: v6Port, https: closedPort)
let v1Ports = PhilipsPorts(http: v1Port, https: closedPort)
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "OK    " : "FEHLER ") + what)
    if !ok { failures += 1 }
}

func keyLog(_ port: Int) throws -> [String] {
    let data = try Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/log")!)
    return (try JSONSerialization.jsonObject(with: data) as? [String]) ?? []
}

// Eingabe-Normalisierung
check(PhilipsClient.normalize(" 172,20,10,4 ") == "172.20.10.4", "IP mit Komma (deutsche Tastatur)")
check(PhilipsClient.normalize("300.1.1.1") == nil, "ungültige IP abgelehnt")
check(PhilipsClient.formatMAC("70-af-24-1c-5e-a2") == "70:AF:24:1C:5E:A2", "MAC-Format")
check(WakeOnLANPacket.bytes(mac: "70:AF:24:1C:5E:A2")?.count == 102, "Magic Packet 102 Byte")

// Netze für die Suche
let hotspot = Discovery.hosts(address: Discovery.parse("172.20.10.1")!, netmask: Discovery.parse("255.255.255.240")!)
check(hotspot.first == "172.20.10.2" && hotspot.last == "172.20.10.14" && hotspot.count == 13, "iPhone-Hotspot /28: \(hotspot.count) Hosts")
let home = Discovery.hosts(address: Discovery.parse("192.168.178.23")!, netmask: Discovery.parse("255.255.255.0")!)
check(home.count == 253 && !home.contains("192.168.178.23") && !home.contains("192.168.178.255"), "Heimnetz /24 ohne eigene IP")
let big = Discovery.hosts(address: Discovery.parse("10.4.7.9")!, netmask: Discovery.parse("255.255.0.0")!)
check(big.count == 253 && big.allSatisfy { $0.hasPrefix("10.4.7.") }, "/16 nur im eigenen /24-Block")

// Kopplungs-Signatur (Referenz aus Python/ha-philipsjs)
check(PhilipsClient.signature(timestamp: 1700000000, pin: "1234") == "Up43OnIb8sG9V66+HISRwCPnYns=", "HMAC-SHA1-Signatur")
let parsed = DigestAuth.parse(#"Digest realm="XTV", qop="auth,auth-int", nonce="abc", opaque=x1"#)
check(parsed["realm"] == "XTV" && parsed["qop"] == "auth,auth-int" && parsed["nonce"] == "abc" && parsed["opaque"] == "x1", "Digest-Challenge lesen")

// Suche: offene Ports + system
let open = await Discovery.openHosts(["127.0.0.1", "127.0.0.2"], ports: [v6Port])
check(open == ["127.0.0.1"], "Portsuche findet nur den TV: \(open)")
let found = await Discovery.findAll(hosts: ["127.0.0.2", "127.0.0.1"], ports: v6Ports)
check(found.count == 1 && found.first?.endpoint.host == "127.0.0.1", "Suche liefert genau einen TV")

// Android-TV (API 6, PIN)
guard let tv6 = await PhilipsClient.probe("127.0.0.1", ports: v6Ports) else {
    print("FEHLER v6-TV nicht erkannt"); exit(1)
}
check(tv6.endpoint.api == 6 && !tv6.endpoint.secure && tv6.info.needsPairing, "v6 erkannt: API \(tv6.endpoint.api), PIN nötig")
check(tv6.info.name == "55PUS8505/12", "Name: \(tv6.info.name)")

let unpaired = PhilipsClient(endpoint: tv6.endpoint, ports: v6Ports)
do {
    try await unpaired.send(PhilipsKey.volumeUp.rawValue)
    check(false, "ohne Kopplung abgelehnt")
} catch PhilipsError.unauthorized {
    check(true, "ohne Kopplung → 401 erkannt")
}

let first = try await unpaired.pairRequest(deviceName: "Test-iPhone")
do {
    _ = try await unpaired.pairGrant(first, pin: "9999")
    check(false, "falsche PIN erkannt")
} catch PhilipsError.pairing(let code) {
    check(code == "INVALID_PIN", "falsche PIN → \(code)")
}
let session = try await unpaired.pairRequest(deviceName: "Test-iPhone")
let creds = try await unpaired.pairGrant(session, pin: " 12 34")
check(creds.user == session.deviceID && creds.password == session.authKey, "Kopplung mit PIN 1234")

let paired = PhilipsClient(endpoint: tv6.endpoint, credentials: creds, ports: v6Ports)
for key in [PhilipsKey.standby, .volumeUp, .confirm, .digit(7), .red, .ambilight, .channelUp] {
    try await paired.send(key.rawValue)
}
let log6 = try keyLog(v6Port)
check(log6 == ["Standby", "VolumeUp", "Confirm", "Digit7", "RedColour", "AmbilightOnOff", "ChannelStepUp"], "Tasten kamen an (Digest mit Nonce-Cache): \(log6)")
check(PhilipsKey.allCases.allSatisfy { $0.rawValue.allSatisfy { $0.isLetter || $0.isNumber } }, "alle Tastennamen gültig")

try await paired.setVolume(23)
let vol = try await paired.volume()
check(vol.current == 23 && vol.max == 60 && !vol.muted, "Lautstärke setzen/lesen: \(vol.current)/\(vol.max)")
try await paired.setPower(false)
check(try await paired.powerState() == "Standby", "Standby gesetzt")
try await paired.setPower(true)
check(try await paired.powerState() == "On", "Einschalten per powerstate")
check(try await paired.mac() == "70:AF:24:1C:5E:A2", "MAC aus network/devices")

let wrong = PhilipsClient(endpoint: tv6.endpoint, credentials: Credentials(user: creds.user, password: "falsch"), ports: v6Ports)
do {
    _ = try await wrong.volume()
    check(false, "falsches Passwort erkannt")
} catch PhilipsError.unauthorized {
    check(true, "falsches Passwort → neu koppeln")
}

// Alter TV (API 1, ohne PIN)
guard let tv1 = await PhilipsClient.probe("127.0.0.1", ports: v1Ports) else {
    print("FEHLER v1-TV nicht erkannt"); exit(1)
}
check(tv1.endpoint.api == 1 && !tv1.info.needsPairing && tv1.info.name == "Philips TV", "v1 erkannt: API \(tv1.endpoint.api), ohne PIN")
let old = PhilipsClient(endpoint: tv1.endpoint, ports: v1Ports)
try await old.send(PhilipsKey.mute.rawValue)
try await old.setVolume(5)
check(try keyLog(v1Port) == ["Mute"] && (try await old.volume()).current == 5, "v1: Taste + Lautstärke")

// Nicht erreichbar
let start = Date()
check(await PhilipsClient.probe("127.0.0.1", ports: PhilipsPorts(http: closedPort, https: closedPort)) == nil, "kein TV → nil")
do {
    _ = try await PhilipsClient(endpoint: TVEndpoint(host: "127.0.0.1", secure: false, api: 6), ports: PhilipsPorts(http: closedPort, https: closedPort)).info()
    check(false, "geschlossener Port erkannt")
} catch PhilipsError.unreachable(let why) {
    check(Date().timeIntervalSince(start) < 6, "nicht erreichbar → \(why)")
}

print(failures == 0 ? "\nAlles grün." : "\n\(failures) Fehler.")
exit(failures == 0 ? 0 : 1)
