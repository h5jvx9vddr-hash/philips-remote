import Foundation
import Network
import Security

enum ATVError: LocalizedError, Equatable {
    case identity(String)
    case unreachable(String)
    case notPaired
    case badCode
    case pairing(String)
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .identity(let why): "Zertifikat konnte nicht angelegt werden (\(why))."
        case .unreachable(let why): "Gerät nicht erreichbar (\(why))."
        case .notPaired: "Das Gerät kennt diese App noch nicht – bitte koppeln."
        case .badCode: "Der Code passt nicht – bitte genau so eingeben, wie er am Bildschirm steht (0–9, A–F)."
        case .pairing(let why): "Kopplung fehlgeschlagen (\(why))."
        case .timeout: "Keine Antwort vom Gerät."
        case .closed: "Verbindung wurde getrennt."
        }
    }
}

/// Eigenes Client-Zertifikat (RSA 2048, im Schlüsselbund); das Android-TV merkt es sich beim Koppeln.
enum ATVIdentity {
    private static let tag = Data("com.selfhosted.philipsremote.atv".utf8)
    private static let lock = NSLock()

    static func get() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let id = find() { return id }
        // Halbe Reste (Schlüssel ohne Zertifikat) aufräumen und neu anlegen.
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: ATV.commonName] as CFDictionary)
        try create()
        guard let id = find() else { throw ATVError.identity("Identität nicht gefunden") }
        return id
    }

    static func publicKey(of identity: SecIdentity) -> RSAPublic? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
              let key = SecCertificateCopyKey(cert),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return RSAPublic(pkcs1: der)
    }

    static func certificatePEM(of identity: SecIdentity) -> String? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
        return DER.pem(SecCertificateCopyData(cert) as Data)
    }

    private static func find() -> SecIdentity? {
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let ids = result as? [SecIdentity] else { return nil }
        return ids.first { id in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert else { return false }
            return SecCertificateCopySubjectSummary(cert) as String? == ATV.commonName
        }
    }

    private static func create() throws {
        var keyAttrs: [CFString: Any] = [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrLabel: ATV.commonName]
        #if os(iOS)
        keyAttrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
                                      kSecPrivateKeyAttrs: keyAttrs]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw ATVError.identity(error.map { "\($0.takeRetainedValue())" } ?? "Schlüssel")
        }
        let der = try DER.selfSignedCertificate(publicKeyPKCS1: pkcs1, commonName: ATV.commonName) { tbs in
            var e: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &e) as Data? else {
                throw ATVError.identity(e.map { "\($0.takeRetainedValue())" } ?? "Signatur")
            }
            return sig
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw ATVError.identity("Zertifikat ungültig") }
        let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecAttrLabel: ATV.commonName] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw ATVError.identity("SecItemAdd \(status)") }
    }
}

/// Einmal-Ergebnis, auf das async gewartet werden kann (mit Zeitlimit).
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func fire(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: r)
    }

    func wait(timeout: Double) async throws -> T {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.fire(.failure(ATVError.timeout))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(with: result)
            } else {
                cont = c
                lock.unlock()
            }
        }
    }
}

/// TLS-Verbindung mit Client-Zertifikat; merkt sich den Server-Schlüssel (für die Kopplungs-Prüfsumme).
final class ATVLink: @unchecked Sendable {
    let queue = DispatchQueue(label: "atv.link")
    private var conn: NWConnection?
    private var deframer = Proto.Deframer()
    private(set) var serverKey: RSAPublic?
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var closed = false

    func start(host: String, port: Int, identity: SecIdentity) async throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let id = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, id) }
        sec_protocol_options_set_verify_block(sec, { [weak self] _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let cert = chain.first,
               let key = SecCertificateCopyKey(cert), let der = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                self?.serverKey = RSAPublic(pkcs1: der)
            }
            complete(true)  // selbstsigniert, nur im lokalen Netz
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 4
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!,
                             using: NWParameters(tls: tls, tcp: tcp))
        conn = c
        let ready = OneShot<Void>()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.fire(.success(()))
            case .waiting(let e), .failed(let e):
                ready.fire(.failure(Self.map(e)))
                self?.close(Self.map(e))
            case .cancelled:
                ready.fire(.failure(ATVError.closed))
            default:
                break
            }
        }
        c.start(queue: queue)
        try await ready.wait(timeout: 6)
        receive()
    }

    func send(_ message: Data) {
        conn?.send(content: Proto.frame(message), completion: .contentProcessed { _ in })
    }

    func close(_ error: Error? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            conn?.cancel()
            onClose?(error)
            onMessage = nil
            onClose = nil
        }
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for m in self.deframer.push(data) { self.onMessage?(m) }
            }
            if complete || error != nil {
                self.close(error.map(Self.map) ?? ATVError.closed)
            } else {
                self.receive()
            }
        }
    }

    static func map(_ e: NWError) -> ATVError {
        switch e {
        case .tls: .notPaired
        case .posix(let code) where code == .ECONNREFUSED: .unreachable("Verbindung abgelehnt")
        case .posix(let code) where code == .ETIMEDOUT: .unreachable("keine Antwort")
        default: .unreachable(e.localizedDescription)
        }
    }

    static func map(_ e: Error) -> ATVError {
        if let n = e as? NWError { return map(n) }
        return (e as? ATVError) ?? .unreachable(e.localizedDescription)
    }
}

/// Kopplung: Anfrage → Gerät zeigt 6-stelligen Code → `finish(code:)`.
final class ATVPairing: @unchecked Sendable {
    private let link = ATVLink()
    private let identity: SecIdentity
    private let shown = OneShot<Void>()
    private let done = OneShot<Void>()

    private init(identity: SecIdentity) { self.identity = identity }

    static func start(host: String, port: Int = ATV.pairingPort, clientName: String) async throws -> ATVPairing {
        let p = ATVPairing(identity: try ATVIdentity.get())
        p.link.onMessage = { [weak p] data in p?.handle(data) }
        p.link.onClose = { [weak p] error in
            let e = (error as? ATVError) ?? .closed
            p?.shown.fire(.failure(e))
            p?.done.fire(.failure(e))
        }
        try await p.link.start(host: host, port: port, identity: p.identity)
        p.link.send(ATV.pairingRequest(clientName: clientName))
        try await p.shown.wait(timeout: 10)
        return p
    }

    func finish(code: String) async throws {
        guard let client = ATVIdentity.publicKey(of: identity), let server = link.serverKey else {
            throw ATVError.pairing("Schlüssel fehlen")
        }
        guard let secret = ATV.secret(client: client, server: server, code: code) else { throw ATVError.badCode }
        link.send(ATV.pairingSecret(secret))
        defer { link.close() }
        try await done.wait(timeout: 10)
    }

    func cancel() { link.close() }

    private func handle(_ data: Data) {
        switch ATV.parsePairing(data) {
        case .requestAck: link.send(ATV.pairingOptions())
        case .options: link.send(ATV.pairingConfiguration())
        case .configurationAck: shown.fire(.success(()))
        case .secretAck: done.fire(.success(()))
        case .error(let status):
            let e: ATVError = status == 402 ? .badCode : .pairing("Status \(status)")
            shown.fire(.failure(e))
            done.fire(.failure(e))
            link.close()
        case nil: break
        }
    }
}

/// Dauerhafte Steuerverbindung (Port 6466): beantwortet Konfiguration und Pings, liefert Lautstärke und Ein/Aus.
final class ATVRemote: @unchecked Sendable {
    let host: String
    let port: Int
    private let link = ATVLink()
    private let ready = OneShot<Void>()
    private var features: UInt64 = 0
    var onVolume: ((Int, Int, Bool) -> Void)?
    var onPower: ((Bool) -> Void)?
    var onClose: ((ATVError) -> Void)?
    private(set) var isOpen = false
    private(set) var device: String?

    init(host: String, port: Int = ATV.remotePort) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        link.onMessage = { [weak self] data in self?.handle(data) }
        link.onClose = { [weak self] error in
            guard let self else { return }
            let e = (error as? ATVError) ?? .closed
            // Bricht das Gerät vor der Konfiguration ab, kennt es unser Zertifikat nicht.
            self.ready.fire(.failure(e == .closed ? .notPaired : e))
            self.isOpen = false
            self.onClose?(e)
        }
        try await link.start(host: host, port: port, identity: try ATVIdentity.get())
        try await ready.wait(timeout: 6)
        isOpen = true
    }

    func press(_ keyCode: Int) {
        link.queue.async { [self] in link.send(ATV.keyPress(keyCode)) }
    }

    func open(_ appLink: String) {
        link.queue.async { [self] in link.send(ATV.appLink(appLink)) }
    }

    func close() {
        isOpen = false
        link.close()
    }

    private func handle(_ data: Data) {
        switch ATV.parseRemote(data) {
        case .configure(let f, let model, let vendor):
            features = f
            device = [vendor, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            link.send(ATV.configureReply(tvFeatures: f))
        case .setActive:
            link.send(ATV.setActiveReply(tvFeatures: features))
            ready.fire(.success(()))
        case .ping(let v):
            link.send(ATV.pingReply(v))
        case .started(let on):
            ready.fire(.success(()))
            onPower?(on)
        case .volume(let level, let max, let muted):
            onVolume?(level, max, muted)
        case .error, .other, nil:
            break
        }
    }

    /// Einmal verbinden, Taste senden (nil = nur prüfen), trennen – für Kurzbefehle und die Suche.
    static func pressOnce(host: String, keyCode: Int?, port: Int = ATV.remotePort) async throws {
        let r = ATVRemote(host: host, port: port)
        try await r.connect()
        if let keyCode { r.press(keyCode) }
        try? await Task.sleep(for: .milliseconds(400))
        r.close()
    }
}
