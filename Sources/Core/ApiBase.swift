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
    private var siteDevices: Set<String> = []
    private var deviceCallbacks: [String: [DeviceCacheCallback]] = [:]

    var account: [String: Any] = [:]
    var sites: [String: [String: Any]] = [:]
    var devices: [String: [String: Any]] = [:]

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
        if let callback = callback {
            mqttUpdateCallback = callback
        }
        return mqttUpdateCallback
    }

    // MARK: - Cache Helpers

    func resetSiteDevices() {
        siteDevices.removeAll()
    }

    func addSiteDevice(_ deviceSn: String) {
        guard !deviceSn.isEmpty else { return }
        siteDevices.insert(deviceSn)
    }

    func addSiteDevices(_ deviceSns: [String]) {
        for sn in deviceSns {
            addSiteDevice(sn)
        }
    }

    func currentSiteDevices() -> Set<String> {
        siteDevices
    }

    func getCaches() -> [String: Any] {
        var merged: [String: Any] = [:]

        for (key, value) in sites {
            merged[key] = value
        }
        for (key, value) in devices {
            merged[key] = value
        }

        merged[apisession.email] = account

        if let vehicles = account["vehicles"] as? [String: Any] {
            for (key, value) in vehicles {
                merged[key] = value
            }
        }

        return merged
    }

    func clearCaches() {
        for callbacks in deviceCallbacks.values {
            for callback in callbacks {
                callback([:])
            }
        }
        deviceCallbacks = [:]
        sites = [:]
        devices = [:]
        account = [:]

        stopMqttSession()
    }

    func customizeCacheId(id: String, key: String, value: Any) {
        guard !id.isEmpty, !key.isEmpty else { return }

        if var site = sites[id] {
            var customized = site["customized"] as? [String: Any] ?? [:]
            customized[key] = mergeCustomizedValue(current: customized[key], newValue: value)
            site["customized"] = customized
            sites[id] = site

            // If key exists in site details, refresh to trigger downstream updates
            if let siteDetails = site["site_details"] as? [String: Any], siteDetails[key] != nil {
                _update_site(siteId: id, details: [key: siteDetails[key] as Any])
            }
        } else if var device = devices[id] {
            var customized = device["customized"] as? [String: Any] ?? [:]
            customized[key] = value
            device["customized"] = customized
            devices[id] = device

            if device[key] != nil {
                _update_dev(devData: ["device_sn": id, key: device[key] as Any])
            }
        } else if id == apisession.email {
            var customized = account["customized"] as? [String: Any] ?? [:]
            customized[key] = value
            account["customized"] = customized

            if account[key] != nil {
                _update_account(details: [key: account[key] as Any])
            }
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

        if !active.isEmpty {
            let removed = siteDevices.subtracting(active.union(extra))
            for dev in removed {
                siteDevices.remove(dev)
            }
        }

        let toRemove = devices.keys.filter { !siteDevices.contains($0) && !extra.contains($0) }
        for sn in toRemove {
            devices.removeValue(forKey: sn)
            if let callbacks = deviceCallbacks.removeValue(forKey: sn) {
                for callback in callbacks {
                    callback([:])
                }
            }
        }
    }

    func recycleSites(activeSites: Set<String>? = nil) {
        guard let activeSites, !activeSites.isEmpty else { return }
        let toRemove = sites.keys.filter { !activeSites.contains($0) }
        for siteId in toRemove {
            sites.removeValue(forKey: siteId)
        }
    }

    // MARK: - Device Callback Registration

    func register_device_callback(deviceSn: String, func callback: @escaping DeviceCacheCallback) {
        var list = deviceCallbacks[deviceSn] ?? []
        list.append(callback)
        deviceCallbacks[deviceSn] = list
    }

    func notify_device(deviceSn: String) {
        guard let callbacks = deviceCallbacks[deviceSn] else { return }
        for callback in callbacks {
            callback(devices[deviceSn] ?? [:])
        }
    }

    // MARK: - MQTT Session (placeholder interface)

    @discardableResult
    func startMqttSession() async -> AnyObject? {
        if let existing = mqttsession as? MqttSession, existing.isConnected() {
            _update_account(details: [:])
            return existing
        }

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
        _update_account(details: ["mqtt_connection": connected])
        return mqttsession
    }

    func stopMqttSession() {
        if let mqtt = mqttsession as? MqttSessionStatusProviding {
            mqtt.cleanup()
        }
        mqttsession = nil
        mqttUpdateCallback = nil

        // Clear mqtt_data from devices to prevent stale data
        for (sn, var device) in devices {
            device.removeValue(forKey: "mqtt_data")
            devices[sn] = device
        }

        _update_account(details: ["mqtt_statistic": NSNull()])
    }

    // MARK: - Cache Update Helpers

    func _update_account(details: [String: Any] = [:]) {
        var accountDetails = account

        if accountDetails.isEmpty || (accountDetails["nickname"] as? String) != apisession.nickname
        {
            accountDetails["type"] = SolixDeviceType.account.rawValue
            accountDetails["email"] = apisession.email
            accountDetails["nickname"] = apisession.nickname
            accountDetails["country"] = apisession.countryId
            accountDetails["server"] = apisession.apiBase
        }

        let mqttConnected = (mqttsession as? MqttSessionStatusProviding)?.isConnected() ?? false

        accountDetails.merge(details) { _, new in new }
        accountDetails["requests_last_min"] = apisession.requestCount.lastMinuteCount()
        accountDetails["requests_last_hour"] = apisession.requestCount.lastHourCount()
        accountDetails["mqtt_connection"] = mqttConnected

        account = accountDetails
    }

    func _update_site(siteId: String, details: [String: Any]) {
        var site = sites[siteId] ?? [:]
        var siteDetails = site["site_details"] as? [String: Any] ?? [:]

        for (key, value) in details {
            siteDetails[key] = value
        }

        site["site_details"] = siteDetails
        sites[siteId] = site
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

        var device = devices[deviceSn] ?? [:]
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

        devices[deviceSn] = device
        return deviceSn
    }

    // MARK: - MQTT Data Merge Placeholder

    func update_device_mqtt(deviceSn: String? = nil) -> Bool {
        guard let session = mqttsession as? MqttSession else { return false }

        if let sn = deviceSn {
            let data = session.mqtt_data(deviceSn: sn)
            guard !data.isEmpty else { return false }

            var device = devices[sn] ?? ["device_sn": sn]
            var existing = device["mqtt_data"] as? [String: Any] ?? [:]
            existing.merge(data) { _, new in new }
            device["mqtt_data"] = existing
            devices[sn] = device
            notify_device(deviceSn: sn)
            return true
        }

        var updated = false
        for (sn, data) in session.mqtt_data_all() {
            guard !data.isEmpty else { continue }
            var device = devices[sn] ?? ["device_sn": sn]
            var existing = device["mqtt_data"] as? [String: Any] ?? [:]
            existing.merge(data) { _, new in new }
            device["mqtt_data"] = existing
            devices[sn] = device
            notify_device(deviceSn: sn)
            updated = true
        }
        return updated
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
