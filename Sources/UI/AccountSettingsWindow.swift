import Cocoa

@MainActor
final class AccountSettingsWindowController: NSWindowController {
    struct Configuration {
        var title: String = AppLocalization.text("settings.title")
        var minSize: NSSize = NSSize(width: 440, height: 260)
    }

    private let configuration: Configuration
    private let settingsViewController: AccountSettingsViewController

    init(
        credentials: SolixCredentials?,
        configuration: Configuration = Configuration(),
        onVerify: ((SolixCredentials) async -> Result<Void, Error>)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.settingsViewController = AccountSettingsViewController(
            credentials: credentials,
            onVerify: onVerify,
            onCancel: onCancel
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: configuration.minSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = configuration.title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = settingsViewController
        window.minSize = configuration.minSize

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window else { return }
        installEditMenuIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installEditMenuIfNeeded() {
        let app = NSApplication.shared
        if app.mainMenu == nil {
            app.mainMenu = NSMenu()
        }
        guard let mainMenu = app.mainMenu else { return }
        if mainMenu.item(withTitle: "Edit") != nil {
            return
        }

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            NSMenuItem(
                title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
    }
}

@MainActor
private final class AccountSettingsViewController: NSViewController {
    private let onVerify: ((SolixCredentials) async -> Result<Void, Error>)?
    private let onCancel: (() -> Void)?

    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let countryField = NSTextField()

    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    private let verifyButton = NSButton()
    private let cancelButton = NSButton()

    init(
        credentials: SolixCredentials?,
        onVerify: ((SolixCredentials) async -> Result<Void, Error>)?,
        onCancel: (() -> Void)?
    ) {
        self.onVerify = onVerify
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)

        if let credentials {
            emailField.stringValue = credentials.email
            passwordField.stringValue = credentials.password
            countryField.stringValue = credentials.countryId
        } else {
            countryField.stringValue = "EU"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false

        configureFields()

        let emailRow = labeledRow(title: AppLocalization.text("settings.email"), field: emailField)
        let passwordRow = labeledRow(
            title: AppLocalization.text("settings.password"),
            field: passwordField
        )
        let countryRow = labeledRow(
            title: AppLocalization.text("settings.country"),
            field: countryField
        )

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true

        progressIndicator.controlSize = .small
        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true

        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        configureButtons()

        let buttonRow = NSStackView(views: [cancelButton, verifyButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        formStack.addArrangedSubview(emailRow)
        formStack.addArrangedSubview(passwordRow)
        formStack.addArrangedSubview(countryRow)
        formStack.addArrangedSubview(statusRow)
        formStack.addArrangedSubview(buttonRow)

        view.addSubview(formStack)

        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            formStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            formStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),

            emailField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            countryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        self.view = view
    }

    private func configureFields() {
        [emailField, passwordField].forEach { field in
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.refusesFirstResponder = false
        }
    }

    private func configureButtons() {
        cancelButton.title = AppLocalization.text("settings.cancel")
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)

        verifyButton.title = AppLocalization.text("settings.login")
        verifyButton.target = self
        verifyButton.action = #selector(handleVerify)
        verifyButton.keyEquivalent = "\r"
    }

    private func labeledRow(title: String, field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right

        let grid = NSGridView(views: [[label, field]])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).width = 120

        return grid
    }

    private func currentCredentials() -> SolixCredentials? {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        let country = countryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty, !password.isEmpty, !country.isEmpty else {
            showError(AppLocalization.text("settings.error.missing_fields"))
            return nil
        }

        return SolixCredentials(
            email: email,
            password: password,
            countryId: country.uppercased()
        )
    }

    @objc private func handleVerify() {
        guard let credentials = currentCredentials() else { return }
        guard let onVerify else {
            showError(AppLocalization.text("settings.error.auth_failed"))
            return
        }

        setLoading(true, message: AppLocalization.text("settings.status.verifying"))
        Task {
            let result = await onVerify(credentials)
            switch result {
            case .success:
                showStatus(AppLocalization.text("settings.status.success"))
                closeWindow()
            case .failure(let error):
                showError(
                    error.localizedDescription.isEmpty
                        ? AppLocalization.text("settings.status.failure")
                        : error.localizedDescription
                )
            }
            setLoading(false, message: nil)
        }
    }

    @objc private func handleCancel() {
        onCancel?()
        closeWindow()
    }

    private func closeWindow() {
        if let window = view.window {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }

    private func setLoading(_ loading: Bool, message: String?) {
        progressIndicator.isHidden = !loading
        if loading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        }
    }

    private func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
    }

    private func showStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
    }

    private func hideStatus() {
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
    }
}
