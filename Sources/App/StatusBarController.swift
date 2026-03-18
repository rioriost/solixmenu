import Cocoa
import Combine

@MainActor
final class StatusBarController: NSObject {
    private func attributedLine(for device: SolixAppState.Device) -> NSAttributedString {
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let valueFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let outAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.systemRed,
        ]
        let inAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.systemGreen,
        ]

        let result = NSMutableAttributedString(
            string: device.name,
            attributes: nameAttributes
        )

        result.append(NSAttributedString(string: "  ", attributes: valueAttributes))
        result.append(
            NSAttributedString(
                string: "OUT: \(wattText(device.outputWatts)) W",
                attributes: outAttributes
            )
        )
        result.append(NSAttributedString(string: " / ", attributes: valueAttributes))
        result.append(
            NSAttributedString(
                string: "IN: \(wattText(device.inputWatts)) W",
                attributes: inAttributes
            )
        )
        result.append(NSAttributedString(string: " / ", attributes: valueAttributes))
        result.append(
            NSAttributedString(
                string: "\(percentText(device.batteryPercent)) %",
                attributes: valueAttributes
            )
        )
        return result
    }

    private func wattText(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }

    private func percentText(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let appState: SolixAppState
    private var deviceItems: [NSMenuItem] = []
    private var errorItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    var onAccountSettings: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    init(appState: SolixAppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()
        configureStatusItem()
        configureMenu()
        bindState()
    }

    private func configureStatusItem() {
        statusItem.isVisible = true
        if let button = statusItem.button {
            let image = statusImage(isAuthenticated: appState.isAuthenticated)
            button.image = image
            button.title = AppLocalization.text("about.title")
            if image == nil {
                button.imagePosition = .noImage
                AppLogger.log("Status bar image unavailable; showing title only.")
            } else {
                button.imagePosition = .imageLeft
            }
            button.toolTip = AppLocalization.text("about.title")
            button.setAccessibilityLabel(AppLocalization.text("about.title"))
        } else {
            AppLogger.log("Status bar button is nil; status item may not be visible.")
        }
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        updateDeviceItems()
        addFixedItems()
    }

    private func bindState() {
        appState.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDeviceItems()
            }
            .store(in: &cancellables)

        appState.$isAuthenticated
            .receive(on: RunLoop.main)
            .sink { [weak self] isAuthenticated in
                guard let self else { return }
                if let button = self.statusItem.button {
                    button.image = self.statusImage(isAuthenticated: isAuthenticated)
                }
            }
            .store(in: &cancellables)

        appState.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDeviceItems()
            }
            .store(in: &cancellables)
    }

    private func updateDeviceItems() {
        AppLogger.log(
            "StatusBarController: updateDeviceItems start devices=\(appState.devices.count) hasError=\((appState.lastErrorMessage?.isEmpty == false)) menuItems=\(menu.items.count)"
        )
        for item in deviceItems {
            menu.removeItem(item)
        }
        deviceItems.removeAll()

        if let errorItem {
            menu.removeItem(errorItem)
            self.errorItem = nil
        }

        let devices = appState.sortedDevices

        if devices.isEmpty {
            if appState.lastErrorMessage == nil || appState.lastErrorMessage?.isEmpty == true {
                let item = NSMenuItem(
                    title: AppLocalization.text("menu.no_devices"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                deviceItems.append(item)
            }
        } else {
            for device in devices {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = attributedLine(for: device)
                deviceItems.append(item)
            }
        }

        if let message = appState.lastErrorMessage, !message.isEmpty {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 0)
            errorItem = item
        }

        let offset = errorItem == nil ? 0 : 1
        for (index, item) in deviceItems.enumerated() {
            menu.insertItem(item, at: index + offset)
        }
        AppLogger.log(
            "StatusBarController: updateDeviceItems done insertedDevices=\(deviceItems.count) errorVisible=\(errorItem != nil) totalMenuItems=\(menu.items.count)"
        )
    }

    private func addFixedItems() {
        if !menu.items.contains(where: { $0.isSeparatorItem }) {
            menu.addItem(NSMenuItem.separator())
        }

        let accountItem = NSMenuItem(
            title: AppLocalization.text("menu.account_settings"),
            action: #selector(handleAccountSettings),
            keyEquivalent: ""
        )
        accountItem.target = self
        menu.addItem(accountItem)

        let aboutItem = NSMenuItem(
            title: AppLocalization.text("menu.about"),
            action: #selector(handleAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: AppLocalization.text("menu.quit"),
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func statusImage(isAuthenticated: Bool) -> NSImage? {
        let symbolNames = ["circle.fill", "circle"]
        for name in symbolNames {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                image.isTemplate = true
                let tinted = image.copy() as? NSImage ?? image
                tinted.isTemplate = false
                tinted.lockFocus()
                (isAuthenticated ? NSColor.systemGreen : NSColor.tertiaryLabelColor).set()
                let rect = NSRect(origin: .zero, size: tinted.size)
                rect.fill(using: .sourceAtop)
                tinted.unlockFocus()
                return tinted
            }
        }
        return nil
    }

    @objc private func handleAccountSettings() {
        if let onAccountSettings {
            onAccountSettings()
        }
    }

    @objc private func handleAbout() {
        if let onAbout {
            onAbout()
        } else {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func handleQuit() {
        AppLogger.log("StatusBarController: Quit menu selected")
        if let onQuit {
            AppLogger.log("StatusBarController: forwarding quit action to app delegate")
            onQuit()
        } else {
            AppLogger.log("StatusBarController: terminating app directly from status bar")
            NSApp.terminate(nil)
        }
    }

}
