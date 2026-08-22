import SwiftUI

public struct PreferencesView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("playSoundEffects") private var playSoundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: String = ""
    @AppStorage("AdiumAutoAwayEnabled") private var autoAwayEnabled: Bool = true
    @AppStorage("AdiumAutoAwayMinutes") private var autoAwayMinutes: Int = 5
    @AppStorage("AdiumAutoreplyEnabled") private var autoreplyEnabled: Bool = false
    
    @State private var showAddAccountSheet = false
    @State private var accountToConfigure: Account? = nil
    @State private var selectedAccountID: UUID?
    @State private var backupStatusMessage: String? = nil
    @State private var accountToDelete: Account? = nil
    
    public init() {}
    
    var selectedAccount: Account? {
        bridge.accounts.first(where: { $0.id == selectedAccountID })
    }
    
    public var body: some View {
        TabView {
            // Accounts tab.
            VStack(alignment: .leading, spacing: 10) {
                Text(t("Configured Accounts"))
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                
                if bridge.accounts.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                        Text(t("No accounts configured."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: { showAddAccountSheet = true }) {
                            Label(t("Add Account"), systemImage: "plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .cornerRadius(6)
                    .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 0) {
                        List(bridge.accounts, selection: $selectedAccountID) { acc in
                            HStack(spacing: 10) {
                                Image(systemName: acc.accountProtocol.iconName)
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 13))
                                    .accessibilityHidden(true)
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(acc.username)
                                        .font(.system(size: 11, weight: .medium))
                                    HStack(spacing: 4) {
                                        Text(acc.accountProtocol.rawValue)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        
                                        if acc.server != nil || acc.port != nil || acc.resource != nil {
                                            Text(t("• Advanced"))
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Circle()
                                    .fill(acc.isConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                    .help(acc.isConnected ? t("Connected") : t("Disconnected"))
                            }
                            .tag(acc.id)
                            .contextMenu {
                                Button(t("Advanced Options...")) {
                                    accountToConfigure = acc
                                }
                                Divider()
                                Button(role: .destructive) {
                                    accountToDelete = acc
                                } label: {
                                    Label(t("Delete Account"), systemImage: "trash")
                                }
                            }
                        }
                        .listStyle(.inset)
                        .cornerRadius(6)
                        
                        // Classic macOS toolbar.
                        HStack(spacing: 0) {
                            Button(action: { showAddAccountSheet = true }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(t("Add new account"))
                            .accessibilityLabel(t("Add new account"))
                            
                            Divider()
                                .frame(height: 12)
                            
                            Button(action: {
                                if let acc = selectedAccount {
                                    accountToDelete = acc
                                }
                            }) {
                                Image(systemName: "minus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedAccountID == nil)
                            .help(t("Delete selected account"))
                            .accessibilityLabel(t("Delete selected account"))
                            
                            Divider()
                                .frame(height: 12)
                            
                            Button(action: {
                                if let acc = selectedAccount {
                                    accountToConfigure = acc
                                }
                            }) {
                                Label(t("Advanced Options"), systemImage: "gearshape")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedAccountID == nil)
                            .help(t("Advanced options for the selected account"))
                            
                            Spacer()
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            Rectangle()
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                    .padding(.horizontal, 16)
                }
                
                Spacer()
                    .frame(height: 10)
            }
            .tabItem {
                Label(t("Accounts"), systemImage: "person.2.fill")
            }
            
            // General settings tab.
            VStack(alignment: .leading, spacing: 12) {
                Toggle(t("Show a notification when a message arrives"), isOn: $showNotifications)
                    .font(.system(size: 11))
                Toggle(t("Play the classic Adium sound when a message arrives"), isOn: $playSoundEffects)
                    .font(.system(size: 11))
                Toggle(t("Show offline contacts in the list"), isOn: $showOfflineContacts)
                    .font(.system(size: 11))
                Toggle(t("Start Adium when the Mac starts"), isOn: $launchAtLogin)
                    .font(.system(size: 11))
                Toggle(t("Set status to Away when inactive"), isOn: $autoAwayEnabled)
                    .font(.system(size: 11))
                if autoAwayEnabled {
                    Picker(t("Away after:"), selection: $autoAwayMinutes) {
                        ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                            Text(t("\(minutes) min")).tag(minutes)
                        }
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: 280, alignment: .leading)
                }

                Divider()

                Toggle(t("Answer with an away notice when someone writes to you"), isOn: $autoreplyEnabled)
                    .font(.system(size: 11))

                Divider()

                Picker(t("Language:"), selection: $appLanguage) {
                    Text(t("System default")).tag("")
                    ForEach(AppLanguage.options) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: 280, alignment: .leading)

                Text(t("Restart Adium to apply the language change."))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(16)
            .tabItem {
                Label(t("General"), systemImage: "gearshape.fill")
            }
            
            // Events engine settings tab.
            EventsPreferencesTab()
                .tabItem {
                    Label(t("Events"), systemImage: "bell.badge.fill")
                }

            // Optional protocol plugins tab.
            PluginsPreferencesTab()
                .tabItem {
                    Label(t("Plugins"), systemImage: "puzzlepiece.extension.fill")
                }

            // Backup and data tab.
            VStack(alignment: .leading, spacing: 14) {
                Text(t("Backup & Data"))
                    .font(.system(size: 13, weight: .bold))
                
                Text(t("Export or restore the complete Adium configuration, accounts, contact list, and chat history (without plaintext passwords)."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Divider()
                
                // System stats.
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Current Data Summary"))
                        .font(.system(size: 11, weight: .semibold))
                    
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text(t("Accounts:"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(bridge.accounts.count)")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        VStack(alignment: .leading) {
                            Text(t("Contacts:"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(bridge.contacts.count)")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        VStack(alignment: .leading) {
                            Text(t("Transcripts:"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(t("\(ChatLogStore.shared.allLogHandles().count) chats"))
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .cornerRadius(6)
                }
                
                Divider()
                
                HStack(spacing: 10) {
                    Button(action: {
                        BackupManager.shared.promptExportBackup { result in
                            switch result {
                            case .success(let url):
                                backupStatusMessage = t("Backup exported successfully to \(url.lastPathComponent)")
                            case .failure(let error):
                                backupStatusMessage = t("Error while exporting: \(error.localizedDescription)")
                            }
                        }
                    }) {
                        Label(t("Export Backup..."), systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button(action: {
                        BackupManager.shared.promptImportBackup { result in
                            switch result {
                            case .success(let url):
                                backupStatusMessage = t("Backup restored successfully from \(url.lastPathComponent)")
                            case .failure(let error):
                                backupStatusMessage = t("Error while restoring: \(error.localizedDescription)")
                            }
                        }
                    }) {
                        Label(t("Restore Backup..."), systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        TranscriptViewerWindowController.shared.show()
                    }) {
                        Label(t("Open Viewer"), systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                    }
                }
                
                if let status = backupStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: status.contains("Error") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(status.contains("Error") ? .red : .green)
                            .accessibilityHidden(true)
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
                
                Spacer()
            }
            .padding(16)
            .tabItem {
                Label(t("Backup & Data"), systemImage: "externaldrive.fill")
            }
        }
        .frame(width: 540, height: 380)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
        .sheet(item: $accountToConfigure) { acc in
            AccountOptionsSheet(account: acc, isPresented: Binding(get: { accountToConfigure != nil }, set: { if !$0 { accountToConfigure = nil } }))
        }
        .sheet(item: $accountToDelete) { acc in
            DeleteAccountSheet(account: acc) { deleteLogs in
                bridge.removeAccount(acc, deleteChatLogs: deleteLogs)
                if selectedAccountID == acc.id {
                    selectedAccountID = nil
                }
            }
        }
    }
}

struct DeleteAccountSheet: View {
    let account: Account
    let onConfirm: (_ deleteChatLogs: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deleteChatLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Delete the account \(account.username)?"))
                        .font(.system(size: 12, weight: .bold))
                    Text(t("The account, its password, and its contacts will be removed. This action cannot be undone."))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Toggle(t("Also delete the chat history of this account"), isOn: $deleteChatLogs)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            HStack {
                Spacer()
                Button(t("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(t("Delete"), role: .destructive) {
                    onConfirm(deleteChatLogs)
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

public struct AddAccountSheet: View {
    @Binding var isPresented: Bool
    @Bindable var bridge = PurpleBridgeService.shared
    
    @State private var selectedProtocol: AccountProtocol = .teams
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showAdvancedOptions = false
    
    @State private var server: String = ""
    @State private var port: String = ""
    @State private var resource: String = ""
    @State private var useSSL: Bool = true
    
    var usernameLabel: String {
        switch selectedProtocol {
        case .teams:
            return t("Teams email:")
        case .whatsapp:
            return t("Phone (e.g. +34600000000):")
        case .xmpp:
            return t("JID / Username:")
        default:
            return t("Username / Email:")
        }
    }
    
    var isFormValid: Bool {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty { return false }
        if selectedProtocol == .teams || selectedProtocol == .whatsapp {
            return true
        }
        return !password.isEmpty
    }
    
    public var body: some View {
        VStack(spacing: 14) {
            Text(t("Add Messaging Account"))
                .font(.system(size: 13, weight: .bold))
            
            Form {
                Picker(t("Protocol:"), selection: $selectedProtocol) {
                    ForEach(AccountProtocol.allCases, id: \.self) { proto in
                        Label(proto.rawValue, systemImage: proto.iconName)
                            .tag(proto)
                    }
                }
                .font(.system(size: 11))
                
                TextField(usernameLabel, text: $username)
                    .font(.system(size: 11))
                
                if selectedProtocol == .teams {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "safari")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                        Text(t("Microsoft Teams uses OAuth2 web authentication. When you click Connect, your browser opens so you can sign in to Microsoft."))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                } else if selectedProtocol == .whatsapp {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "qrcode")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                        Text(t("WhatsApp uses QR code or phone pairing to link. When you click Connect, the link procedure starts."))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    SecureField(t("Password:"), text: $password)
                        .font(.system(size: 11))
                    
                    DisclosureGroup(t("Advanced Options (Server, Port...)"), isExpanded: $showAdvancedOptions) {
                        TextField(t("Server (e.g. jabber.org):"), text: $server)
                            .font(.system(size: 11))
                        TextField(t("Port (e.g. 5222):"), text: $port)
                            .font(.system(size: 11))
                        TextField(t("XMPP Resource (e.g. Adium):"), text: $resource)
                            .font(.system(size: 11))
                        Toggle(t("Use Secure Connection (SSL/TLS)"), isOn: $useSSL)
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 10, weight: .medium))
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedProtocol) { _, _ in
                // Advanced options are protocol-specific.
                // Do not carry stale values over to a newly selected protocol.
                server = ""
                port = ""
                resource = ""
                useSSL = true
                showAdvancedOptions = false
            }

            HStack {
                Button(t("Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(t("Connect")) {
                    let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedUser.isEmpty else { return }
                    let pass = (selectedProtocol == .teams || selectedProtocol == .whatsapp) ? "" : password
                    let pInt = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
                    bridge.connectAccount(
                        username: trimmedUser,
                        protocolType: selectedProtocol,
                        password: pass,
                        server: server.isEmpty ? nil : server,
                        port: pInt,
                        resource: resource.isEmpty ? nil : resource,
                        useSSL: useSSL
                    )
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)
            }
        }
        .padding(16)
        .frame(width: 400, height: (selectedProtocol == .teams || selectedProtocol == .whatsapp) ? 260 : (showAdvancedOptions ? 380 : 250))
    }
}

public struct AccountOptionsSheet: View {
    let account: Account
    @Binding var isPresented: Bool
    @Bindable var bridge = PurpleBridgeService.shared
    
    @State private var server: String = ""
    @State private var port: String = ""
    @State private var resource: String = ""
    @State private var useSSL: Bool = true
    @State private var customOptionsText: String = ""
    
    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: account.accountProtocol.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Advanced Options per Service"))
                        .font(.system(size: 13, weight: .bold))
                    Text("\(account.username) (\(account.accountProtocol.rawValue))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Form {
                Section(header: Text(t("Server & Connection")).font(.system(size: 10, weight: .bold))) {
                    TextField(t("Server host:"), text: $server)
                        .font(.system(size: 11))
                    TextField(t("Port:"), text: $port)
                        .font(.system(size: 11))
                    TextField(t("Resource / Identifier:"), text: $resource)
                        .font(.system(size: 11))
                    Toggle(t("Use Secure Connection (SSL/TLS)"), isOn: $useSSL)
                        .font(.system(size: 11))
                }
                
                Section(header: Text(t("Extra Libpurple Options (key=value per line)")).font(.system(size: 10, weight: .bold))) {
                    TextEditor(text: $customOptionsText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 60)
                }
            }
            .formStyle(.grouped)
            .onAppear {
                server = account.server ?? ""
                port = account.port.map { String($0) } ?? ""
                resource = account.resource ?? ""
                useSSL = account.useSSL ?? true
                
                var lines: [String] = []
                for (k, v) in account.customOptions {
                    lines.append("\(k)=\(v)")
                }
                customOptionsText = lines.joined(separator: "\n")
            }
            
            HStack {
                Button(t("Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(t("Save Changes")) {
                    let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
                    var optionsDict: [String: String] = [:]
                    let lines = customOptionsText.components(separatedBy: .newlines)
                    for line in lines {
                        let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        if parts.count == 2 && !parts[0].isEmpty {
                            optionsDict[parts[0]] = parts[1]
                        }
                    }
                    
                    bridge.updateAccountOptions(
                        accountID: account.id,
                        server: server.isEmpty ? nil : server,
                        port: parsedPort,
                        resource: resource.isEmpty ? nil : resource,
                        useSSL: useSSL,
                        customOptions: optionsDict
                    )
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420, height: 380)
    }
}

public struct EventsPreferencesTab: View {
    @Bindable var eventManager = EventManager.shared
    
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("Adium Events Engine"))
                    .font(.system(size: 13, weight: .bold))
                
                Text(t("Configure how Adium responds to system events (sounds, Dock bounce, and badges)."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Divider()
                
                ForEach(AdiumEventType.allCases) { eventType in
                    if let rule = eventManager.rules[eventType] {
                        EventRuleConfigRow(rule: rule) { updatedRule in
                            eventManager.updateRule(updatedRule)
                        }
                        Divider()
                    }
                }
            }
            .padding(16)
        }
    }
}

struct EventRuleConfigRow: View {
    let rule: EventRule
    let onUpdate: (EventRule) -> Void
    
    @State var playSound: Bool = true
    @State var soundName: String = "Tink"
    @State var bounceDock: Bool = false
    @State var updateBadge: Bool = false
    @State var showNotification: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rule.eventType.displayName)
                    .font(.system(size: 11, weight: .bold))
                
                Spacer()
                
                Button(action: {
                    EventManager.shared.triggerEvent(
                        rule.eventType,
                        title: t("Test: \(rule.eventType.displayName)"),
                        content: t("Test of the event sound and reaction.")
                    )
                }) {
                    Label(t("Test Event"), systemImage: "play.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Toggle(t("Play sound"), isOn: $playSound)
                        .font(.system(size: 11))
                    
                    if playSound {
                        Picker(t("Effect:"), selection: $soundName) {
                            ForEach(EventManager.availableSounds, id: \.self) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .font(.system(size: 10))
                        .frame(width: 150)
                    }
                }
                
                GridRow {
                    Toggle(t("Bounce Dock icon"), isOn: $bounceDock)
                        .font(.system(size: 11))
                    
                    Toggle(t("Dock badge counter"), isOn: $updateBadge)
                        .font(.system(size: 11))
                }
                
                GridRow {
                    Toggle(t("macOS notification"), isOn: $showNotification)
                        .font(.system(size: 11))
                }
            }
        }
        .onAppear {
            playSound = rule.playSound
            soundName = rule.soundName
            bounceDock = rule.bounceDock
            updateBadge = rule.updateBadge
            showNotification = rule.showNotification
        }
        .onChange(of: playSound) { _, _ in save() }
        .onChange(of: soundName) { _, _ in save() }
        .onChange(of: bounceDock) { _, _ in save() }
        .onChange(of: updateBadge) { _, _ in save() }
        .onChange(of: showNotification) { _, _ in save() }
    }
    
    private func save() {
        var updated = rule
        updated.playSound = playSound
        updated.soundName = soundName
        updated.bounceDock = bounceDock
        updated.updateBadge = updateBadge
        updated.showNotification = showNotification
        onUpdate(updated)
    }
}

