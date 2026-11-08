import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wo und wie der TV antwortet (ermittelt beim Suchen; die IP ändert sich je nach WLAN/Hotspot).
struct TVEndpoint: Codable, Equatable, Hashable {
    var host: String
    /// HTTPS auf 1926 (Android-TVs ab 2016) statt HTTP auf 1925.
    var secure: Bool
    /// JointSPACE-Version: 1 (2011–2015), 5 oder 6 (Android/Saphi); 0 bei Android-TV-Geräten.
    var api: Int
    /// nil = Philips JointSPACE; .androidTV = Google-TV-Fernbedienungsprotokoll (Ports 6466/6467).
    var kind: TVKind? = nil

    var isAndroidTV: Bool { kind == .androidTV }
}

enum TVKind: String, Codable, Hashable {
    case androidTV
}

/// Infos aus `/<api>/system`.
struct TVInfo: Codable, Equatable {
    var name: String
    /// Android-/Saphi-TVs verlangen eine PIN-Kopplung (Digest-Anmeldung).
    var needsPairing: Bool
    var os: String?
}

/// Zugangsdaten aus der PIN-Kopplung (Digest: Benutzer = Geräte-ID, Passwort = auth_key).
struct Credentials: Codable, Equatable {
    var user: String
    var password: String
}

struct FoundTV: Identifiable, Equatable {
    var endpoint: TVEndpoint
    var info: TVInfo
    var id: String { endpoint.host }
}

struct Volume: Equatable {
    var current: Int
    var min: Int
    var max: Int
    var muted: Bool
}

/// Laufende PIN-Kopplung: zwischen pair/request und pair/grant.
struct PairingSession: Equatable {
    var deviceID: String
    var authKey: String
    var timestamp: Int
    var device: [String: String]
}

struct PhilipsPorts: Sendable {
    var http = 1925
    var https = 1926
    var atvRemote = 6466
    var atvPairing = 6467
    static let standard = PhilipsPorts()
}

enum PhilipsError: LocalizedError, Equatable {
    case invalidHost
    case notPaired
    case unreachable(String)
    case unauthorized
    case pairing(String)
    case rejected(Int)
    case badResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Das ist keine gültige IP-Adresse (Beispiel: 192.168.178.40)."
        case .notPaired:
            "Noch kein Fernseher gekoppelt – bitte zuerst die App öffnen."
        case .unreachable(let why):
            "Fernseher nicht erreichbar (\(why))."
        case .unauthorized:
            "Der Fernseher kennt diese App nicht mehr – bitte in den Einstellungen neu koppeln."
        case .pairing(let code):
            switch code {
            case "INVALID_PIN": "Falsche PIN – bitte nochmal koppeln."
            case "CONCURRENT_PAIRING": "Am Fernseher läuft schon eine Kopplung. Kurz warten und nochmal versuchen."
            case "TIMEOUT": "Die PIN ist abgelaufen – bitte nochmal koppeln."
            default: "Kopplung fehlgeschlagen (\(code))."
            }
        case .rejected(let code):
            "Der Fernseher hat den Befehl abgelehnt (Fehler \(code))."
        case .badResponse:
            "Unerwartete Antwort – ist unter dieser IP wirklich ein Philips-Fernseher?"
        case .notFound:
            "Kein Philips-Fernseher gefunden. Ist er an und im selben WLAN bzw. mit deinem Hotspot verbunden?"
        }
    }
}

/// Spricht die JointSPACE-API der Philips-Fernseher (HTTP 1925 / HTTPS 1926 mit Digest-Anmeldung).
struct PhilipsClient {
    let endpoint: TVEndpoint
    var credentials: Credentials?
    var ports = PhilipsPorts.standard

    /// Gemeinsamer Schlüssel aller Philips-Apps für die Kopplungs-Signatur (aus ha-philipsjs).
    static let sharedKey = Data(base64Encoded:
        "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==")!

    static let session = makeSession(timeout: 3)
    static let probeSession = makeSession(timeout: 2)

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.urlCredentialStorage = nil
        return URLSession(configuration: c, delegate: SelfSignedTrust(), delegateQueue: nil)
    }

    // MARK: Suchen

    /// Fragt `system` ab: zuerst HTTPS 1926 (Android), dann HTTP 1925 mit API 6, 5 und 1.
    static func probe(_ host: String, ports: PhilipsPorts = .standard) async -> FoundTV? {
        let tries: [(Bool, Int)] = [(true, 6), (false, 6), (false, 5), (false, 1)]
        for (secure, api) in tries {
            let c = PhilipsClient(endpoint: TVEndpoint(host: host, secure: secure, api: api), ports: ports)
            guard let json = try? await c.getJSON("system", session: probeSession) as? [String: Any],
                  json["name"] != nil || json["api_version"] != nil else {
                continue
            }
            let major = (json["api_version"] as? [String: Any])?["Major"] as? Int ?? api
            let features = (json["featuring"] as? [String: Any])?["systemfeatures"] as? [String: Any]
            let securedTransport = "\(features?["secured_transport"] ?? "")" == "true"
                || features?["secured_transport"] as? Bool == true
            return FoundTV(
                endpoint: TVEndpoint(host: host, secure: secure || securedTransport, api: major),
                info: TVInfo(name: (json["name"] as? String) ?? "Philips TV",
                             needsPairing: features?["pairing_type"] as? String == "digest_auth_pairing",
                             os: json["os_type"] as? String))
        }
        return nil
    }

    /// Für die Diagnose: Antwort bzw. Fehler je Versuch.
    static func probeReport(_ host: String) async -> [String] {
        var out: [String] = []
        for (secure, api) in [(true, 6), (false, 6), (false, 5), (false, 1)] {
            let c = PhilipsClient(endpoint: TVEndpoint(host: host, secure: secure, api: api))
            let label = "\(secure ? "https:1926" : "http:1925")/\(api)/system"
            do {
                let data = try await c.request("system", method: "GET", json: nil, session: probeSession)
                out.append("\(label): OK \(String(decoding: data.prefix(160), as: UTF8.self))")
            } catch let e as PhilipsError {
                out.append("\(label): \(e.errorDescription ?? "\(e)")")
            } catch {
                out.append("\(label): \(error.localizedDescription)")
            }
        }
        return out
    }

    // MARK: Koppeln

    func pairRequest(deviceName: String) async throws -> PairingSession {
        let id = Self.randomID()
        let device = ["device_name": deviceName, "device_os": "iOS", "type": "native", "id": id,
                      "app_id": "com.selfhosted.philipsremote", "app_name": "Philips Remote"]
        let body: [String: Any] = ["access": ["scope": ["read", "write", "control"]], "device": device]
        let data = try await request("pair/request", method: "POST", json: body, authenticate: false)
        guard let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PhilipsError.badResponse }
        let error = r["error_id"] as? String ?? "?"
        guard error == "SUCCESS" else { throw PhilipsError.pairing(error) }
        guard let key = r["auth_key"] as? String, let ts = Self.int(r["timestamp"]) else { throw PhilipsError.badResponse }
        return PairingSession(deviceID: id, authKey: key, timestamp: ts, device: device)
    }

    func pairGrant(_ s: PairingSession, pin: String) async throws -> Credentials {
        let pin = pin.filter(\.isNumber)
        let creds = Credentials(user: s.deviceID, password: s.authKey)
        let auth: [String: Any] = ["auth_appId": "1", "auth_timestamp": s.timestamp,
                                   "auth_signature": Self.signature(timestamp: s.timestamp, pin: pin), "pin": pin]
        var c = self
        c.credentials = creds
        let data = try await c.request("pair/grant", method: "POST", json: ["auth": auth, "device": s.device])
        guard let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PhilipsError.badResponse }
        let error = r["error_id"] as? String ?? "?"
        guard error == "SUCCESS" else { throw PhilipsError.pairing(error) }
        return creds
    }

    /// Base64(HMAC-SHA1(sharedKey, timestamp + pin)) – wie ha-philipsjs `hmac_signature`.
    static func signature(timestamp: Int, pin: String) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("\(timestamp)\(pin)".utf8),
                                                         using: SymmetricKey(data: sharedKey))
        return Data(mac).base64EncodedString()
    }

    // MARK: Befehle

    func info() async throws -> TVInfo {
        guard let json = try await getJSON("system") as? [String: Any] else { throw PhilipsError.badResponse }
        let features = (json["featuring"] as? [String: Any])?["systemfeatures"] as? [String: Any]
        return TVInfo(name: (json["name"] as? String) ?? "Philips TV",
                      needsPairing: features?["pairing_type"] as? String == "digest_auth_pairing",
                      os: json["os_type"] as? String)
    }

    func send(_ key: String) async throws {
        _ = try await request("input/key", method: "POST", json: ["key": key])
    }

    func volume() async throws -> Volume {
        guard let j = try await getJSON("audio/volume") as? [String: Any],
              let current = Self.int(j["current"]) else { throw PhilipsError.badResponse }
        return Volume(current: current, min: Self.int(j["min"]) ?? 0, max: Self.int(j["max"]) ?? 60,
                      muted: j["muted"] as? Bool ?? false)
    }

    func setVolume(_ n: Int, muted: Bool = false) async throws {
        _ = try await request("audio/volume", method: "POST", json: ["current": n, "muted": muted])
    }

    /// "On", "Standby", "StandbyKeep" … (ab API 5; ältere TVs kennen das nicht).
    func powerState() async throws -> String {
        guard endpoint.api >= 5 else { throw PhilipsError.rejected(404) }
        guard let j = try await getJSON("powerstate") as? [String: Any], let s = j["powerstate"] as? String else {
            throw PhilipsError.badResponse
        }
        return s
    }

    func setPower(_ on: Bool) async throws {
        _ = try await request("powerstate", method: "POST", json: ["powerstate": on ? "On" : "Standby"])
    }

    /// MAC für Wake-on-LAN aus `network/devices` (passend zur IP, sonst die erste).
    func mac() async throws -> String? {
        guard let list = try await getJSON("network/devices") as? [[String: Any]] else { return nil }
        let macs = list.compactMap { d -> (String, String?)? in
            guard let m = (d["mac"] as? String).flatMap(Self.formatMAC) else { return nil }
            return (m, d["ip-address"] as? String ?? d["ip"] as? String)
        }
        return (macs.first { $0.1 == endpoint.host } ?? macs.first)?.0
    }

    // MARK: Hilfen

    /// "192,168,178,40" (deutsche Zifferntastatur) → "192.168.178.40"; nil, wenn keine IPv4.
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ p in
            Int(p).map { (0...255).contains($0) && String($0) == String(p) } ?? false
        }) else { return nil }
        return s
    }

    /// Beliebige Schreibweise → "AA:BB:CC:DD:EE:FF"; nil, wenn keine gültige MAC.
    static func formatMAC(_ raw: String) -> String? {
        let hex = Array(raw.uppercased().filter(\.isHexDigit))
        guard hex.count == 12, hex.contains(where: { $0 != "0" }) else { return nil }
        return stride(from: 0, to: 12, by: 2).map { String(hex[$0..<$0 + 2]) }.joined(separator: ":")
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func randomID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    private var baseURL: String {
        "\(endpoint.secure ? "https" : "http")://\(endpoint.host):\(endpoint.secure ? ports.https : ports.http)"
    }

    private func getJSON(_ path: String, session: URLSession = PhilipsClient.session) async throws -> Any {
        let data = try await request(path, method: "GET", json: nil, session: session)
        guard let j = try? JSONSerialization.jsonObject(with: data) else { throw PhilipsError.badResponse }
        return j
    }

    /// Ein Aufruf; mit Zugangsdaten wird bei 401 die Digest-Antwort berechnet und einmal wiederholt.
    @discardableResult
    func request(_ path: String, method: String, json: Any?, authenticate: Bool = true,
                 session: URLSession = PhilipsClient.session) async throws -> Data {
        let uri = "/\(endpoint.api)/\(path)"
        guard let url = URL(string: baseURL + uri) else { throw PhilipsError.invalidHost }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let creds = authenticate ? credentials : nil
        if let creds, let header = DigestAuth.cached(for: endpoint.host, creds: creds, method: method, uri: uri) {
            req.setValue(header, forHTTPHeaderField: "Authorization")
        }
        var (data, resp) = try await load(req, session: session)
        if resp.statusCode == 401, let creds,
           let challenge = resp.value(forHTTPHeaderField: "WWW-Authenticate"),
           let header = DigestAuth.answer(challenge, host: endpoint.host, creds: creds, method: method, uri: uri) {
            req.setValue(header, forHTTPHeaderField: "Authorization")
            (data, resp) = try await load(req, session: session)
        }
        switch resp.statusCode {
        case 200...299: return data
        case 401: throw PhilipsError.unauthorized
        default: throw PhilipsError.rejected(resp.statusCode)
        }
    }

    private func load(_ req: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PhilipsError.badResponse }
            return (data, http)
        } catch let e as URLError {
            throw PhilipsError.unreachable(Self.describe(e))
        }
    }

    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .timedOut: "keine Antwort"
        case .cannotConnectToHost: "Verbindung abgelehnt"
        case .notConnectedToInternet: "kein Netz – „Lokales Netzwerk“ für die App erlaubt?"
        case .networkConnectionLost: "Verbindung abgebrochen"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            "TLS-Fehler \(e.code.rawValue)"
        default: "\(e.localizedDescription) [\(e.code.rawValue)]"
        }
    }
}

/// Die TVs nutzen ein selbstsigniertes Zertifikat – im lokalen Netz akzeptieren.
final class SelfSignedTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

/// HTTP-Digest (MD5, qop=auth) mit zwischengespeicherter Nonce je TV, damit nicht jeder Tastendruck zwei Anfragen braucht.
enum DigestAuth {
    private struct Challenge {
        var realm: String
        var nonce: String
        var qop: String?
        var opaque: String?
        var count: Int
    }

    private static let lock = NSLock()
    private static var challenges: [String: Challenge] = [:]

    static func answer(_ header: String, host: String, creds: Credentials, method: String, uri: String) -> String? {
        let p = parse(header)
        guard header.lowercased().hasPrefix("digest"), let nonce = p["nonce"] else { return nil }
        let qop = p["qop"].flatMap { q in q.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") ? "auth" : nil }
        lock.lock()
        challenges[host] = Challenge(realm: p["realm"] ?? "", nonce: nonce, qop: qop, opaque: p["opaque"], count: 0)
        lock.unlock()
        return cached(for: host, creds: creds, method: method, uri: uri)
    }

    static func cached(for host: String, creds: Credentials, method: String, uri: String) -> String? {
        lock.lock()
        guard var c = challenges[host] else { lock.unlock(); return nil }
        c.count += 1
        challenges[host] = c
        lock.unlock()

        let ha1 = md5("\(creds.user):\(c.realm):\(creds.password)")
        let ha2 = md5("\(method):\(uri)")
        var parts = ["username=\"\(creds.user)\"", "realm=\"\(c.realm)\"", "nonce=\"\(c.nonce)\"", "uri=\"\(uri)\"", "algorithm=MD5"]
        if let qop = c.qop {
            let nc = String(format: "%08x", c.count)
            let cnonce = String(format: "%016llx", UInt64.random(in: 0...UInt64.max))
            parts.append("response=\"\(md5("\(ha1):\(c.nonce):\(nc):\(cnonce):\(qop):\(ha2)"))\"")
            parts += ["qop=\(qop)", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
        } else {
            parts.append("response=\"\(md5("\(ha1):\(c.nonce):\(ha2)"))\"")
        }
        if let opaque = c.opaque { parts.append("opaque=\"\(opaque)\"") }
        return "Digest " + parts.joined(separator: ", ")
    }

    static func forget(_ host: String) {
        lock.lock()
        challenges[host] = nil
        lock.unlock()
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `Digest realm="XTV", qop="auth", nonce="…"` → [realm: XTV, qop: auth, nonce: …]
    static func parse(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        let body = header.drop { !$0.isWhitespace }
        let re = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]*))"#)
        let s = String(body)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s) else { continue }
            let v = Range(m.range(at: 2), in: s) ?? Range(m.range(at: 3), in: s)
            out[String(s[k]).lowercased()] = v.map { String(s[$0]) } ?? ""
        }
        return out
    }
}

/// Magic Packet: 6 × 0xFF + 16 × MAC (getrennt von WakeOnLAN, damit es auch unter Linux testbar ist).
enum WakeOnLANPacket {
    static func bytes(mac: String) -> Data? {
        guard let formatted = PhilipsClient.formatMAC(mac) else { return nil }
        let macBytes = formatted.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        var bytes = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { bytes += macBytes }
        return Data(bytes)
    }
}
