import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Sucht Philips-TVs in allen eigenen IPv4-Netzen – WLAN (en0) und iPhone-Hotspot (bridge100, 172.20.10.x).
/// Ohne Multicast-Entitlement geht kein SSDP, deshalb: Ports 1925/1926 im Subnetz abklopfen, Treffer per `system` prüfen.
enum Discovery {
    struct Interface: Equatable {
        var name: String
        var address: UInt32
        var netmask: UInt32
        var isHotspot: Bool { name.hasPrefix("bridge") }
    }

    /// Hotspot zuerst (kleines Netz, schnell), dann WLAN/LAN.
    static func candidateHosts() -> [String] {
        var seen = Set<String>()
        return interfaces()
            .sorted { $0.isHotspot && !$1.isHotspot }
            .flatMap { hosts(address: $0.address, netmask: $0.netmask) }
            .filter { seen.insert($0).inserted }
    }

    /// Alle Hosts im Netz außer der eigenen Adresse; größere Netze als /24 nur im eigenen /24-Block.
    static func hosts(address: UInt32, netmask: UInt32) -> [String] {
        let mask = netmask.nonzeroBitCount < 24 ? 0xFFFF_FF00 : netmask
        guard mask.nonzeroBitCount <= 30 else { return [] }
        let network = address & mask
        let broadcast = network | ~mask
        return (network + 1 ..< broadcast).filter { $0 != address }.map(dotted)
    }

    static func dotted(_ a: UInt32) -> String {
        "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }

    static func parse(_ s: String) -> UInt32? {
        let p = s.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
        return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }

    static func interfaces() -> [Interface] {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [Interface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            let flags = Int32(i.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = i.ifa_netmask else { continue }
            let name = String(cString: i.ifa_name)
            // Mobilfunk, VPN, AirDrop & Co. auslassen
            guard !["pdp_ip", "utun", "ipsec", "llw", "awdl", "anpi"].contains(where: name.hasPrefix) else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.append(Interface(name: name, address: a, netmask: m))
        }
        return out
        #else
        return []
        #endif
    }

    /// Findet TVs nach und nach (Hosts in Blöcken, damit nicht zu viele Sockets gleichzeitig offen sind).
    static func scan(hosts: [String]? = nil, ports: PhilipsPorts = .standard) -> AsyncStream<FoundTV> {
        AsyncStream { cont in
            let task = Task.detached {
                let all = hosts ?? candidateHosts()
                for start in stride(from: 0, to: all.count, by: 64) {
                    if Task.isCancelled { break }
                    let batch = Array(all[start ..< min(start + 64, all.count)])
                    let open = await openPorts(batch, ports: [ports.http, ports.https, ports.atvRemote, ports.atvPairing])
                    await withTaskGroup(of: FoundTV?.self) { group in
                        for (host, p) in open { group.addTask { await identify(host, open: p, ports: ports) } }
                        for await tv in group { if let tv { cont.yield(tv) } }
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Philips (JointSPACE) hat Vorrang; sonst Android-/Google-TV-Gerät, falls dessen Fernbedienungsports offen sind.
    static func identify(_ host: String, open: Set<Int>, ports: PhilipsPorts) async -> FoundTV? {
        if !open.isDisjoint(with: [ports.http, ports.https]), let tv = await PhilipsClient.probe(host, ports: ports) {
            return tv
        }
        guard !open.isDisjoint(with: [ports.atvRemote, ports.atvPairing]) else { return nil }
        return FoundTV(endpoint: TVEndpoint(host: host, secure: true, api: 0, kind: .androidTV),
                       info: TVInfo(name: await castName(host) ?? "Android-TV-Gerät", needsPairing: true, os: "Android TV"))
    }

    /// Gerätename aus der Chromecast-Schnittstelle (z. B. „MagentaTV One“), falls verfügbar.
    static func castName(_ host: String) async -> String? {
        guard let url = URL(string: "http://\(host):8008/setup/eureka_info?params=name") else { return nil }
        guard let r = try? await PhilipsClient.probeSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: r.0) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// Alle Treffer eines kompletten Suchlaufs.
    static func findAll(hosts: [String]? = nil, ports: PhilipsPorts = .standard) async -> [FoundTV] {
        var out: [FoundTV] = []
        for await tv in scan(hosts: hosts, ports: ports) { out.append(tv) }
        return out
    }

    /// Hosts, bei denen mindestens einer der Ports eine TCP-Verbindung annimmt.
    static func openHosts(_ hosts: [String], ports: [Int], timeout: Double = 1.2) async -> [String] {
        let open = await openPorts(hosts, ports: ports, timeout: timeout)
        return hosts.filter { open[$0] != nil }
    }

    /// Host → offene Ports (nur Hosts mit mindestens einem offenen Port).
    static func openPorts(_ hosts: [String], ports: [Int], timeout: Double = 1.2) async -> [String: Set<Int>] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: probePorts(hosts, ports: ports, timeout: timeout))
            }
        }
    }

    /// Nicht blockierende connect()-Aufrufe für alle Ziele, dann gemeinsam per poll() warten.
    private static func probePorts(_ hosts: [String], ports: [Int], timeout: Double) -> [String: Set<Int>] {
        var sockets: [(fd: Int32, host: String, port: Int)] = []
        defer { for s in sockets { close(s.fd) } }
        var open: [String: Set<Int>] = [:]

        for host in hosts {
            var addr = sockaddr_in()
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { continue }
            for port in ports {
                #if canImport(Darwin)
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                #else
                let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                #endif
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                var a = addr
                #if canImport(Darwin)
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = UInt16(port).bigEndian
                let r = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if r == 0 {
                    open[host, default: []].insert(port)
                    close(fd)
                } else if errno == EINPROGRESS {
                    sockets.append((fd, host, port))
                } else {
                    close(fd)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var pending = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        var target = Dictionary(uniqueKeysWithValues: sockets.map { ($0.fd, ($0.host, $0.port)) })
        while !pending.isEmpty {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            let n = poll(&pending, nfds_t(pending.count), Int32(left * 1000))
            guard n > 0 else { break }
            var still: [pollfd] = []
            for p in pending {
                guard p.revents != 0 else { still.append(p); continue }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0, let t = target[p.fd] { open[t.0, default: []].insert(t.1) }
                target[p.fd] = nil
            }
            pending = still
        }
        return open
    }

    /// Was sieht die Suche? Für die Diagnose-Ansicht: Netze, alle Geräte mit TV-typischen Ports, Antwort auf `system`.
    static func diagnose() async -> String {
        var lines: [String] = []
        let ifs = interfaces()
        lines.append(ifs.isEmpty ? "Keine Netze gefunden (WLAN aus? Hotspot ohne verbundene Geräte?)" : "Netze:")
        for i in ifs {
            lines.append("  \(i.name): \(dotted(i.address)) / \(dotted(i.netmask))\(i.isHotspot ? " (Hotspot)" : "")")
        }
        let hosts = candidateHosts()
        lines.append("Geprüfte Adressen: \(hosts.count)")
        // 1925/1926 JointSPACE, 6466/6467 Android-TV-Fernbedienung, 8008/8009/8443 Chromecast, 80/9080 Sonstige
        let ports = [1925, 1926, 6466, 6467, 8008, 8009, 8443, 9080, 80]
        var found: [String: Set<Int>] = [:]
        for start in stride(from: 0, to: hosts.count, by: 18) {
            let batch = Array(hosts[start ..< min(start + 18, hosts.count)])
            found.merge(await openPorts(batch, ports: ports, timeout: 1.5)) { $0.union($1) }
        }
        if found.isEmpty { lines.append("Kein Gerät antwortet. iOS-Einstellungen → Datenschutz → Lokales Netzwerk → Philips TV an?") }
        for host in hosts where found[host] != nil {
            lines.append("\(host): Ports \(found[host]!.sorted().map(String.init).joined(separator: ", "))")
            if !found[host]!.isDisjoint(with: [1925, 1926]) {
                lines += await PhilipsClient.probeReport(host).map { "  " + $0 }
            }
            if let name = await castName(host) { lines.append("  Chromecast-Name: \(name)") }
        }
        return lines.joined(separator: "\n")
    }
}
