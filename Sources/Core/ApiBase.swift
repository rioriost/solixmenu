//
//  ApiBase.swift
//  solixmenu
//
//  Swift port of anker-solix-api/api/apibase.py (cache management + update helpers)
//

import Foundation

// MARK: - Callback Types

typealias MqttUpdateCallback = (_ deviceSn: String) -> Void
typealias DeviceCacheCallback = (_ device: [String: Any]) -> Void

// MARK: - MQTT Status Protocol (optional)

protocol MqttSessionStatusProviding: AnyObject {
    func isConnected() -> Bool
    func cleanup()
}

// MARK: - ApiBase

class ApiBase {
    // Core session
    let apisession: ApiSession

    // MQTT session (set by MQTT module when available)
    var mqttsession: AnyObject?

    // Cache
    private let cacheQueue = DispatchQueue(label: "solixmenu.apibase.cache")
    private var siteDevices: Set<String> = []
    private var deviceCallbacks: [String: [DeviceCacheCallback]] = [:]

    var account: [String: Any] {
        get { cacheQueue.sync { _account } }
        set { cacheQueue.sync { _account = newValue } }
    }
    var sites: [String: [String: Any]] {
        get { cacheQueue.sync { _sites } }
        set { cacheQueue.sync { _sites = newValue } }
    }
    var devices: [String: [String: Any]] {
        get { cacheQueue.sync { _devices } }
        set { cacheQueue.sync { _devices = newValue } }
    }

    private var _account: [String: Any] = [:]
    private var _sites: [String: [String: Any]] = [:]
    private var _devices: [String: [String: Any]] = [:]

    // Callbacks
    private var mqttUpdateCallback: MqttUpdateCallback?

    init(
        email: String? = nil,
        password: String? = nil,
        countryId: String? = nil,
        apisession: ApiSession? = nil
    ) throws {
        if let apisession {
            self.apisession = apisession
        } else {
            guard
                let email,
                let password,
                let countryId
            else {
                throw ApiSessionError.missingLoginData
            }
            self.apisession = try ApiSession(
                email: email,
                password: password,
                countryId: countryId
            )
        }
    }

    // MARK: - Logger

    func logger(_ message: String) {
        // ApiSession owns logging config. If you need more, inject your own logger here.
        // This is intentionally minimal to keep ApiBase generic.
        AppLogger.log(message)
    }

    // MARK: - MQTT Callback Setter

    @discardableResult
    func mqtt_update_callback(_ callback: MqttUpdateCallback? = nil) -> MqttUpdateCallback? {
        cacheQueue.sync {
            if let callback = callback {
                mqttUpdateCallback = callback
            }
            return mqttUpdateCallback
        }
    }

    // MARK: - Cache Helpers

    func resetSiteDevices() {
        cacheQueue.sync {
            siteDevices.removeAll()
        }
    }

    func addSiteDevice(_ deviceSn: String) {
        guard !deviceSn.isEmpty else { return }
        cacheQueue.sync {
            siteDevices.insert(deviceSn)
        }
    }

    func addSiteDevices(_ deviceSns: [String]) {
        cacheQueue.sync {
            for sn in deviceSns where !sn.isEmpty {
                siteDevices.insert(sn)
            }
        }
    }

    func currentSiteDevices() -> Set<String> {
        cacheQueue.sync { siteDevices }
    }

    func getCaches() -> [String: Any] {
        cacheQueue.sync {
            var merged: [String: Any] = [:]

            for (key, value) in _sites {
                merged[key] = value
            }
            for (key, value) in _devices {
                merged[key] = value
            }

            merged[apisession.email] = _account

            if let vehicles = _account["vehicles"] as? [String: Any] {
                for (key, value) in vehicles {
                    merged[key] = value
                }
            }

            return merged
        }
    }

    func clearCaches() {
        let callbacksToNotify = cacheQueue.sync { () -> [DeviceCacheCallback] in
            let callbacks = deviceCallbacks.values.flatMap { $0 }
            deviceCallbacks = [:]
            _sites = [:]
            _devices = [:]
            _account = [:]
            siteDevices.removeAll()
            return callbacks
        }

        for callback in callbacksToNotify {
            callback([:])
        }

        stopMqttSession()
    }

    func customizeCacheId(id: String, key: String, value: Any) {
        guard !id.isEmpty, !key.isEmpty else { return }

        enum FollowUp {
            case none
            case site(Any)
            case device(Any)
            case account(Any)
        }

        let followUp: FollowUp = cacheQueue.sync {
            if var site = _sites[id] {
                var customized = site["customized"] as? [String: Any] ?? [:]
                customized[key] = mergeCustomizedValue(current: customized[key], newValue: value)
                site["customized"] = customized
                _sites[id] = site

                if let siteDetails = site["site_details"] as? [String: Any],
                    let existingValue = siteDetails[key]
                {
                    return .site(existingValue)
                }
                return .none
            } else if var device = _devices[id] {
                var customized = device["customized"] as? [String: Any] ?? [:]
                customized[key] = value
                device["customized"] = customized
                _devices[id] = device

                if let existingValue = device[key] {
                    return .device(existingValue)
                }
                return .none
            } else if id == apisession.email {
                var customized = _account["customized"] as? [String: Any] ?? [:]
                customized[key] = value
                _account["customized"] = customized

                if let existingValue = _account[key] {
                    return .account(existingValue)
                }
                return .none
            }

            return .none
        }

        switch followUp {
        case .none:
            break
        case .site(let existingValue):
            _update_site(siteId: id, details: [key: existingValue])
        case .device(let existingValue):
            _update_dev(devData: ["device_sn": id, key: existingValue])
        case .account(let existingValue):
            _update_account(details: [key: existingValue])
        }
    }

    private func mergeCustomizedValue(current: Any?, newValue: Any) -> Any {
        if let currentDict = current as? [String: Any],
            let newDict = newValue as? [String: Any]
        {
            return currentDict.merging(newDict) { _, new in new }
        }
        return newValue
    }

    func recycleDevices(extraDevices: Set<String>? = nil, activeDevices: Set<String>? = nil) {
        let extra = extraDevices ?? []
        let active = activeDevices ?? []

        let callbacksToNotify = cacheQueue.sync { () -> [DeviceCacheCallback] in
            if !active.isEmpty {
                let removed = siteDevices.subtracting(active.union(extra))
                for dev in removed {
                    siteDevices.remove(dev)
                }
            }

            let toRemove = _devices.keys.filter { !siteDevices.contains($0) && !extra.contains($0) }
            var callbacks: [DeviceCacheCallback] = []
            for sn in toRemove {
                _devices.removeValue(forKey: sn)
                if let removedCallbacks = deviceCallbacks.removeValue(forKey: sn) {
                    callbacks.append(contentsOf: removedCallbacks)
                }
            }
            return callbacks
        }

        for callback in callbacksToNotify {
            callback([:])
        }
    }

    func recycleSites(activeSites: Set<String>? = nil) {
        guard let activeSites, !activeSites.isEmpty else { return }
        cacheQueue.sync {
            let toRemove = _sites.keys.filter { !activeSites.contains($0) }
            for siteId in toRemove {
                _sites.removeValue(forKey: siteId)
            }
        }
    }

    // MARK: - Device Callback Registration

    func register_device_callback(deviceSn: String, func callback: @escaping DeviceCacheCallback) {
        cacheQueue.sync {
            var list = deviceCallbacks[deviceSn] ?? []
            list.append(callback)
            deviceCallbacks[deviceSn] = list
        }
    }

    func notify_device(deviceSn: String) {
        let payload = cacheQueue.sync { () -> ([DeviceCacheCallback], [String: Any]) in
            let callbacks = deviceCallbacks[deviceSn] ?? []
            let device = _devices[deviceSn] ?? [:]
            return (callbacks, device)
        }
        for callback in payload.0 {
            callback(payload.1)
        }
    }

    // MARK: - MQTT Session (placeholder interface)

    @discardableResult
    func startMqttSession() async -> AnyObject? {
        if let existing = mqttsession as? MqttSession {
            let connected = existing.isConnected()
            logger(
                "ApiBase: startMqttSession reuse existing session connected=\(connected)"
            )
            if connected {
                _update_account(details: [:])
                return existing
            }

            logger("ApiBase: startMqttSession reconnecting existing session")
            let reconnected = await existing.connect()
            logger(
                "ApiBase: startMqttSession reconnect finished connected=\(reconnected)"
            )
            _update_account(details: ["mqtt_connection": reconnected])
            return existing
        }

        logger("ApiBase: startMqttSession creating new session")
        let session = MqttSession(
            apisession: apisession,
            logger: { [weak self] message in
                self?.logger(message)
            }
        )
        mqttsession = session

        session.message_callback { [weak self] _, _, _, _, _, deviceSn, valueUpdate in
            guard let self, let deviceSn else { return }
            if valueUpdate {
                _ = self.update_device_mqtt(deviceSn: deviceSn)
                self.mqttUpdateCallback?(deviceSn)
            }
        }

        let connected = await session.connect()
        logger("ApiBase: startMqttSession new session connect finished connected=\(connected)")
        _update_account(details: ["mqtt_connection": connected])
        return session
    }

    func stopMqttSession() {
        if let mqtt = mqttsession as? MqttSessionStatusProviding {
            mqtt.cleanup()
        }
        mqttsession = nil
        cacheQueue.sync {
            mqttUpdateCallback = nil

            // Clear mqtt_data from devices to prevent stale data
            for (sn, var device) in _devices {
                device.removeValue(forKey: "mqtt_data")
                _devices[sn] = device
            }
        }

        _update_account(details: ["mqtt_statistic": NSNull()])
    }

    // MARK: - Cache Update Helpers

    func _update_account(details: [String: Any] = [:]) {
        let mqttConnected = (mqttsession as? MqttSessionStatusProviding)?.isConnected() ?? false

        cacheQueue.sync {
            var accountDetails = _account

            if accountDetails.isEmpty
                || (accountDetails["nickname"] as? String) != apisession.nickname
            {
                accountDetails["type"] = SolixDeviceType.account.rawValue
                accountDetails["email"] = apisession.email
                accountDetails["nickname"] = apisession.nickname
                accountDetails["country"] = apisession.countryId
                accountDetails["server"] = apisession.apiBase
            }

            accountDetails.merge(details) { _, new in new }
            accountDetails["requests_last_min"] = apisession.requestCount.lastMinuteCount()
            accountDetails["requests_last_hour"] = apisession.requestCount.lastHourCount()
            accountDetails["mqtt_connection"] = mqttConnected

            _account = accountDetails
        }
    }

    func _update_site(siteId: String, details: [String: Any]) {
        cacheQueue.sync {
            var site = _sites[siteId] ?? [:]
            var siteDetails = site["site_details"] as? [String: Any] ?? [:]

            for (key, value) in details {
                siteDetails[key] = value
            }

            site["site_details"] = siteDetails
            _sites[siteId] = site
        }
    }

    @discardableResult
    func _update_dev(
        devData: [String: Any],
        devType: String? = nil,
        siteId: String? = nil,
        isAdmin: Bool? = nil
    ) -> String? {
        guard let sn = devData["device_sn"] else { return nil }
        let deviceSn = String(describing: sn)

        return cacheQueue.sync {
            var device = _devices[deviceSn] ?? [:]
            device["device_sn"] = deviceSn

            if let devType {
                device["type"] = devType.lowercased()
            }
            if let siteId {
                device["site_id"] = siteId
            }
            if let isAdmin {
                device["is_admin"] = isAdmin
            } else if device["is_admin"] == nil, let value = devData["ms_device_type"] as? Int {
                device["is_admin"] = (value == 0 || value == 1)
            }

            for (key, value) in devData {
                if key == "product_code" || key == "device_pn" {
                    let pn = String(describing: value)
                    if !pn.isEmpty {
                        device["device_pn"] = pn
                        if let mapped = SolixDeviceCategory.map[pn] {
                            let parts = mapped.split(separator: "_")
                            if let last = parts.last, let gen = Int(last), parts.count > 1 {
                                if (device["type"] as? String)?.isEmpty != false {
                                    device["type"] = parts.dropLast().joined(separator: "_")
                                }
                                device["generation"] = gen
                            } else if (device["type"] as? String)?.isEmpty != false {
                                device["type"] = mapped
                            }
                        }
                    }
                    device[key] = value
                } else if key == "device_sw_version", let value = value as? String {
                    device["sw_version"] = value
                } else if ["wifi_online", "auto_upgrade", "is_ota_update"].contains(key) {
                    device[key] = (value as? Bool) ?? false
                } else if ["wireless_type", "ota_version"].contains(key) {
                    device[key] = String(describing: value)
                } else if key == "device_name" {
                    let name = String(describing: value)
                    if !name.isEmpty { device["name"] = name }
                    device[key] = value
                } else if key == "alias_name" {
                    let alias = String(describing: value)
                    if !alias.isEmpty { device["alias"] = alias }
                    device[key] = value
                } else if key == "wifi_name" {
                    let name = String(describing: value)
                    if !name.isEmpty { device[key] = name }
                } else {
                    device[key] = value
                }
            }

            _devices[deviceSn] = device
            return deviceSn
        }
    }

    // MARK: - MQTT Data Merge Placeholder

    func update_device_mqtt(deviceSn: String? = nil) -> Bool {
        guard let session = mqttsession as? MqttSession else { return false }

        if let sn = deviceSn {
            let data = session.mqtt_data(deviceSn: sn)
            guard !data.isEmpty else { return false }

            cacheQueue.sync {
                var device = _devices[sn] ?? ["device_sn": sn]
                var existing = device["mqtt_data"] as? [String: Any] ?? [:]
                existing.merge(data) { _, new in new }
                device["mqtt_data"] = existing
                _devices[sn] = device
            }
            notify_device(deviceSn: sn)
            return true
        }

        let allData = session.mqtt_data_all()
        var updatedDeviceSns: [String] = []

        cacheQueue.sync {
            for (sn, data) in allData {
                guard !data.isEmpty else { continue }
                var device = _devices[sn] ?? ["device_sn": sn]
                var existing = device["mqtt_data"] as? [String: Any] ?? [:]
                existing.merge(data) { _, new in new }
                device["mqtt_data"] = existing
                _devices[sn] = device
                updatedDeviceSns.append(sn)
            }
        }

        for sn in updatedDeviceSns {
            notify_device(deviceSn: sn)
        }
        return !updatedDeviceSns.isEmpty
    }

    // MARK: - Pricing / Forecast Placeholders

    func extractPriceData(siteId: String, forceCalc: Bool = false) -> [String: Any] {
        // Placeholder for dynamic price aggregation
        return [:]
    }

    func extractSolarForecast(siteId: String) {
        // Placeholder for solar forecast aggregation
    }
}
