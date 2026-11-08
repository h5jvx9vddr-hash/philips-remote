import Foundation
import Network

/// Magic Packet an die TV-IP (Unicast) und an die Subnetz-Broadcast-Adresse.
/// Broadcast braucht unter iOS eigentlich das Multicast-Entitlement – schlägt er fehl, bleibt der Unicast.
enum WakeOnLAN {
    static func send(mac: String, host: String) async {
        guard let data = WakeOnLANPacket.bytes(mac: mac) else { return }
        var targets = [host]
        let parts = host.split(separator: ".")
        if parts.count == 4 { targets.append(parts.dropLast().joined(separator: ".") + ".255") }
        for target in targets {
            for port: UInt16 in [9, 7] { fire(data, to: target, port: port) }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func fire(_ data: Data, to host: String, port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
            case .failed, .waiting:
                conn.cancel()
            case .cancelled:
                conn.stateUpdateHandler = nil
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { conn.cancel() }
    }
}
