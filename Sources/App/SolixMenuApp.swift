import Cocoa

@main
@MainActor
final class SolixMenuApp: NSObject, NSApplicationDelegate {
    private let coordinator = SolixAppCoordinator()
    private var statusBarController: StatusBarController?
    private var accountSettingsWindow: AccountSettingsWindowController?
    private let terminationReason = "SolixMenu status item"

    private func logLifecycle(_ message: String) {
        AppLogger.log("[SolixMenuApp] \(message)")
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = SolixMenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLifecycle("applicationDidFinishLaunching")
        ProcessInfo.processInfo.disableAutomaticTermination(terminationReason)
        NSLog("SolixMenu: configuring status bar controller.")
        statusBarController = StatusBarController(appState: coordinator.appState)
        NSLog("SolixMenu: status bar controller configured: \(statusBarController != nil).")
        logLifecycle("status bar controller configured: \(statusBarController != nil)")
        statusBarController?.onAccountSettings = { [weak self] in
            self?.logLifecycle("account settings requested")
            self?.showAccountSettings()
        }
        statusBarController?.onAbout = { [weak self] in
            self?.logLifecycle("about requested")
            self?.showAbout()
        }
        statusBarController?.onQuit = {
            AppLogger.log("[SolixMenuApp] quit requested from status bar")
            NSApp.terminate(nil)
        }
        logLifecycle("starting coordinator task")
        Task {
            AppLogger.log("[SolixMenuApp] coordinator.start begin")
            await coordinator.start()
            AppLogger.log("[SolixMenuApp] coordinator.start end")
        }
    }

    private func showAccountSettings() {
        let credentials = CredentialStore.shared.load()
        let window = AccountSettingsWindowController(
            credentials: credentials,
            onVerify: { [weak self] credentials in
                guard let self else {
                    return .failure(ApiSessionError.authenticationFailed)
                }
                let result = await self.coordinator.applySettings(credentials)
                if case .success = result {
                    self.accountSettingsWindow = nil
                }
                return result
            },
            onCancel: { [weak self] in
                self?.accountSettingsWindow = nil
            }
        )
        accountSettingsWindow = window
        window.present()
    }

    private func showAbout() {
        AboutWindowController.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logLifecycle("applicationWillTerminate")
        ProcessInfo.processInfo.enableAutomaticTermination(terminationReason)
        logLifecycle("calling coordinator.stop")
        coordinator.stop()
        logLifecycle("applicationWillTerminate complete")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logLifecycle("applicationShouldTerminate")
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        logLifecycle("applicationDidBecomeActive")
    }

    func applicationDidResignActive(_ notification: Notification) {
        logLifecycle("applicationDidResignActive")
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        logLifecycle("applicationWillBecomeActive")
    }

    func applicationWillResignActive(_ notification: Notification) {
        logLifecycle("applicationWillResignActive")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        logLifecycle("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        return true
    }
}
