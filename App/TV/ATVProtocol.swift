import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Android-TV-Fernbedienungsprotokoll v2 (wie die Google-TV-App, geprüft gegen androidtvremote2):
/// Kopplung auf Port 6467 („polo“), Steuerung auf 6466, beides TLS mit eigenem Client-Zertifikat,
/// Nachrichten = Protobuf mit Varint-Längenpräfix. Dieser Teil ist plattformneutral (auch unter Linux testbar).
enum ATV {
    static let remotePort = 6466
    static let pairingPort = 6467
    static let commonName = "PhilipsRemote"

    // MARK: Kopplung (polo.proto, OuterMessage)

    private static func outer(_ body: (inout Proto.Writer) -> Void) -> Data {
        var w = Proto.Writer()
        w.field(1, varint: 2)      // protocol_version
        w.field(2, varint: 200)    // STATUS_OK
        body(&w)
        return w.data
    }

    private static func hexEncoding(_ w: inout Proto.Writer) {
        w.field(1, varint: 3)      // ENCODING_TYPE_HEXADECIMAL
        w.field(2, varint: 6)      // symbol_length
    }

    static func pairingRequest(clientName: String) -> Data {
        outer { $0.field(10) { r in r.field(1, string: "atvremote"); r.field(2, string: clientName) } }
    }

    static func pairingOptions() -> Data {
        outer { $0.field(20) { o in o.field(1) { hexEncoding(&$0) }; o.field(3, varint: 1) } }  // ROLE_TYPE_INPUT
    }

    static func pairingConfiguration() -> Data {
        outer { $0.field(30) { c in c.field(1) { hexEncoding(&$0) }; c.field(2, varint: 1) } }
    }

    static func pairingSecret(_ secret: Data) -> Data {
        outer { $0.field(40) { $0.field(1, bytes: secret) } }
    }

    enum PairingReply: Equatable {
        case requestAck, options, configurationAck, secretAck
        case error(Int)
    }

    static func parsePairing(_ data: Data) -> PairingReply? {
        guard let m = Proto.Message(data) else { return nil }
        let status = Int(m.int(2) ?? 0)
        guard status == 200 else { return .error(status) }
        if m.has(11) { return .requestAck }
        if m.has(20) { return .options }
        if m.has(31) { return .configurationAck }
        if m.has(41) { return .secretAck }
        return nil
    }

    /// SHA-256(Client-Modulus, Client-Exponent, Server-Modulus, Server-Exponent, Code[2…]);
    /// das erste Byte muss den ersten beiden Code-Zeichen entsprechen (sonst Tippfehler im Code).
    static func secret(client: RSAPublic, server: RSAPublic, code raw: String) -> Data? {
        let code = raw.uppercased().filter(\.isHexDigit)
        guard code.count == 6, let check = UInt8(code.prefix(2), radix: 16), let tail = hexBytes(String(code.dropFirst(2))) else {
            return nil
        }
        var h = SHA256()
        for part in [client.modulus, client.exponent, server.modulus, server.exponent] { h.update(data: part) }
        h.update(data: tail)
        let digest = Data(h.finalize())
        return digest.first == check ? digest : nil
    }

    static func hexBytes(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    // MARK: Steuerung (remotemessage.proto, RemoteMessage)

    /// PING | KEY | POWER | VOLUME | APP_LINK
    static let features: UInt64 = 1 | 2 | 32 | 64 | 512

    static func configureReply(tvFeatures: UInt64) -> Data {
        var w = Proto.Writer()
        w.field(1) { c in
            c.field(1, varint: tvFeatures == 0 ? features : tvFeatures & features)
            c.field(2) { d in
                d.field(3, varint: 1)
                d.field(4, string: "1")
                d.field(5, string: "atvremote")
                d.field(6, string: "1.0.0")
            }
        }
        return w.data
    }

    static func setActiveReply(tvFeatures: UInt64) -> Data {
        var w = Proto.Writer()
        w.field(2) { $0.field(1, varint: tvFeatures == 0 ? features : tvFeatures & features) }
        return w.data
    }

    static func pingReply(_ val: UInt64) -> Data {
        var w = Proto.Writer()
        w.field(9) { $0.field(1, varint: val) }
        return w.data
    }

    static func keyPress(_ code: Int) -> Data {
        var w = Proto.Writer()
        w.field(10) { $0.field(1, varint: UInt64(code)); $0.field(2, varint: 3) }  // SHORT
        return w.data
    }

    static func appLink(_ link: String) -> Data {
        var w = Proto.Writer()
        w.field(90) { $0.field(1, string: link) }
        return w.data
    }

    enum RemoteEvent: Equatable {
        case configure(features: UInt64, model: String?, vendor: String?)
        case setActive
        case ping(UInt64)
        case started(Bool)
        case volume(level: Int, max: Int, muted: Bool)
        case error
        case other
    }

    static func parseRemote(_ data: Data) -> RemoteEvent? {
        guard let m = Proto.Message(data) else { return nil }
        if let c = m.message(1) {
            let info = c.message(2)
            return .configure(features: c.int(1) ?? 0, model: info?.string(1), vendor: info?.string(2))
        }
        if m.has(2) { return .setActive }
        if m.has(3) { return .error }
        if m.has(8) { return .ping(m.message(8)?.int(1) ?? 0) }
        if m.has(40) { return .started(m.message(40)?.int(1) == 1) }
        if let v = m.message(50) {
            return .volume(level: Int(v.int(7) ?? 0), max: Int(v.int(6) ?? 100), muted: v.int(8) == 1)
        }
        return .other
    }
}

/// RSA-Public-Key als minimale Big-Endian-Bytes (ohne führende Nullen).
struct RSAPublic: Equatable {
    var modulus: Data
    var exponent: Data

    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`
    init?(pkcs1 der: Data) {
        var r = DER.Reader(Array(der))
        guard let seq = r.read(tag: 0x30) else { return nil }
        var inner = DER.Reader(seq)
        guard let n = inner.read(tag: 0x02), let e = inner.read(tag: 0x02) else { return nil }
        modulus = Data(n.drop { $0 == 0 })
        exponent = Data(e.drop { $0 == 0 })
    }
}

// MARK: Protobuf (nur was das Protokoll braucht)

enum Proto {
    struct Writer {
        var data = Data()

        mutating func varint(_ v: UInt64) { data.append(Proto.varint(v)) }

        mutating func field(_ n: Int, varint v: UInt64) {
            varint(UInt64(n) << 3)
            varint(v)
        }

        mutating func field(_ n: Int, bytes d: Data) {
            varint(UInt64(n) << 3 | 2)
            varint(UInt64(d.count))
            data.append(d)
        }

        mutating func field(_ n: Int, string s: String) { field(n, bytes: Data(s.utf8)) }

        mutating func field(_ n: Int, _ build: (inout Writer) -> Void) {
            var w = Writer()
            build(&w)
            field(n, bytes: w.data)
        }
    }

    enum Value { case varint(UInt64), bytes(Data) }

    struct Message {
        var fields: [Int: [Value]] = [:]

        init?(_ data: Data) {
            let b = [UInt8](data)
            var i = 0
            while i < b.count {
                guard let key = Proto.readVarint(b, &i) else { return nil }
                let n = Int(key >> 3)
                switch key & 7 {
                case 0:
                    guard let v = Proto.readVarint(b, &i) else { return nil }
                    fields[n, default: []].append(.varint(v))
                case 2:
                    guard let len = Proto.readVarint(b, &i), len <= UInt64(b.count - i) else { return nil }
                    fields[n, default: []].append(.bytes(Data(b[i ..< i + Int(len)])))
                    i += Int(len)
                case 1:
                    guard i + 8 <= b.count else { return nil }
                    i += 8
                case 5:
                    guard i + 4 <= b.count else { return nil }
                    i += 4
                default:
                    return nil
                }
            }
        }

        func has(_ n: Int) -> Bool { fields[n] != nil }

        func int(_ n: Int) -> UInt64? {
            if case .varint(let v) = fields[n]?.last { return v }
            return nil
        }

        func bytes(_ n: Int) -> Data? {
            if case .bytes(let d) = fields[n]?.last { return d }
            return nil
        }

        func string(_ n: Int) -> String? { bytes(n).map { String(decoding: $0, as: UTF8.self) } }

        func message(_ n: Int) -> Message? { bytes(n).flatMap(Message.init) }
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func frame(_ message: Data) -> Data { varint(UInt64(message.count)) + message }

    /// Zerlegt den TLS-Datenstrom in Nachrichten (Teilstücke werden gepuffert).
    struct Deframer {
        private var buffer: [UInt8] = []

        mutating func push(_ data: Data) -> [Data] {
            buffer += data
            var out: [Data] = []
            while true {
                var i = 0
                guard let len = Proto.readVarint(buffer, &i), buffer.count - i >= Int(len) else { break }
                out.append(Data(buffer[i ..< i + Int(len)]))
                buffer.removeFirst(i + Int(len))
            }
            return out
        }
    }
}

// MARK: DER / X.509 (selbstsigniertes Client-Zertifikat)

enum DER {
    struct Reader {
        private let b: [UInt8]
        private var i = 0
        init(_ bytes: [UInt8]) { b = bytes }

        mutating func read(tag: UInt8) -> [UInt8]? {
            guard i < b.count, b[i] == tag, i + 1 < b.count else { return nil }
            i += 1
            var len = Int(b[i])
            i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, i + n <= b.count else { return nil }
                len = b[i ..< i + n].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            guard i + len <= b.count else { return nil }
            defer { i += len }
            return Array(b[i ..< i + len])
        }
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var len: [UInt8]
        if content.count < 0x80 {
            len = [UInt8(content.count)]
        } else {
            var n = content.count
            var bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            len = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + len + content
    }

    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func integer(_ n: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = n
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v != 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }
    static let null: [UInt8] = [0x05, 0x00]
    static let sha256WithRSA: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let commonNameOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
    static let basicConstraintsOID: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x13]

    static func utcTime(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(f.string(from: date).utf8))
    }

    /// X.509 v3, sha256WithRSAEncryption, CN = `commonName`, CA:TRUE, 10 Jahre gültig (wie androidtvremote2).
    static func selfSignedCertificate(publicKeyPKCS1: Data, commonName: String, now: Date = Date(),
                                      sign: (Data) throws -> Data) rethrows -> Data {
        let name = seq(tlv(0x31, seq(commonNameOID, tlv(0x0C, Array(commonName.utf8)))))
        let algorithm = seq(sha256WithRSA, null)
        let spki = seq(seq(rsaEncryption, null), tlv(0x03, [0x00] + Array(publicKeyPKCS1)))
        let basicConstraints = seq(basicConstraintsOID, tlv(0x04, seq(tlv(0x01, [0xFF]))))
        let tbs = seq(
            tlv(0xA0, integer(2)),
            integer(UInt64(now.timeIntervalSince1970)),
            algorithm,
            name,
            seq(utcTime(now.addingTimeInterval(-86_400)), utcTime(now.addingTimeInterval(10 * 365 * 86_400))),
            name,
            spki,
            tlv(0xA3, seq(basicConstraints))
        )
        let signature = try sign(Data(tbs))
        return Data(seq(tbs, algorithm, tlv(0x03, [0x00] + Array(signature))))
    }

    static func pem(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }
}
