//
//  AppLifecycleChannel.swift
//
//  Created by wanghongen on 2023/12/21.
//

import Foundation
import FlutterMacOS
import Security
import SystemConfiguration

class AppLifecycleChannel {
    static private var channel : FlutterMethodChannel?
    static private var terminationRequestID = 0
    
    //注册
    static func registerChannel(flutterViewController: FlutterViewController) {
        channel = FlutterMethodChannel(name: "com.proxy/appLifecycle", binaryMessenger: flutterViewController.engine.binaryMessenger)
    }
    
    static func requestTermination(completion: @escaping (Bool) -> Void) {
        guard let channel = channel else {
            // Fail closed while Flutter is still booting. A persisted proxy
            // lease may already make the system depend on ProxyPin's listener.
            completion(false)
            return
        }
        terminationRequestID += 1
        let requestID = terminationRequestID
        var completed = false
        let finish: (Bool) -> Void = { safeToTerminate in
            guard !completed else { return }
            completed = true
            if !safeToTerminate {
                // Dart deliberately keeps the listener/start lock alive after a
                // successful cleanup until AppKit either exits or explicitly
                // cancels this exact termination request.
                channel.invokeMethod(
                    "appTerminationCancelled",
                    arguments: ["requestId": requestID]
                )
            }
            completion(safeToTerminate)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            // Never leave AppKit stuck in terminateLater forever. Timeout also
            // fails closed so the listener stays alive for a later retry.
            finish(false)
        }
        channel.invokeMethod(
            "appDetached",
            arguments: ["requestId": requestID]
        ) { result in
            if result is FlutterError {
                finish(false)
                return
            }
            finish((result as? Bool) == true)
        }
    }
}

/// Performs the first-hop ownership change as one SystemConfiguration
/// transaction. `SCPreferencesLock` serializes us with other compliant
/// network-settings writers, while one protocol dictionary commit changes
/// HTTP and HTTPS together without rewriting Surge's bypass list.
final class SystemProxyChannel {
    private static var channel: FlutterMethodChannel?
    private static var authorization: AuthorizationRef?

    private struct ProxyEndpoint {
        let host: String
        let port: Int
    }

    private struct ProxyTransactionError: LocalizedError {
        let message: String
        let code: String
        let mayHaveChanged: Bool

        init(
            message: String,
            code: String = "SYSTEM_PROXY_TRANSACTION_FAILED",
            mayHaveChanged: Bool = false
        ) {
            self.message = message
            self.code = code
            self.mayHaveChanged = mayHaveChanged
        }

        var errorDescription: String? { message }
    }

    private static let httpEnableKey = kSCPropNetProxiesHTTPEnable as String
    private static let httpHostKey = kSCPropNetProxiesHTTPProxy as String
    private static let httpPortKey = kSCPropNetProxiesHTTPPort as String
    private static let httpsEnableKey = kSCPropNetProxiesHTTPSEnable as String
    private static let httpsHostKey = kSCPropNetProxiesHTTPSProxy as String
    private static let httpsPortKey = kSCPropNetProxiesHTTPSPort as String

    static func registerChannel(flutterViewController: FlutterViewController) {
        let methodChannel = FlutterMethodChannel(
            name: "com.proxy/systemProxy",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        methodChannel.setMethodCallHandler { call, result in
            guard let arguments = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing system proxy arguments", details: nil))
                return
            }

            do {
                switch call.method {
                case "takeOwnership":
                    try takeOwnership(arguments)
                case "restoreOwnedEndpoints":
                    try restoreOwnedEndpoints(arguments)
                default:
                    result(FlutterMethodNotImplemented)
                    return
                }
                result(nil)
            } catch {
                let transactionError = error as? ProxyTransactionError
                result(FlutterError(
                    code: transactionError?.code ?? "SYSTEM_PROXY_TRANSACTION_FAILED",
                    message: error.localizedDescription,
                    details: ["mayHaveChanged": transactionError?.mayHaveChanged ?? true]
                ))
            }
        }
        channel = methodChannel
    }

    private static func takeOwnership(_ arguments: [String: Any]) throws {
        let serviceName = try requiredString(arguments, key: "networkService")
        let ownerHost = try requiredString(arguments, key: "ownerHost")
        let ownerPort = try requiredPort(arguments, key: "ownerPort")
        guard let expected = arguments["expected"] as? [String: Any] else {
            throw ProxyTransactionError(message: "Missing expected system proxy snapshot")
        }

        try withLockedProxyConfiguration(serviceName: serviceName) { preferences, proxyProtocol, configuration in
            guard try mutableEndpointsMatch(configuration, expected: expected) else {
                throw ProxyTransactionError(
                    message: "macOS HTTP/HTTPS proxy changed before the atomic takeover",
                    code: "SYSTEM_PROXY_ENDPOINTS_CHANGED"
                )
            }

            var updated = configuration
            setEndpoint(
                &updated,
                endpoint: ProxyEndpoint(host: ownerHost, port: ownerPort),
                enableKey: httpEnableKey,
                hostKey: httpHostKey,
                portKey: httpPortKey
            )
            setEndpoint(
                &updated,
                endpoint: ProxyEndpoint(host: ownerHost, port: ownerPort),
                enableKey: httpsEnableKey,
                hostKey: httpsHostKey,
                portKey: httpsPortKey
            )
            try commit(updated, preferences: preferences, protocol: proxyProtocol)
        }
    }

    private static func restoreOwnedEndpoints(_ arguments: [String: Any]) throws {
        let serviceName = try requiredString(arguments, key: "networkService")
        let owner = ProxyEndpoint(
            host: try requiredString(arguments, key: "ownerHost"),
            port: try requiredPort(arguments, key: "ownerPort")
        )
        guard let backup = arguments["backup"] as? [String: Any] else {
            throw ProxyTransactionError(message: "Missing system proxy recovery snapshot")
        }
        let backupHTTP = try endpoint(from: backup["http"])
        let backupHTTPS = try endpoint(from: backup["https"])

        try withLockedProxyConfiguration(serviceName: serviceName) { preferences, proxyProtocol, configuration in
            var updated = configuration
            var changed = false
            if endpointMatches(
                configuration,
                expected: owner,
                enableKey: httpEnableKey,
                hostKey: httpHostKey,
                portKey: httpPortKey
            ) {
                setEndpoint(
                    &updated,
                    endpoint: backupHTTP,
                    enableKey: httpEnableKey,
                    hostKey: httpHostKey,
                    portKey: httpPortKey
                )
                changed = true
            }
            if endpointMatches(
                configuration,
                expected: owner,
                enableKey: httpsEnableKey,
                hostKey: httpsHostKey,
                portKey: httpsPortKey
            ) {
                setEndpoint(
                    &updated,
                    endpoint: backupHTTPS,
                    enableKey: httpsEnableKey,
                    hostKey: httpsHostKey,
                    portKey: httpsPortKey
                )
                changed = true
            }

            // First-hop never changes ExceptionsList. Leaving it untouched is
            // essential: a newer Surge configuration must remain authoritative.
            if changed {
                try commit(updated, preferences: preferences, protocol: proxyProtocol)
            }
        }
    }

    private static func withLockedProxyConfiguration(
        serviceName: String,
        action: (SCPreferences, SCNetworkProtocol, [String: Any]) throws -> Void
    ) throws {
        if authorization == nil {
            var newAuthorization: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &newAuthorization)
            guard status == errAuthorizationSuccess, let newAuthorization else {
                throw ProxyTransactionError(
                    message: "Unable to create a macOS network-settings authorization session (\(status))",
                    code: "SYSTEM_PROXY_AUTHORIZATION_FAILED"
                )
            }
            authorization = newAuthorization
        }
        guard let preferences = SCPreferencesCreateWithAuthorization(
            nil,
            "ProxyPin" as CFString,
            nil,
            authorization
        ) else {
            throw ProxyTransactionError(
                message: "Unable to open authorized macOS network preferences",
                code: "SYSTEM_PROXY_AUTHORIZATION_FAILED"
            )
        }
        guard SCPreferencesLock(preferences, false) else {
            let status = SCError()
            let description = String(cString: SCErrorString(status))
            let code: String
            switch status {
            case Int32(kSCStatusAccessError):
                code = "SYSTEM_PROXY_AUTHORIZATION_DENIED"
            case Int32(kSCStatusPrefsBusy):
                code = "SYSTEM_PROXY_BUSY"
            default:
                code = "SYSTEM_PROXY_LOCK_FAILED"
            }
            throw ProxyTransactionError(
                message: "Unable to lock macOS network preferences: \(description) (\(status))",
                code: code
            )
        }
        defer { SCPreferencesUnlock(preferences) }

        SCPreferencesSynchronize(preferences)
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw ProxyTransactionError(message: "Unable to list macOS network services")
        }
        let matches = services.filter { service in
            guard let name = SCNetworkServiceGetName(service) else { return false }
            return (name as String) == serviceName
        }
        guard matches.count == 1, let service = matches.first else {
            throw ProxyTransactionError(message: "The macOS network service is missing or ambiguous: \(serviceName)")
        }
        guard let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw ProxyTransactionError(message: "The macOS network service has no proxy protocol: \(serviceName)")
        }
        let configuration = (SCNetworkProtocolGetConfiguration(proxyProtocol) as NSDictionary? as? [String: Any]) ?? [:]
        try action(preferences, proxyProtocol, configuration)
    }

    private static func commit(
        _ configuration: [String: Any],
        preferences: SCPreferences,
        protocol proxyProtocol: SCNetworkProtocol
    ) throws {
        guard SCNetworkProtocolSetConfiguration(proxyProtocol, configuration as CFDictionary) else {
            throw ProxyTransactionError(message: "Unable to stage the macOS proxy transaction")
        }
        guard SCPreferencesCommitChanges(preferences) else {
            throw ProxyTransactionError(
                message: "macOS denied the atomic proxy transaction",
                mayHaveChanged: true
            )
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw ProxyTransactionError(
                message: "macOS saved but could not apply the proxy transaction",
                mayHaveChanged: true
            )
        }
    }

    /// Compare only the HTTP/HTTPS fields this transaction mutates.
    ///
    /// Surge may refresh PAC metadata or its bypass list while the macOS
    /// authorization sheet is open. Those fields are deliberately preserved
    /// from the locked configuration below, so treating their refresh as a
    /// compare-and-swap failure creates a false conflict. Endpoint changes
    /// remain fail-closed because overwriting a newer proxy owner would break
    /// the first-hop chain.
    private static func mutableEndpointsMatch(_ configuration: [String: Any], expected: [String: Any]) throws -> Bool {
        let expectedHTTP = try endpoint(from: expected["http"])
        let expectedHTTPS = try endpoint(from: expected["https"])
        return endpointMatches(
            configuration,
            expected: expectedHTTP,
            enableKey: httpEnableKey,
            hostKey: httpHostKey,
            portKey: httpPortKey
        ) && endpointMatches(
            configuration,
            expected: expectedHTTPS,
            enableKey: httpsEnableKey,
            hostKey: httpsHostKey,
            portKey: httpsPortKey
        )
    }

    private static func endpointMatches(
        _ configuration: [String: Any],
        expected: ProxyEndpoint?,
        enableKey: String,
        hostKey: String,
        portKey: String
    ) -> Bool {
        let enabled = integer(configuration[enableKey]) != 0
        guard let expected else { return !enabled }
        guard enabled,
              let host = configuration[hostKey] as? String,
              let port = integer(configuration[portKey]) else {
            return false
        }
        return normalizedHost(host) == normalizedHost(expected.host) && port == expected.port
    }

    private static func setEndpoint(
        _ configuration: inout [String: Any],
        endpoint: ProxyEndpoint?,
        enableKey: String,
        hostKey: String,
        portKey: String
    ) {
        guard let endpoint else {
            configuration[enableKey] = 0
            return
        }
        configuration[enableKey] = 1
        configuration[hostKey] = endpoint.host
        configuration[portKey] = endpoint.port
    }

    private static func endpoint(from value: Any?) throws -> ProxyEndpoint? {
        guard let value else { return nil }
        guard let map = value as? [String: Any],
              let host = map["host"] as? String,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = integer(map["port"]),
              (1...65535).contains(port) else {
            throw ProxyTransactionError(message: "Invalid endpoint in the system proxy snapshot")
        }
        return ProxyEndpoint(host: host, port: port)
    }

    private static func requiredString(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProxyTransactionError(message: "Missing \(key)")
        }
        return value
    }

    private static func requiredPort(_ arguments: [String: Any], key: String) throws -> Int {
        guard let value = integer(arguments[key]), (1...65535).contains(value) else {
            throw ProxyTransactionError(message: "Invalid \(key)")
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func normalizedHost(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "localhost", "::1", "[::1]", "0.0.0.0":
            return "127.0.0.1"
        default:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
