import Foundation

final class SolixAppCoordinator: @unchecked Sendable {
    struct Configuration {
        let logPrefix: String
        let pollIntervalSeconds: TimeInterval
        let mqttReconnectDelaySeconds: TimeInterval

        init(
            logPrefix: String = "[SolixAppCoordinator]",
            pollIntervalSeconds: TimeInterval = 60,
            mqttReconnectDelaySeconds: TimeInterval = 10
        ) {
            self.logPrefix = logPrefix
            self.pollIntervalSeconds = pollIntervalSeconds
            self.mqttReconnectDelaySeconds = mqttReconnectDelaySeconds
        }
    }

    enum State: String {
        case idle
        case authenticating
        case polling
        case mqttConnecting
        case running
        case stopped
    }

    private let configuration: Configuration
    private let loginController: LoginController
    let appState: SolixAppState
    private(set) var state: State = .idle {
        didSet { log("state -> \(state.rawValue)") }
    }

    private var isStarted = false
    private var lastError: Error?
    private var api: SolixApi?
    private var mqttSession: MqttSession?
    private var pollTask: Task<Void, Never>?
    private var mqttTask: Task<Void, Never>?
    private var mqttRefreshTask: Task<Void, Never>?

    @MainActor
    init(
        configuration: Configuration = Configuration(),
        appState: SolixAppState? = nil,
        loginController: LoginController = LoginController()
    ) {
        self.configuration = configuration
        self.appState = appState ?? SolixAppState()
        self.loginController = loginController
    }

    func start() async {
        guard !isStarted else {
            log("start ignored; already started")
            return
        }
        isStarted = true
        state = .authenticating

        do {
            let session = try await loginController.authenticate(fromSettings: false)
            try await start(with: session)
        } catch {
            setError(error)
            isStarted = false
            state = .stopped
        }
    }

    func applySettings(_ credentials: SolixCredentials) async -> Result<Void, Error> {
        let result = await loginController.authenticateFromSettings(credentials)
        switch result {
        case .success(let session):
            guard loginController.saveCredentials(credentials) else {
                let error = ApiSessionError.authenticationFailed
                setError(error)
                return .failure(error)
            }
            stop()
            isStarted = true
            state = .authenticating
            do {
                try await start(with: session)
                return .success(())
            } catch {
                setError(error)
                isStarted = false
                state = .stopped
                return .failure(error)
            }
        case .failure(let error):
            setError(error)
            return .failure(error)
        }
    }

    private func start(with session: ApiSession) async throws {
        let api = try SolixApi(apisession: session)
        self.api = api

        let appState = appState
        await MainActor.run {
            appState.isAuthenticated = true
            appState.lastErrorMessage = nil
        }

        api.mqtt_update_callback { [weak self] deviceSn in
            self?.handleMqttUpdate(deviceSn: deviceSn)
        }

        state = .polling
        try await refreshDevices()
        startPollingLoop()

        state = .mqttConnecting
        if mqttTask != nil {
            log("cancelling existing mqtt task before reconnect")
        }
        mqttTask?.cancel()
        mqttTask = Task { [weak self] in
            self?.log("mqtt task started")
            await self?.connectMqttIfNeeded()
            self?.log("mqtt task finished cancelled=\(Task.isCancelled)")
        }

        state = .running
        log("start completed")
    }

    func stop() {
        guard isStarted else {
            log("stop ignored; already stopped")
            return
        }
        log(
            "stop requested state=\(state.rawValue) hasApi=\(api != nil) mqttConnected=\(mqttSession?.isConnected() ?? false)"
        )
        isStarted = false
        state = .stopped

        if pollTask != nil {
            log("cancelling poll task")
        }
        pollTask?.cancel()
        pollTask = nil
        if mqttTask != nil {
            log("cancelling mqtt task")
        }
        mqttTask?.cancel()
        mqttTask = nil
        if mqttRefreshTask != nil {
            log("cancelling realtime trigger task")
        }
        mqttRefreshTask?.cancel()
        mqttRefreshTask = nil

        if let api {
            log("stopping mqtt session via api")
            api.stopMqttSession()
        }
        mqttSession = nil
        api = nil

        let appState = appState
        Task { @MainActor in
            appState.isAuthenticated = false
            appState.lastErrorMessage = nil
            appState.clearDevices()
        }

        log("stopped")
    }

    func setError(_ error: Error) {
        lastError = error
        log("error: \(error)")
        let message = shouldShowErrorInMenu(error) ? localizedErrorMessage(for: error) : nil
        let appState = appState
        Task { @MainActor in
            appState.lastErrorMessage = message
        }
    }

    private func shouldShowErrorInMenu(_ error: Error) -> Bool {
        if error is LoginControllerError {
            return true
        }
        if let apiError = error as? ApiSessionError {
            switch apiError {
            case .authenticationFailed:
                return true
            default:
                break
            }
        }
        return false
    }

    private func localizedErrorMessage(for error: Error) -> String {
        if let loginError = error as? LoginControllerError {
            switch loginError {
            case .missingCredentials:
                return AppLocalization.text("settings.error.missing_credentials")
            case .backoffActive:
                return AppLocalization.text("settings.error.backoff")
            case .authenticationFailed:
                return AppLocalization.text("settings.error.auth_failed")
            }
        }

        if let apiError = error as? ApiSessionError {
            switch apiError {
            case .authenticationFailed:
                return AppLocalization.text("settings.error.auth_failed")
            default:
                break
            }
        }

        return String(describing: error)
    }

    private func refreshDevices() async throws {
        guard let api else {
            log("refreshDevices skipped; api unavailable")
            return
        }
        log("refreshDevices begin devices=\(api.devices.count)")
        do {
            _ = try await ApiPoller.pollSites(api: api)
            _ = try await ApiPoller.pollDeviceDetails(api: api)
            await updateAppStateFromApi(api: api)

            if let mqttSession {
                log("refreshDevices subscribe existing mqtt connected=\(mqttSession.isConnected())")
                subscribeDevices(mqtt: mqttSession, api: api)
            } else {
                log("refreshDevices no mqtt session to subscribe")
            }
            log("refreshDevices complete devices=\(api.devices.count)")
        } catch {
            log("refreshDevices failed error=\(error)")
            throw error
        }
    }

    private func startPollingLoop() {
        if pollTask != nil {
            log("restarting poll task")
        } else {
            log("starting poll task")
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            self.log("poll task entered")
            while !Task.isCancelled, self.isStarted {
                do {
                    try await self.refreshDevices()
                } catch {
                    self.log("poll task refresh error=\(error)")
                    self.setError(error)
                }
                let delay = max(5, self.configuration.pollIntervalSeconds)
                self.log("poll task sleeping seconds=\(delay)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            self.log("poll task exited cancelled=\(Task.isCancelled) isStarted=\(self.isStarted)")
        }
    }

    private func connectMqttIfNeeded() async {
        guard let api else {
            log("connectMqttIfNeeded skipped; api unavailable")
            return
        }
        log(
            "connectMqttIfNeeded begin existingSession=\(mqttSession != nil) existingConnected=\(mqttSession?.isConnected() ?? false)"
        )
        if let existing = mqttSession, existing.isConnected() {
            log("connectMqttIfNeeded reusing connected session")
            await configureMqttMonitor(api: api, mqtt: existing)
            return
        }

        log("connectMqttIfNeeded requesting api.startMqttSession")
        guard let mqtt = await api.startMqttSession() as? MqttSession else {
            log("MQTT session start failed")
            return
        }
        mqttSession = mqtt
        log("connectMqttIfNeeded obtained session connected=\(mqtt.isConnected())")

        if mqtt.isConnected() {
            await configureMqttMonitor(api: api, mqtt: mqtt)
        } else {
            log("MQTT session not connected")
        }
    }

    private func configureMqttMonitor(api: SolixApi, mqtt: MqttSession) async {
        api.logger(
            "MQTT: configure monitor start connected=\(mqtt.isConnected()) devices=\(api.devices.count)"
        )
        let debugMqtt =
            ProcessInfo.processInfo.environment["SOLIX_MQTT_DEBUG"] == "1"
            || ProcessInfo.processInfo.arguments.contains("SOLIX_MQTT_DEBUG=1")
        mqtt.message_callback { [weak self] _, topic, _, _, _, deviceSn, valueUpdate in
            if debugMqtt {
                api.logger(
                    "MQTT: received topic=\(topic) sn=\(deviceSn ?? "unknown") valueUpdate=\(valueUpdate)"
                )
            }
            guard let self else {
                api.logger("MQTT: callback dropped because coordinator is gone")
                return
            }
            guard let deviceSn else {
                api.logger("MQTT: callback missing deviceSn topic=\(topic)")
                return
            }
            guard valueUpdate else {
                if debugMqtt {
                    api.logger("MQTT: callback ignored non-value update sn=\(deviceSn)")
                }
                return
            }
            _ = api.update_device_mqtt(deviceSn: deviceSn)
            self.handleMqttUpdate(deviceSn: deviceSn)
        }

        subscribeDevices(mqtt: mqtt, api: api)
        api.logger("MQTT: subscribed topics, requesting initial data")
        try? await Task.sleep(nanoseconds: 500_000_000)
        await requestInitialMqttData(api: api)
        // Fallback: some devices only respond to status_request.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await requestStatusRefresh(api: api)
        startRealtimeTriggerLoop()
        if debugMqtt {
            api.logger("MQTT: debug waiting for inbound data (10s)")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            api.logger("MQTT: debug wait complete")
        }
        api.logger("MQTT: configure monitor complete")
    }

    private func requestInitialMqttData(api: SolixApi) async {
        var apiDevices = Array(api.devices.values)
        if apiDevices.isEmpty {
            for attempt in 1...5 {
                api.logger("MQTT: device cache empty; retrying (\(attempt)/5)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                apiDevices = Array(api.devices.values)
                if !apiDevices.isEmpty { break }
            }
        }
        let deviceSns = apiDevices.compactMap { deviceSn(from: $0) }
        api.logger("MQTT: request initial data for devices=\(deviceSns)")
        if deviceSns.isEmpty, let sample = apiDevices.first {
            api.logger("MQTT: device_sn missing; keys=\(Array(sample.keys).sorted())")
        }
        for device in apiDevices {
            let deviceSn = deviceSn(from: device) ?? "unknown"
            let factory = SolixMqttDeviceFactory(api: api, deviceSn: deviceSn)
            guard let mqttDevice = factory.createDevice(device: device) else {
                api.logger("MQTT: skip device \(deviceSn) (no MQTT device)")
                continue
            }
            let result = await mqttDevice.sendCommand(
                SolixMqttCommands.realtimeTrigger,
                parameters: ["trigger_timeout_sec": SolixDefaults.triggerTimeoutDef],
                description: "realtime trigger"
            )
            if result == nil {
                api.logger("MQTT: realtime trigger failed for \(deviceSn); trying status request")
                _ = await mqttDevice.sendCommand(
                    SolixMqttCommands.statusRequest,
                    parameters: nil,
                    description: "status request"
                )
            } else {
                api.logger("MQTT: realtime trigger sent for \(deviceSn)")
            }
        }
    }

    private func requestStatusRefresh(api: SolixApi) async {
        let apiDevices = Array(api.devices.values)
        for device in apiDevices {
            let deviceSn = deviceSn(from: device) ?? "unknown"
            let factory = SolixMqttDeviceFactory(api: api, deviceSn: deviceSn)
            guard let mqttDevice = factory.createDevice(device: device) else { continue }
            _ = await mqttDevice.sendCommand(
                SolixMqttCommands.statusRequest,
                parameters: nil,
                description: "status request (fallback)"
            )
        }
    }

    private func startRealtimeTriggerLoop() {
        if mqttRefreshTask != nil {
            log("restarting realtime trigger task")
        } else {
            log("starting realtime trigger task")
        }
        mqttRefreshTask?.cancel()
        mqttRefreshTask = Task { [weak self] in
            guard let self else { return }
            let timeout = Double(SolixDefaults.triggerTimeoutDef)
            let maxTimeout = Double(SolixDefaults.triggerTimeoutMax)
            let intervalSeconds = max(30.0, min(timeout, maxTimeout) * 0.8)
            self.log("realtime trigger task entered intervalSeconds=\(intervalSeconds)")
            while !Task.isCancelled, self.isStarted {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled || !self.isStarted { break }
                guard let api = self.api else {
                    self.log("realtime trigger task skipped; api unavailable")
                    continue
                }
                self.log("realtime trigger task requesting initial mqtt data")
                await self.requestInitialMqttData(api: api)
            }
            self.log(
                "realtime trigger task exited cancelled=\(Task.isCancelled) isStarted=\(self.isStarted)"
            )
        }
    }

    private func deviceSn(from device: [String: Any]) -> String? {
        let keys = ["device_sn", "deviceSn", "sn", "id", "device_id", "deviceId"]
        for key in keys {
            if let value = device[key] {
                let sn = String(describing: value)
                if !sn.isEmpty { return sn }
            }
        }
        return nil
    }

    private func subscribeDevices(mqtt: MqttSession, api: SolixApi) {
        for device in api.devices.values {
            subscribeRootTopics(mqtt: mqtt, device: device)
        }
    }

    private func subscribeRootTopics(mqtt: MqttSession, device: [String: Any]) {
        let prefix = mqtt.getTopicPrefix(deviceDict: device, publish: false)
        if !prefix.isEmpty {
            mqtt.subscribe("\(prefix)#")
        }
        let cmdPrefix = mqtt.getTopicPrefix(deviceDict: device, publish: true)
        if !cmdPrefix.isEmpty {
            mqtt.subscribe("\(cmdPrefix)#")
        }
    }

    private func handleMqttUpdate(deviceSn: String) {
        guard let api else { return }
        if let device = api.devices[deviceSn] {
            updateAppStateForDevice(id: deviceSn, device: device)
            return
        }
        if let match = api.devices.first(where: { ($0.value["device_sn"] as? String) == deviceSn })
        {
            updateAppStateForDevice(id: match.key, device: match.value)
        }
    }

    private func updateAppStateFromApi(api: SolixApi) async {
        let devices = api.devices
        let currentIds = Set(devices.keys)
        let appState = appState
        await MainActor.run {
            for id in appState.devices.keys where !currentIds.contains(id) {
                appState.removeDevice(id: id)
            }
        }
        for (id, device) in devices {
            updateAppStateForDevice(id: id, device: device)
        }
    }

    private func updateAppStateForDevice(id: String, device: [String: Any]) {
        let debugMqtt =
            ProcessInfo.processInfo.environment["SOLIX_MQTT_DEBUG"] == "1"
            || ProcessInfo.processInfo.arguments.contains("SOLIX_MQTT_DEBUG=1")
        let name = deviceName(from: device)
        let mqttData = device["mqtt_data"] as? [String: Any] ?? [:]

        let batteryPercent = mqttFirstInt(
            names: [
                "battery_soc",
                "battery_soc_total",
                "main_battery_soc",
                "battery_soc_calc",
                "battery_percent",
                "battery_percentage",
                "soc",
            ],
            mqttData: mqttData,
            device: device
        )
        let outputWatts = mqttFirstInt(
            names: [
                "output_power_total",
                "output_power",
                "ac_output_power_total",
                "ac_output_power",
                "dc_output_power_total",
                "dc_output_power",
            ],
            mqttData: mqttData,
            device: device
        )
        let acInputWatts = mqttMaxInt(
            names: [
                "ac_input_power",
                "ac_input_power_total",
                "grid_to_battery_power",
                "battery_power_signed_total",
                "battery_power_signed",
            ],
            mqttData: mqttData,
            device: device
        )
        let dcInputWatts = mqttMaxInt(
            names: [
                "dc_input_power_total",
                "dc_input_power",
                "pv_power_total",
                "photovoltaic_power",
            ],
            mqttData: mqttData,
            device: device
        )
        let pvWatts = mqttFirstInt(
            names: [
                "photovoltaic_power",
                "pv_power_total",
            ],
            mqttData: mqttData,
            device: device
        )
        let inputWatts: Int
        if let pvWatts {
            if let acInputWatts,
                let dcInputWatts,
                acInputWatts == pvWatts,
                dcInputWatts == pvWatts
            {
                inputWatts = pvWatts
            } else if let acInputWatts,
                let dcInputWatts,
                dcInputWatts == 0,
                acInputWatts == pvWatts
            {
                inputWatts = acInputWatts
            } else {
                inputWatts = (acInputWatts ?? 0) + (dcInputWatts ?? 0)
            }
        } else {
            inputWatts = (acInputWatts ?? 0) + (dcInputWatts ?? 0)
        }

        let outputWattsFinal = outputWatts
        let inputWattsFinal: Int? = inputWatts

        if debugMqtt {
            let keys = mqttData.keys.sorted()
            let pairs = keys.map { key -> String in
                let value = mqttData[key].map { String(describing: $0) } ?? "nil"
                return "\(key)=\(value)"
            }
            log("MQTT: device=\(id) keys=\(keys)")
            log("MQTT: device=\(id) data=\(pairs)")
            log(
                "MQTT: device=\(id) battery=\(batteryPercent?.description ?? "nil") out=\(outputWattsFinal?.description ?? "nil") in=\(inputWattsFinal?.description ?? "nil")"
            )
        }

        let appState = appState
        Task { @MainActor in
            appState.updateDevice(
                id: id,
                name: name,
                batteryPercent: batteryPercent,
                outputWatts: outputWattsFinal,
                inputWatts: inputWattsFinal
            )
        }
    }

    private func mqttFirstInt(
        names: [String],
        mqttData: [String: Any],
        device: [String: Any]
    ) -> Int? {
        for name in names {
            if let value = mqttValue(named: name, mqttData: mqttData, device: device),
                let intValue = intValue(from: value)
            {
                return intValue
            }
        }
        return nil
    }

    private func mqttMaxInt(
        names: [String],
        mqttData: [String: Any],
        device: [String: Any]
    ) -> Int? {
        var maxValue: Int? = nil
        for name in names {
            if let value = mqttValue(named: name, mqttData: mqttData, device: device),
                let intValue = intValue(from: value)
            {
                if let current = maxValue {
                    maxValue = max(current, intValue)
                } else {
                    maxValue = intValue
                }
            }
        }
        return maxValue
    }

    private func mqttValue(
        named name: String,
        mqttData: [String: Any],
        device: [String: Any]
    ) -> Any? {
        if let direct = mqttData[name] {
            return direct
        }
        guard
            let model =
                (device["device_pn"] as? String)
                    ?? (device["product_code"] as? String),
            let modelMap = MqttMap.map[model]
        else {
            return nil
        }
        for (_, fieldsAny) in modelMap {
            for (fieldKey, descAny) in fieldsAny {
                guard let desc = descAny as? [String: Any] else { continue }
                if let fieldName = desc[MqttMapKeys.name] as? String, fieldName == name {
                    if let mapped = mqttData[fieldKey] {
                        return mapped
                    }
                }
            }
        }
        return nil
    }

    private func deviceName(from device: [String: Any]) -> String {
        if let alias = device["alias"] as? String, !alias.isEmpty {
            return alias
        }
        if let name = device["device_name"] as? String, !name.isEmpty {
            return name
        }
        if let name = device["name"] as? String, !name.isEmpty {
            return name
        }
        if let sn = device["device_sn"] as? String, !sn.isEmpty {
            return sn
        }
        return "Unknown"
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let doubleValue as Double:
            return Int(doubleValue)
        case let floatValue as Float:
            return Int(floatValue)
        case let number as NSNumber:
            return number.intValue
        case let stringValue as String:
            return Int(stringValue)
        default:
            return nil
        }
    }

    private func log(_ message: String) {
        AppLogger.log("\(configuration.logPrefix) \(message)")
    }
}
