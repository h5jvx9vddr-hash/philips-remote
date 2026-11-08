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
                    let open = await openHosts(batch, ports: [ports.http, ports.https])
                    await withTaskGroup(of: FoundTV?.self) { group in
                        for host in open { group.addTask { await PhilipsClient.probe(host, ports: ports) } }
                        for await tv in group { if let tv { cont.yield(tv) } }
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Alle Treffer eines kompletten Suchlaufs.
    static func findAll(hosts: [String]? = nil, ports: PhilipsPorts = .standard) async -> [FoundTV] {
        var out: [FoundTV] = []
        for await tv in scan(hosts: hosts, ports: ports) { out.append(tv) }
        return out
    }

    /// Hosts, bei denen mindestens einer der Ports eine TCP-Verbindung annimmt.
    static func openHosts(_ hosts: [String], ports: [Int], timeout: Double = 1.2) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: probePorts(hosts, ports: ports, timeout: timeout))
            }
        }
    }

    /// Nicht blockierende connect()-Aufrufe für alle Ziele, dann gemeinsam per poll() warten.
    private static func probePorts(_ hosts: [String], ports: [Int], timeout: Double) -> [String] {
        var sockets: [(fd: Int32, host: String)] = []
        defer { for s in sockets { close(s.fd) } }
        var open = Set<String>()

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
                    open.insert(host)
                    close(fd)
                } else if errno == EINPROGRESS {
                    sockets.append((fd, host))
                } else {
                    close(fd)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var pending = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        var hostOf = Dictionary(uniqueKeysWithValues: sockets.map { ($0.fd, $0.host) })
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
                if err == 0, let h = hostOf[p.fd] { open.insert(h) }
                hostOf[p.fd] = nil
            }
            pending = still
        }
        return hosts.filter(open.contains)
    }
}
