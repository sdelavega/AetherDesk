import Foundation

final class NetworkPolicy {

    enum DenialReason: Error, CustomStringConvertible {
        case rawIPBlocked(String)
        case privateIPBlocked(String)
        case metadataEndpointBlocked
        case dnsRebindingBlocked(host: String, resolvedIP: String)
        case lanAccessDisabled(String)

        var description: String {
            switch self {
            case .rawIPBlocked(let ip):
                return "Raw IP address blocked: \(ip). Use a domain name instead."
            case .privateIPBlocked(let ip):
                return "Private/reserved IP address blocked: \(ip)"
            case .metadataEndpointBlocked:
                return "Cloud instance metadata endpoint blocked (169.254.169.254)"
            case .dnsRebindingBlocked(let host, let ip):
                return "DNS rebinding blocked: \(host) resolved to private IP \(ip)"
            case .lanAccessDisabled(let ip):
                return "LAN access is disabled: \(ip)"
            }
        }
    }

    private let allowLANAccess: Bool
    private let bundleID: UUID

    private static var domainLogs: [UUID: [String]] = [:]
    private static let domainLogLock = NSLock()
    private static let maxDomainsPerBundle = 100

    init(bundleID: UUID, allowLANAccess: Bool) {
        self.bundleID = bundleID
        self.allowLANAccess = allowLANAccess
    }

    // MARK: - URL validation

    func validate(url: URL) -> Result<URL, DenialReason> {
        guard let host = url.host else {
            return .failure(.rawIPBlocked("(no host)"))
        }

        if Self.isRawIPAddress(host) {
            if Self.isCloudMetadataEndpoint(host) {
                return .failure(.metadataEndpointBlocked)
            }
            if Self.isPrivateIP(host) {
                return allowLANAccess
                    ? .success(url)
                    : .failure(.lanAccessDisabled(host))
            }
            return .failure(.rawIPBlocked(host))
        }

        logDomain(host)
        return .success(url)
    }

    func validateResolvedAddresses(for url: URL) -> Result<URL, DenialReason> {
        guard let host = url.host, !Self.isRawIPAddress(host) else { return .success(url) }

        let resolvedIPs = resolveHost(host)
        for ip in resolvedIPs {
            if Self.isCloudMetadataEndpoint(ip) {
                return .failure(.metadataEndpointBlocked)
            }
            if Self.isPrivateIP(ip) {
                return .failure(.dnsRebindingBlocked(host: host, resolvedIP: ip))
            }
        }
        return .success(url)
    }

    // MARK: - Domain logging

    static func contactedDomains(for bundleID: UUID) -> [String] {
        domainLogLock.lock()
        defer { domainLogLock.unlock() }
        return domainLogs[bundleID] ?? []
    }

    static func clearDomainLog(for bundleID: UUID) {
        domainLogLock.lock()
        defer { domainLogLock.unlock() }
        domainLogs.removeValue(forKey: bundleID)
    }

    private func logDomain(_ host: String) {
        let domain = Self.stripSubdomain(host)
        Self.domainLogLock.lock()
        if Self.domainLogs[bundleID] == nil {
            Self.domainLogs[bundleID] = []
        }
        var list = Self.domainLogs[bundleID]!
        if !list.contains(domain) {
            if list.count >= Self.maxDomainsPerBundle {
                list.removeFirst()
            }
            list.append(domain)
            Self.domainLogs[bundleID] = list
        }
        Self.domainLogLock.unlock()
    }

    private static func stripSubdomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        if parts.count > 2 {
            return parts.suffix(2).joined(separator: ".")
        }
        return host
    }

    // MARK: - IP classification

    static func isRawIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let ipv4Pattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        return host.range(of: ipv4Pattern, options: .regularExpression) != nil
    }

    static func isPrivateIP(_ host: String) -> Bool {
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        return isPrivateIPv4(host)
    }

    static func isCloudMetadataEndpoint(_ host: String) -> Bool {
        host == "169.254.169.254" || host == "[::ffff:169.254.169.254]"
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return false }
        let ip = addr.s_addr.bigEndian

        let mask10: UInt32 = 0xFF000000
        let mask172: UInt32 = 0xFFF00000
        let mask192: UInt32 = 0xFFFF0000
        let mask169: UInt32 = 0xFFFF0000
        let mask127: UInt32 = 0xFF000000
        let mask224: UInt32 = 0xF0000000

        if ip & mask10 == 0x0A000000 { return true }
        if ip & mask172 == 0xAC100000 { return true }
        if ip & mask192 == 0xC0A80000 { return true }
        if ip & mask169 == 0xA9FE0000 { return true }
        if ip & mask127 == 0x7F000000 { return true }
        if ip & mask224 == 0xE0000000 { return true }
        if ip == 0 { return true }
        if ip == 0xFFFFFFFF { return true }

        return false
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        var addr = in6_addr()
        let cleaned = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        guard inet_pton(AF_INET6, cleaned, &addr) == 1 else { return false }

        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 16) { bp in
                for i in 0..<16 { bytes[i] = bp[i] }
            }
        }

        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
        if bytes[0] == 0xFC || bytes[0] == 0xFD { return true }
        if bytes[0...7].allSatisfy({ $0 == 0 }) && bytes[8...14].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes[0] == 0xFF { return true }

        return false
    }

    // MARK: - DNS resolution

    private func resolveHost(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }

        var ips: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = result
        while let current = ptr {
            let addr = current.pointee.ai_addr
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfo = getnameinfo(addr, current.pointee.ai_addrlen,
                                       &buffer, socklen_t(buffer.count),
                                       nil, 0, NI_NUMERICHOST)
            if nameInfo == 0 {
                ips.append(String(cString: buffer))
            }
            ptr = current.pointee.ai_next
        }
        return ips
    }
}
