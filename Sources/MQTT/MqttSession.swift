//
//  MqttSession.swift
//  solixmenu
//
//  Swift port of anker-solix-api/api/mqtt.py (MQTT session handling)
//  Uses MQTTNIO + NIOSSL (BoringSSL) instead of SecureTransport.
//  Integrates with MQTTNIO futures/callbacks (no async-only APIs).
//

import Foundation
import MQTTNIO
import NIO
import NIOFoundationCompat
import NIOSSL

final class MqttSession: NSObject, MqttSessionStatusProviding, @unchecked Sendable {
    typealias MessageCallback =
        (
            _ session: MqttSession, _ topic: String, _ message: [String: Any], _ data: Any?,
            _ model: String?, _ deviceSn: String?, _ valueUpdate: Bool
        ) -> Void

    private enum TlsMode: String {
        case apiCa = "api-ca"
        case systemCa = "system-ca"
    }

    private let apisession: ApiSession
    private let logger: ((String) -> Void)?

    private var mqtt: MQTTClient?
    private var mqttInfo: [String: Any] = [:]
    private var subscriptions: Set<String> = []

    private var mqttData: [String: [String: Any]] = [:]
    private var messageCallback: MessageCallback?

    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var connectFailures: Int = 0
    private var cooldownUntil: Date?
    private let connectTimeoutSeconds: TimeInterval = 10
    private let cooldownBaseSeconds: TimeInterval = 5
    private let cooldownMaxSeconds: TimeInterval = 300
    private let debugMqtt = ProcessInfo.processInfo.environment["SOLIX_MQTT_DEBUG"] == "1"

    private var closeListenerName: String?
    private var publishListenerName: String?

    init(apisession: ApiSession, logger: ((String) -> Void)? = nil) {
        self.apisession = apisession
        self.logger = logger
        super.init()
    }

    // MARK: - MqttSessionStatusProviding

    func isConnected() -> Bool {
        mqtt?.isActive() ?? false
    }

    func cleanup() {
        log(
            "MqttSession: cleanup start connected=\(isConnected()) subscriptions=\(subscriptions.count) cachedDevices=\(mqttData.count) connectInFlight=\(connectContinuation != nil)"
        )
        clearConnectTimeout()
        if connectContinuation != nil {
            log("MqttSession: cleanup finishing active connect continuation")
            connectContinuation?.resume(returning: false)
            connectContinuation = nil
        }
        connectFailures = 0
        cooldownUntil = nil

        if let client = mqtt {
            if let publishListenerName {
                client.removePublishListener(named: publishListenerName)
            }
            if let closeListenerName {
                client.removeCloseListener(named: closeListenerName)
            }
            do {
                try client.syncShutdownGracefully()
                log("MqttSession: cleanup mqtt shutdown complete")
            } catch {
                log("MqttSession: mqtt shutdown error \(error)")
            }
        } else {
            log("MqttSession: cleanup skipped mqtt shutdown (client unavailable)")
        }

        mqtt = nil
        mqttInfo = [:]
        subscriptions.removeAll()
        messageCallback = nil
        mqttData.removeAll()
        publishListenerName = nil
        closeListenerName = nil
        log("MqttSession: cleanup done")
    }

    // MARK: - Callback

    @discardableResult
    func message_callback(_ callback: MessageCallback? = nil) -> MessageCallback? {
        messageCallback = callback
        return messageCallback
    }

    func mqtt_data(deviceSn: String) -> [String: Any] {
        mqttData[deviceSn] ?? [:]
    }

    func mqtt_data_all() -> [String: [String: Any]] {
        mqttData
    }

    // MARK: - Public API

    func connect(keepalive: UInt16 = 60) async -> Bool {
        log(
            "MqttSession: connect requested keepalive=\(keepalive) connected=\(isConnected()) connectInFlight=\(connectContinuation != nil) subscriptions=\(subscriptions.count)"
        )
        if isConnected() {
            log("MqttSession: connect skipped (already connected)")
            return true
        }
        if let cooldownUntil, cooldownUntil > Date() {
            let remaining = cooldownUntil.timeIntervalSince(Date())
            log("MqttSession: connect in cooldown for \(String(format: "%.1f", remaining))s")
            return false
        }
        if connectContinuation != nil {
            log("MqttSession: connect already in progress")
            return false
        }
        do {
            try await createClientIfNeeded(keepalive: keepalive)
        } catch {
            log("MqttSession: failed to create client: \(error)")
            registerConnectFailure(reason: "client init failed")
            return false
        }

        guard let client = mqtt else {
            log("MqttSession: connect aborted (client unavailable after creation)")
            registerConnectFailure(reason: "client unavailable")
            return false
        }

        log(
            "MqttSession: connect attempt start endpoint=\(mqttInfo["endpoint_addr"] as? String ?? "unknown") active=\(client.isActive())"
        )

        return await withCheckedContinuation { continuation in
            connectContinuation = continuation
            startConnectTimeout()

            let future = client.connect(
                cleanSession: true,
                connectConfiguration: .init(
                    keepAliveInterval: .seconds(Int64(keepalive))
                )
            )

            future.whenComplete { [weak self] result in
                guard let self, self.connectContinuation != nil else { return }
                switch result {
                case .success:
                    self.log("MqttSession: connect ok")
                    self.finishConnectAttempt(success: true, reason: nil)
                    self.subscribeQueuedTopics()
                case .failure(let error):
                    self.log("MqttSession: connect failed \(error)")
                    self.finishConnectAttempt(success: false, reason: "connect error")
                }
            }
        }
    }

    func disconnect() {
        guard let client = mqtt else { return }
        _ = client.disconnect()
    }

    func subscribe(_ topic: String) {
        guard !topic.isEmpty else { return }
        if subscriptions.contains(topic) {
            log("MqttSession: subscribe skipped duplicate \(topic)")
            return
        }
        subscriptions.insert(topic)

        if isConnected() {
            log("MqttSession: subscribe immediate \(topic) total=\(subscriptions.count)")
            subscribeNow(topic)
        } else {
            log(
                "MqttSession: queued subscribe \(topic) (not connected) total=\(subscriptions.count)"
            )
        }
    }

    func unsubscribe(_ topic: String) {
        guard !topic.isEmpty else { return }
        if subscriptions.contains(topic) {
            subscriptions.remove(topic)
            if isConnected() {
                unsubscribeNow(topic)
            }
        }
    }

    func getTopicPrefix(deviceDict: [String: Any], publish: Bool = false) -> String {
        guard
            let sn = (deviceDict["device_sn"] as? String)
                ?? (deviceDict["device_sn"] as? CustomStringConvertible)?.description,
            let pn = (deviceDict["device_pn"] as? String) ?? (deviceDict["product_code"] as? String)
        else { return "" }

        let appName = mqttInfo["app_name"] as? String ?? ""
        return "\(publish ? "cmd" : "dt")/\(appName)/\(pn)/\(sn)/"
    }

    func publish(
        deviceDict: [String: Any], hexBytes: Data, cmd: Int = 17, sessId: String = "1234-5678"
    ) {
        let deviceSn =
            (deviceDict["device_sn"] as? String)
            ?? (deviceDict["device_sn"] as? CustomStringConvertible)?.description ?? "unknown"
        guard let mqtt else {
            log("MqttSession: publish skipped (client unavailable) sn=\(deviceSn) cmd=\(cmd)")
            return
        }
        guard isConnected() else {
            log("MqttSession: publish skipped (not connected) sn=\(deviceSn) cmd=\(cmd)")
            return
        }

        let appName = mqttInfo["app_name"] as? String ?? ""
        let userId = mqttInfo["user_id"] as? String ?? ""
        let certId = mqttInfo["certificate_id"] as? String ?? ""

        let devicePn =
            (deviceDict["device_pn"] as? String)
            ?? (deviceDict["product_code"] as? String) ?? ""

        let head: [String: Any] = [
            "version": "1.0.0.1",
            "client_id": "android-\(appName)-\(userId)-\(certId)",
            "sess_id": sessId,
            "msg_seq": 1,
            "seed": 1,
            "timestamp": Int(Date().timeIntervalSince1970),
            "cmd_status": 2,
            "cmd": cmd,
            "sign_code": 1,
            "device_pn": devicePn,
            "device_sn": deviceSn,
        ]

        let payload: [String: Any] = [
            "account_id": (deviceDict["owner_user_id"] as? String) ?? userId,
            "device_sn": deviceSn,
            "data": hexBytes.base64EncodedString(),
        ]

        let payloadString =
            (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let message: [String: Any] = [
            "head": head,
            "payload": payloadString,
        ]

        guard
            let messageData = try? JSONSerialization.data(withJSONObject: message),
            let messageString = String(data: messageData, encoding: .utf8)
        else { return }

        let topic = "\(getTopicPrefix(deviceDict: deviceDict, publish: true))req"
        let buffer = ByteBufferAllocator().buffer(string: messageString)
        mqtt.publish(to: topic, payload: buffer, qos: .atLeastOnce)
            .whenFailure { [weak self] error in
                self?.log("MqttSession: publish error \(error)")
            }
        log("MqttSession: publish topic \(topic)")
    }

    // MARK: - Private

    private func clearConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func startConnectTimeout() {
        clearConnectTimeout()
        log("MqttSession: connect timeout armed \(connectTimeoutSeconds)s")
        connectTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(connectTimeoutSeconds * 1_000_000_000))
            if Task.isCancelled {
                self.log("MqttSession: connect timeout task cancelled")
                return
            }
            if self.connectContinuation != nil {
                self.log("MqttSession: connect timeout fired")
                self.finishConnectAttempt(success: false, reason: "timeout")
            }
        }
    }

    private func registerConnectFailure(reason: String) {
        connectFailures += 1
        let exponent = min(max(connectFailures - 1, 0), 6)
        let base = min(cooldownMaxSeconds, cooldownBaseSeconds * pow(2.0, Double(exponent)))
        let jitter = Double.random(in: 0...(base * 0.2))
        let wait = base + jitter
        cooldownUntil = Date().addingTimeInterval(wait)
        log("MqttSession: connect failed (\(reason)), cooldown \(String(format: "%.1f", wait))s")
    }

    private func finishConnectAttempt(success: Bool, reason: String? = nil) {
        clearConnectTimeout()
        if success {
            connectFailures = 0
            cooldownUntil = nil
        } else {
            registerConnectFailure(reason: reason ?? "unknown")
        }
        log(
            "MqttSession: connect attempt finished success=\(success) reason=\(reason ?? "none") failures=\(connectFailures) cooldownActive=\(cooldownUntil != nil)"
        )
        if let continuation = connectContinuation {
            continuation.resume(returning: success)
            connectContinuation = nil
        }
    }

    private func createClientIfNeeded(keepalive: UInt16) async throws {
        if mqtt != nil {
            log("MqttSession: create client skipped (existing client present)")
            return
        }

        log("MqttSession: loading mqtt info for new client keepalive=\(keepalive)")
        mqttInfo = try await apisession.getMqttInfo()
        guard let host = mqttInfo["endpoint_addr"] as? String, !host.isEmpty else {
            log("MqttSession: mqtt info missing endpoint_addr")
            throw ApiSessionError.invalidResponse
        }
        log(
            "MqttSession: mqtt_info endpoint=\(host) thing_name=\(String(describing: mqttInfo["thing_name"] ?? "")) ca_present=\(mqttInfo["aws_root_ca1_pem"] != nil) cert_present=\(mqttInfo["certificate_pem"] != nil) key_present=\(mqttInfo["private_key"] != nil)"
        )

        let thingName = mqttInfo["thing_name"] as? String ?? "solix"
        let clientId = "\(thingName)_\(UUID().uuidString.prefix(8))"

        let tlsConfig = try buildTLSConfiguration(mqttInfo: mqttInfo)
        let configuration = MQTTClient.Configuration(
            version: .v3_1_1,
            disablePing: false,
            keepAliveInterval: .seconds(Int64(keepalive)),
            pingInterval: nil,
            connectTimeout: .seconds(Int64(connectTimeoutSeconds)),
            timeout: nil,
            userName: nil,
            password: nil,
            useSSL: true,
            useWebSockets: false,
            tlsConfiguration: .niossl(tlsConfig),
            sniServerName: host,
            webSocketURLPath: nil,
            webSocketMaxFrameSize: 1 << 14
        )

        let client = MQTTClient(
            host: host,
            port: 8883,
            identifier: clientId,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            logger: nil,
            configuration: configuration
        )

        attachListeners(client: client)
        mqtt = client
        log("MqttSession: client created host=\(host) port=8883 keepalive=\(keepalive)")
    }

    private func attachListeners(client: MQTTClient) {
        let publishName = "solix.mqtt.publish.\(UUID().uuidString)"
        let closeName = "solix.mqtt.close.\(UUID().uuidString)"
        publishListenerName = publishName
        closeListenerName = closeName

        client.addPublishListener(named: publishName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let publish):
                self.handleIncomingPublish(publish)
            case .failure(let error):
                self.log("MqttSession: publish listener error \(error)")
            }
        }

        client.addCloseListener(named: closeName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.log(
                    "MqttSession: connection closed connected=\(self.isConnected()) connectInFlight=\(self.connectContinuation != nil) subscriptions=\(self.subscriptions.count)"
                )
            case .failure(let error):
                self.log(
                    "MqttSession: connection closed with error \(error) connected=\(self.isConnected()) connectInFlight=\(self.connectContinuation != nil) subscriptions=\(self.subscriptions.count)"
                )
            }
            if self.connectContinuation != nil {
                self.finishConnectAttempt(success: false, reason: "disconnect")
            } else {
                self.registerConnectFailure(reason: "disconnect")
            }
        }
    }

    private func subscribeQueuedTopics() {
        log("MqttSession: subscribe queued topics count=\(subscriptions.count)")
        for topic in subscriptions {
            subscribeNow(topic)
        }
    }

    private func subscribeNow(_ topic: String) {
        guard let mqtt else {
            log("MqttSession: subscribe skipped \(topic) (client unavailable)")
            return
        }
        mqtt.subscribe(to: [.init(topicFilter: topic, qos: .atLeastOnce)])
            .whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.log(
                        "MqttSession: subscribe \(topic) total=\(self?.subscriptions.count ?? 0)")
                case .failure(let error):
                    self?.log("MqttSession: subscribe error \(error) topic=\(topic)")
                }
            }
    }

    private func unsubscribeNow(_ topic: String) {
        guard let mqtt else { return }
        mqtt.unsubscribe(from: [topic])
            .whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.log("MqttSession: unsubscribe \(topic)")
                case .failure(let error):
                    self?.log("MqttSession: unsubscribe error \(error)")
                }
            }
    }

    private func handleIncomingPublish(_ publish: MQTTPublishInfo) {
        var buffer = publish.payload
        let rawData = buffer.readData(length: buffer.readableBytes) ?? Data()
        guard
            let text = String(data: rawData, encoding: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: rawData),
            let dict = obj as? [String: Any]
        else {
            log("MqttSession: failed to decode publish payload")
            return
        }

        if debugMqtt {
            log("MqttSession: publish topic=\(publish.topicName) bytes=\(text.count)")
        }

        let payloadString = dict["payload"] as? String ?? "{}"
        let payloadData = payloadString.data(using: .utf8) ?? Data()
        let payloadObj =
            (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]

        let model =
            (payloadObj["pn"] as? String)
            ?? publish.topicName.split(separator: "/").dropFirst(2).first.map(String.init)
        let deviceSn =
            (payloadObj["sn"] as? String)
            ?? publish.topicName.split(separator: "/").dropFirst(3).first.map(String.init)

        var dataValue: Any? = nil
        var valueUpdate = false

        if let dataBase64 = payloadObj["data"] as? String {
            if let dataBytes = Data(base64Encoded: dataBase64) {
                let hexData = DeviceHexData(hexbytes: dataBytes, model: model ?? "")
                let values = hexData.decodedValuesExpanded()
                dataValue = values

                if let sn = deviceSn {
                    var existing = mqttData[sn] ?? [:]
                    existing.merge(values) { _, new in new }
                    existing["last_message"] = Date().description
                    mqttData[sn] = existing
                    valueUpdate = true
                }
            } else if let jsonData = dataBase64.data(using: .utf8),
                let jsonObj = try? JSONSerialization.jsonObject(with: jsonData),
                let dict = jsonObj as? [String: Any]
            {
                dataValue = dict
                if let sn = deviceSn {
                    var existing = mqttData[sn] ?? [:]
                    existing.merge(dict) { _, new in new }
                    existing["last_message"] = Date().description
                    mqttData[sn] = existing
                    valueUpdate = true
                }
            } else {
                dataValue = dataBase64
            }
        } else if let dataDict = payloadObj["data"] as? [String: Any] {
            dataValue = dataDict
            if let sn = deviceSn {
                var existing = mqttData[sn] ?? [:]
                existing.merge(dataDict) { _, new in new }
                existing["last_message"] = Date().description
                mqttData[sn] = existing
                valueUpdate = true
            }
        } else if let trans = payloadObj["trans"] as? String {
            dataValue = trans
        } else {
            dataValue = payloadObj
        }

        if let callback = messageCallback {
            callback(self, publish.topicName, dict, dataValue, model, deviceSn, valueUpdate)
        } else {
            log("MqttSession: received publish \(publish.topicName) payloadBytes=\(text.count)")
        }
        if debugMqtt {
            let sn = deviceSn ?? "unknown"
            let keys = (mqttData[sn]?.keys.sorted() ?? [])
            let payloadKeys = payloadObj.keys.sorted()
            log(
                "MqttSession: debug sn=\(sn) model=\(model ?? "unknown") valueUpdate=\(valueUpdate) payloadKeys=\(payloadKeys) keys=\(keys)"
            )
        }
    }

    private func buildTLSConfiguration(mqttInfo: [String: Any]) throws -> TLSConfiguration {
        let caPem = mqttInfo["aws_root_ca1_pem"] as? String ?? ""
        let certPem = mqttInfo["certificate_pem"] as? String ?? ""
        let keyPem = mqttInfo["private_key"] as? String ?? ""

        let mode =
            TlsMode(rawValue: ProcessInfo.processInfo.environment["SOLIX_TLS_MODE"] ?? "api-ca")
            ?? .apiCa

        if mode == .apiCa && caPem.isEmpty {
            log("MqttSession: tls mode api-ca requires aws_root_ca1_pem.")
        }

        var tlsConfig = TLSConfiguration.makeClientConfiguration()

        if mode == .apiCa, !caPem.isEmpty {
            let caCerts = try parseCertificates(pem: caPem)
            if caCerts.isEmpty {
                log("MqttSession: no CA certs parsed from aws_root_ca1_pem.")
            } else {
                tlsConfig.trustRoots = .certificates(caCerts)
            }
        } else {
            tlsConfig.trustRoots = .default
        }

        if !certPem.isEmpty && !keyPem.isEmpty {
            let chain = try parseCertificates(pem: certPem)
            if chain.isEmpty {
                log("MqttSession: no client certificates parsed from certificate_pem.")
            } else {
                tlsConfig.certificateChain = chain.map { .certificate($0) }
            }
            let keyBytes = [UInt8](keyPem.utf8)
            tlsConfig.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: keyBytes, format: .pem))
        } else {
            log("MqttSession: missing certificate_pem or private_key; client identity not set.")
        }

        let manualIntermediatesPem =
            ProcessInfo.processInfo.environment["SOLIX_TLS_INTERMEDIATE_PEMS"] ?? ""
        if !manualIntermediatesPem.isEmpty {
            let manualCerts = try parseCertificates(pem: manualIntermediatesPem)
            if manualCerts.isEmpty {
                log("MqttSession: manual intermediates present but no certs parsed.")
            } else {
                let existingChain = tlsConfig.certificateChain
                tlsConfig.certificateChain = existingChain + manualCerts.map { .certificate($0) }
                log("MqttSession: appended \(manualCerts.count) manual intermediate cert(s).")
            }
        }

        return tlsConfig
    }

    private func parseCertificates(pem: String) throws -> [NIOSSLCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        let normalized =
            pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return [] }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("solix_mqtt_cert_\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try trimmed.write(to: tempURL, atomically: true, encoding: .utf8)
            let certs = try NIOSSLCertificate.fromPEMFile(tempURL.path)
            if !certs.isEmpty {
                return certs
            }
        } catch {
            // Fall back to manual extraction
        }

        var certs: [NIOSSLCertificate] = []
        var remainder = trimmed
        while let beginRange = remainder.range(of: begin) {
            remainder = String(remainder[beginRange.upperBound...])
            guard let endRange = remainder.range(of: end) else { break }
            let body = String(remainder[..<endRange.lowerBound])
            let normalizedBody =
                body
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let block = "\(begin)\n\(normalizedBody)\n\(end)\n"
            let bytes = [UInt8](block.utf8)
            if let cert = try? NIOSSLCertificate(bytes: bytes, format: .pem) {
                certs.append(cert)
            }
            remainder = String(remainder[endRange.upperBound...])
        }
        if !certs.isEmpty {
            return certs
        }

        throw NSError(
            domain: "MqttSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to load PEM certificates"]
        )
    }

    private func log(_ message: String) {
        logger?(message)
    }
}
