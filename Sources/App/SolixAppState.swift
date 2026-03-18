import Combine
import Foundation

private let appStateLogPrefix = "[SolixAppState]"

@MainActor
final class SolixAppState: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String
        var name: String
        var batteryPercent: Int?
        var outputWatts: Int?
        var inputWatts: Int?

        init(
            id: String,
            name: String,
            batteryPercent: Int? = nil,
            outputWatts: Int? = nil,
            inputWatts: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.batteryPercent = batteryPercent
            self.outputWatts = outputWatts
            self.inputWatts = inputWatts
        }

        var percentText: String {
            guard let batteryPercent else { return "--" }
            return "\(batteryPercent)"
        }

        var outputText: String {
            let value = outputWatts.map(String.init) ?? "--"
            return "OUT: \(value) W"
        }

        var inputText: String {
            let value = inputWatts.map(String.init) ?? "--"
            return "IN: \(value) W"
        }

        var statusLine: String {
            "\(outputText) / \(inputText) / \(percentText) %"
        }
    }

    @Published private(set) var devices: [String: Device] = [:]
    @Published var isAuthenticated: Bool = false
    @Published var lastErrorMessage: String?

    var sortedDevices: [Device] {
        devices.values.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func updateDevice(
        id: String,
        name: String? = nil,
        batteryPercent: Int? = nil,
        outputWatts: Int? = nil,
        inputWatts: Int? = nil
    ) {
        let previous = devices[id]
        var device = previous ?? Device(id: id, name: name ?? id)
        if let name { device.name = name }
        if let batteryPercent { device.batteryPercent = batteryPercent }
        if let outputWatts { device.outputWatts = outputWatts }
        if let inputWatts { device.inputWatts = inputWatts }
        devices[id] = device

        let isNewDevice = previous == nil
        let previousSummary =
            "name=\(previous?.name ?? "nil") battery=\(previous?.batteryPercent.map(String.init) ?? "nil") out=\(previous?.outputWatts.map(String.init) ?? "nil") in=\(previous?.inputWatts.map(String.init) ?? "nil")"
        let newSummary =
            "name=\(device.name) battery=\(device.batteryPercent.map(String.init) ?? "nil") out=\(device.outputWatts.map(String.init) ?? "nil") in=\(device.inputWatts.map(String.init) ?? "nil")"
        AppLogger.log(
            "\(appStateLogPrefix) updateDevice id=\(id) new=\(isNewDevice) count=\(devices.count) previous=[\(previousSummary)] current=[\(newSummary)]"
        )
    }

    func removeDevice(id: String) {
        let removed = devices.removeValue(forKey: id)
        AppLogger.log(
            "\(appStateLogPrefix) removeDevice id=\(id) existed=\(removed != nil) count=\(devices.count)"
        )
    }

    func clearDevices() {
        let previousCount = devices.count
        devices.removeAll()
        AppLogger.log("\(appStateLogPrefix) clearDevices previousCount=\(previousCount)")
    }
}
