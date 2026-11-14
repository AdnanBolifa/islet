import Darwin
import Foundation

public struct NetworkSampler {
    private var previous: (received: UInt64, sent: UInt64, time: TimeInterval)?

    public init() {}

    /// Download/upload speed in bytes per second since the previous call. The first call returns zeros.
    public mutating func sample() -> (down: Double, up: Double) {
        var received: UInt64 = 0, sent: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor?.pointee {
            // Only physical Wi-Fi/Ethernet ("en*"); VPN tunnels would count the same traffic twice.
            if entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               String(cString: entry.ifa_name).hasPrefix("en"),
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                received += UInt64(data.ifi_ibytes)
                sent += UInt64(data.ifi_obytes)
            }
            cursor = entry.ifa_next
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (received, sent, now) }
        guard let last = previous, now > last.time else { return (0, 0) }
        let seconds = now - last.time
        // shortcut: kernel counters are 32-bit and wrap at 4 GB; a wrapped tick reads as 0 instead of a spike.
        return (Double(received > last.received ? received - last.received : 0) / seconds,
                Double(sent > last.sent ? sent - last.sent : 0) / seconds)
    }
}
