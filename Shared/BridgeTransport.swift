import Foundation
import Network
import Security

enum BridgePairingCode {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                     "Secure random generation is required for companion pairing.")
        return "sb1-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ code: String) -> Bool {
        let normalized = normalized(code)
        return normalized.hasPrefix("sb1-") && normalized.utf8.count == 36
            && normalized.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum BridgeTransport {
    /// Network.framework's PSK handshake authenticates BOTH peers before .ready.
    /// No certificate trust bypass and no unencrypted fallback are installed.
    static func parameters(pairingCode: String) throws -> NWParameters {
        guard BridgePairingCode.isValid(pairingCode) else { throw BridgeProtocolError.invalidPairingCode }
        let code = BridgePairingCode.normalized(pairingCode)
        let hex = Array(code.dropFirst(4))
        let bytes = stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(hex[$0...($0 + 1)]), radix: 16)!
        }
        let key = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("showbar-companion-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                   tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}
