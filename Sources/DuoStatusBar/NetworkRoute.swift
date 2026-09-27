import Foundation
import Security
import SystemConfiguration

enum NetworkTransport: String {
    case ethernet
    case wifi

    var title: String {
        switch self {
        case .ethernet: return "有線"
        case .wifi: return "Wi-Fi"
        }
    }

    var interfaceType: String {
        switch self {
        case .ethernet: return kSCNetworkInterfaceTypeEthernet as String
        case .wifi: return kSCNetworkInterfaceTypeIEEE80211 as String
        }
    }

    var preferredServiceNames: [String] {
        switch self {
        case .ethernet: return ["UGREEN", "Ethernet"]
        case .wifi: return ["Wi-Fi"]
        }
    }
}

final class NetworkRouteSwitcher {
    private var authorization: AuthorizationRef?

    deinit {
        if let authorization {
            AuthorizationFree(authorization, [])
        }
    }

    func switchTo(_ transport: NetworkTransport) -> Bool {
        guard let authorization = authorized,
              let preferences = SCPreferencesCreateWithAuthorization(
                nil,
                "DuoStatusBar" as CFString,
                nil,
                authorization
              ),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else {
            return false
        }

        let candidates = services.filter { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else {
                return false
            }
            return (type as String) == transport.interfaceType
        }
        guard let target = targetService(from: candidates, for: transport) else {
            return false
        }
        guard let targetID = SCNetworkServiceGetServiceID(target) as String? else {
            return false
        }

        if !SCNetworkServiceGetEnabled(target) {
            guard SCNetworkServiceSetEnabled(target, true) else { return false }
        }

        let serviceIDs = services.compactMap { SCNetworkServiceGetServiceID($0) as String? }
        let storedOrder = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let order = storedOrder.filter { serviceIDs.contains($0) }
            + serviceIDs.filter { !storedOrder.contains($0) }
        let newOrder = [targetID] + order.filter { $0 != targetID }

        guard SCNetworkSetSetServiceOrder(set, newOrder as CFArray),
              SCPreferencesCommitChanges(preferences),
              SCPreferencesApplyChanges(preferences) else {
            return false
        }
        return true
    }

    func interfaceBSDName(for transport: NetworkTransport) -> String? {
        guard let preferences = SCPreferencesCreate(nil, "DuoStatusBar" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            return nil
        }

        let candidates = services.filter { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else {
                return false
            }
            return (type as String) == transport.interfaceType
        }

        guard let target = targetService(from: candidates, for: transport),
              let interface = SCNetworkServiceGetInterface(target) else {
            return nil
        }
        return SCNetworkInterfaceGetBSDName(interface) as String?
    }

    func serviceDiagnostics() -> String {
        guard let preferences = SCPreferencesCreate(nil, "DuoStatusBar" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            return "network preferences unavailable"
        }

        let descriptions = services.compactMap { service -> String? in
            guard let name = SCNetworkServiceGetName(service) as String?,
                  let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                return nil
            }
            let enabled = SCNetworkServiceGetEnabled(service) ? "on" : "off"
            return [name, type, enabled, serviceID].joined(separator: "|")
        }
        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let selectedEthernet = targetService(from: services.filter { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { return false }
            return (type as String) == NetworkTransport.ethernet.interfaceType
        }, for: .ethernet).flatMap { SCNetworkServiceGetName($0) as String? } ?? "none"
        return [
            "services=" + descriptions.joined(separator: ";"),
            "order=" + order.joined(separator: ","),
            "selectedEthernet=" + selectedEthernet
        ].joined(separator: "\n")
    }

    private func targetService(from candidates: [SCNetworkService], for transport: NetworkTransport) -> SCNetworkService? {
        transport.preferredServiceNames.lazy.compactMap { preferredName in
            candidates.first { service in
                (SCNetworkServiceGetName(service) as String?)?.caseInsensitiveCompare(preferredName) == .orderedSame
            }
        }.first ?? candidates.first(where: { service in
            guard transport == .ethernet,
                  let name = SCNetworkServiceGetName(service) as String? else { return false }
            let lowercased = name.lowercased()
            return !lowercased.contains("iphone") && !lowercased.contains("usb")
        }) ?? candidates.first
    }

    private func makeAuthorization() -> AuthorizationRef? {
        var created: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess,
              let created else {
            return nil
        }

        let status: OSStatus = "system.preferences.network".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    created,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights],
                    nil
                )
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(created, [])
            return nil
        }
        return created
    }

    private var authorized: AuthorizationRef? {
        if let authorization { return authorization }
        let created = makeAuthorization()
        authorization = created
        return created
    }
}
