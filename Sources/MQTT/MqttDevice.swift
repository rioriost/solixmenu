//
//  MqttDevice.swift
//  solixmenu
//
//  Base MQTT device wrapper
//

import Foundation

class SolixMqttDevice {
    let api: SolixApi
    let deviceSn: String

    var models: Set<String>
    var features: [String: Set<String>]

    private(set) var device: [String: Any] = [:]
    private(set) var mqttData: [String: Any] = [:]

    init(
        api: SolixApi,
        deviceSn: String,
        models: Set<String> = [],
        features: [String: Set<String>] = [:]
    ) {
        self.api = api
        self.deviceSn = deviceSn
        self.models = models
        self.features = features

        updateDevice(api.devices[deviceSn] ?? [:])
        api.register_device_callback(deviceSn: deviceSn) { [weak self] device in
            self?.updateDevice(device)
        }
    }

    // MARK: - Device Updates

    func updateDevice(_ device: [String: Any]) {
        guard (device["device_sn"] as? String) == deviceSn else { return }
        self.device = device
        self.mqttData = device["mqtt_data"] as? [String: Any] ?? [:]
    }

    // MARK: - Status

    func isConnected() -> Bool {
        (api.mqttsession as? MqttSessionStatusProviding)?.isConnected() ?? false
    }

    func getStatus() -> [String: Any] {
        mqttData
    }

    func supports(command: String) -> Bool {
        guard let model = (device["device_pn"] as? String) ?? (device["product_code"] as? String)
        else { return false }
        return features[command]?.contains(model) == true
    }

    // MARK: - Commands

    @discardableResult
    func sendHexCommand(
        hexString: String,
        description: String = ""
    ) async -> String? {
        guard let data = dataFromHex(hexString) else { return nil }

        if !isConnected() {
            _ = await api.startMqttSession()
        }

        guard
            let session = api.mqttsession as? MqttSession,
            session.isConnected()
        else {
            api.logger(
                "MQTT device \(deviceSn) publish skipped: mqtt session unavailable or not connected"
            )
            return nil
        }

        let published = session.publish(deviceDict: device, hexBytes: data)
        guard published else {
            api.logger("MQTT device \(deviceSn) publish failed")
            return nil
        }

        if !description.isEmpty {
            api.logger("MQTT device \(deviceSn) \(description)")
        }
        return hexString.lowercased()
    }

    @discardableResult
    func sendCommand(
        _ command: String,
        parameters: [String: Any]? = nil,
        description: String = "",
        toFile: Bool = false
    ) async -> String? {
        let model =
            (device["device_pn"] as? String)
            ?? (device["product_code"] as? String)

        guard
            let hexdata = generateMqttCommand(
                command: command,
                parameters: parameters,
                model: model
            )
        else {
            api.logger("MQTT device \(deviceSn) failed to generate hex data for command \(command)")
            return nil
        }

        let hexString = hexdata.hexString()
        if toFile {
            api.logger(
                "TESTMODE: MQTT device \(deviceSn) generated command: \(description)\n\(hexString)")
            return hexString
        }

        return await sendHexCommand(hexString: hexString, description: description)
    }

    // MARK: - Helpers

    private func dataFromHex(_ hexString: String) -> Data? {
        let cleaned = hexString.replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        return data
    }
}
