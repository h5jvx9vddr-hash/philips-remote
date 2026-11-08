import Foundation

// ATVCheck <pairPort> <remotePort> <dir>: echte TLS-Verbindungen gegen Tests/atv/atv_mock.py
let pairPort = Int(CommandLine.arguments[1])!
let remotePort = Int(CommandLine.arguments[2])!
let dir = URL(fileURLWithPath: CommandLine.arguments[3])
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "OK    " : "FEHLER ") + what)
    if !ok { failures += 1 }
}

func waitForFile(_ name: String) async -> String? {
    for _ in 0..<50 {
        if let s = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), !s.isEmpty { return s }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}

// Identität im Schlüsselbund; das Zertifikat bekommt der simulierte TV als Vertrauensanker.
let identity = try ATVIdentity.get()
let again = try ATVIdentity.get()
check(ATVIdentity.publicKey(of: identity) == ATVIdentity.publicKey(of: again), "Identität wird wiederverwendet")
try ATVIdentity.certificatePEM(of: identity)!.write(to: dir.appendingPathComponent("client.pem"), atomically: true, encoding: .utf8)

// Vor dem Koppeln: Steuerport verweigert
do {
    try await ATVRemote.pressOnce(host: "127.0.0.1", keyCode: nil, port: remotePort)
    check(false, "ungekoppelt abgelehnt")
} catch ATVError.notPaired {
    check(true, "ungekoppelt → „bitte koppeln“")
}

// Kopplung
let pairing = try await ATVPairing.start(host: "127.0.0.1", port: pairPort, clientName: "Philips Remote (CI)")
guard let code = await waitForFile("code.txt") else { print("FEHLER kein Code vom Mock"); exit(1) }
check(code.count == 6, "Gerät zeigt Code \(code)")
let wrongFirst = String(format: "%02X", (UInt8(code.prefix(2), radix: 16)! &+ 1)) + code.dropFirst(2)
do {
    try await pairing.finish(code: wrongFirst)
    check(false, "falscher Code erkannt")
} catch ATVError.badCode {
    check(true, "falscher Code lokal erkannt (Verbindung bleibt offen)")
}
try await pairing.finish(code: code.lowercased())
check(true, "Kopplung mit Code \(code)")

// Steuerung
let remote = ATVRemote(host: "127.0.0.1", port: remotePort)
let volume = OneShot<String>()
let power = OneShot<Bool>()
remote.onVolume = { level, max, muted in volume.fire(.success("\(level)/\(max)/\(muted)")) }
remote.onPower = { power.fire(.success($0)) }
try await remote.connect()
check(remote.isOpen, "Steuerverbindung bereit (configure + set_active beantwortet)")
check(remote.device == "Telekom MagentaTV One", "Gerät: \(remote.device ?? "-")")
check(try await power.wait(timeout: 3), "Ein/Aus-Status: an")
check(try await volume.wait(timeout: 3) == "12/100/false", "Lautstärke vom Gerät")
for code in [24, 25, 23, 3, 26] { remote.press(code) }
remote.open("https://www.netflix.com/title")
let log = await waitForFile("keys.txt")
try? await Task.sleep(for: .milliseconds(1500))
let finalLog = (try? String(contentsOf: dir.appendingPathComponent("keys.txt"), encoding: .utf8)) ?? log ?? ""
let lines = finalLog.split(separator: "\n").map(String.init)
check(lines.contains("pong:7"), "Ping beantwortet")
check(lines.filter { $0 != "pong:7" } == ["24", "25", "23", "3", "26", "link:https://www.netflix.com/title"], "Tasten kamen an: \(lines)")
remote.close()

print(failures == 0 ? "\nAlles grün." : "\n\(failures) Fehler.")
exit(failures == 0 ? 0 : 1)
