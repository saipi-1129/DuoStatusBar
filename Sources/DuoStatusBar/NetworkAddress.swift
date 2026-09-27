import Darwin

enum LocalNetworkAddress {
    static func ipv4(forInterface interfaceName: String) -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0 else { return nil }
        defer { freeifaddrs(addressList) }

        var current = addressList
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }

            guard let name = interface.ifa_name,
                  String(cString: name) == interfaceName,
                  let address = interface.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else {
                continue
            }

            var sinAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sinAddress, &buffer, socklen_t(buffer.count)) != nil else {
                continue
            }
            return String(cString: buffer)
        }

        return nil
    }
}
