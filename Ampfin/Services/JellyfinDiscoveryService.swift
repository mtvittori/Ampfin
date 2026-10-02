import Foundation
import Network

/// Discovered Jellyfin server info
struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let endpointAddress: String?
}

/// Discovers Jellyfin servers on the local network by scanning common local IPs
/// and probing the Jellyfin public info endpoint.
@MainActor
final class JellyfinDiscoveryService: ObservableObject {
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isSearching: Bool = false

    private var searchTask: Task<Void, Never>?
    private let jellyfinPorts = [8096, 8920]
    private let publicInfoPath = "/System/Info/Public"

    func startDiscovery() {
        stopDiscovery()
        discoveredServers = []
        isSearching = true

        searchTask = Task {
            await scanLocalNetwork()
            if !Task.isCancelled {
                isSearching = false
            }
        }
    }

    func stopDiscovery() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    // MARK: - HTTP-based subnet scanning

    private func scanLocalNetwork() async {
        // Get the device's local IP to determine the subnet
        let localIP = getLocalIPAddress()
        let subnet = subnetPrefix(from: localIP ?? "192.168.1.1")

        print("[Discovery] Scanning subnet \(subnet).x on ports \(jellyfinPorts)")

        // Scan IPs 1-254 in parallel batches
        await withTaskGroup(of: DiscoveredServer?.self) { group in
            for i in 1...254 {
                if Task.isCancelled { break }
                let ip = "\(subnet).\(i)"
                for port in jellyfinPorts {
                    group.addTask {
                        await self.probeJellyfin(ip: ip, port: port)
                    }
                }
            }

            for await result in group {
                if let server = result {
                    if !discoveredServers.contains(where: { $0.id == server.id }) {
                        discoveredServers.append(server)
                        print("[Discovery] Found: \(server.name) at \(server.address)")
                    }
                }
            }
        }

        print("[Discovery] Scan complete, found \(discoveredServers.count) server(s)")
    }

    private func probeJellyfin(ip: String, port: Int) async -> DiscoveredServer? {
        let urlString = "http://\(ip):\(port)\(publicInfoPath)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"

        do {
            let (data, response) = try await JellyfinAPIService.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let serverName = json["ServerName"] as? String,
                  let serverId = json["Id"] as? String else { return nil }

            let address = "http://\(ip):\(port)"
            return DiscoveredServer(
                id: serverId,
                name: serverName,
                address: address,
                endpointAddress: ip
            )
        } catch {
            return nil
        }
    }

    // MARK: - Network Helpers

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" { // Wi-Fi interfaces
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    private func subnetPrefix(from ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "192.168.1" }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private func parseDiscoveryResponse(_ data: Data) -> DiscoveredServer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["Id"] as? String,
              let name = json["Name"] as? String,
              let address = json["Address"] as? String else {
            return nil
        }
        let endpoint = json["EndpointAddress"] as? String
        return DiscoveredServer(id: id, name: name, address: address, endpointAddress: endpoint)
    }
}
