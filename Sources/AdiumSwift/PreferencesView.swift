import SwiftUI

public struct PreferencesView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("playSoundEffects") private var playSoundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    
    @State private var showAddAccountSheet = false
    @State private var accountToConfigure: Account? = nil
    @State private var selectedAccountID: UUID?
    @State private var backupStatusMessage: String? = nil
    
    public init() {}
    
    var selectedAccount: Account? {
        bridge.accounts.first(where: { $0.id == selectedAccountID })
    }
    
    public var body: some View {
        TabView {
            // Accounts Tab
            VStack(alignment: .leading, spacing: 10) {
                Text("Cuentas Configuradas")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                
                if bridge.accounts.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("No hay cuentas configuradas.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: { showAddAccountSheet = true }) {
                            Label("Añadir Cuenta", systemImage: "plus")
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
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(acc.username)
                                        .font(.system(size: 11, weight: .medium))
                                    HStack(spacing: 4) {
                                        Text(acc.accountProtocol.rawValue)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        
                                        if acc.server != nil || acc.port != nil || acc.resource != nil {
                                            Text("• Avanzada")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Circle()
                                    .fill(acc.isConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                    .help(acc.isConnected ? "Conectado" : "Desconectado")
                            }
                            .tag(acc.id)
                            .contextMenu {
                                Button("Opciones Avanzadas...") {
                                    accountToConfigure = acc
                                }
                                Divider()
                                Button(role: .destructive) {
                                    bridge.removeAccount(acc)
                                    if selectedAccountID == acc.id {
                                        selectedAccountID = nil
                                    }
                                } label: {
                                    Label("Eliminar Cuenta", systemImage: "trash")
                                }
                            }
                        }
                        .listStyle(.inset)
                        .cornerRadius(6)
                        
                        // Classic macOS toolbar + / - / gear
                        HStack(spacing: 0) {
                            Button(action: { showAddAccountSheet = true }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Añadir nueva cuenta")
                            
                            Divider()
                                .frame(height: 12)
                            
                            Button(action: {
                                if let acc = selectedAccount {
                                    bridge.removeAccount(acc)
                                    selectedAccountID = nil
                                }
                            }) {
                                Image(systemName: "minus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedAccountID == nil)
                            .help("Eliminar cuenta seleccionada")
                            
                            Divider()
                                .frame(height: 12)
                            
                            Button(action: {
                                if let acc = selectedAccount {
                                    accountToConfigure = acc
                                }
                            }) {
                                Label("Opciones Avanzadas", systemImage: "gearshape")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedAccountID == nil)
                            .help("Opciones avanzadas de la cuenta seleccionada")
                            
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
                Label("Cuentas", systemImage: "person.2.fill")
            }
            
            // General Settings Tab
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Mostrar notificación al recibir un mensaje", isOn: $showNotifications)
                    .font(.system(size: 11))
                Toggle("Reproducir sonido clásico de Adium al recibir mensaje", isOn: $playSoundEffects)
                    .font(.system(size: 11))
                Toggle("Mostrar contactos desconectados en la lista", isOn: $showOfflineContacts)
                    .font(.system(size: 11))
                Toggle("Iniciar Adium al encender el Mac", isOn: $launchAtLogin)
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(16)
            .tabItem {
                Label("General", systemImage: "gearshape.fill")
            }
            
            // Events Engine Settings Tab
            EventsPreferencesTab()
                .tabItem {
                    Label("Eventos", systemImage: "bell.badge.fill")
                }

            
            // Backup & Data Tab
            VStack(alignment: .leading, spacing: 14) {
                Text("Respaldo y Datos")
                    .font(.system(size: 13, weight: .bold))
                
                Text("Exporta o restaura la configuración completa de Adium, cuentas, lista de contactos y el historial de chats (sin contraseñas en claro).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Divider()
                
                // System stats
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resumen de Datos Actuales")
                        .font(.system(size: 11, weight: .semibold))
                    
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text("Cuentas:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(bridge.accounts.count)")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Contactos:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(bridge.contacts.count)")
                                .font(.system(size: 14, weight: .bold))
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Transcripciones:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(ChatLogStore.shared.allLogHandles().count) chats")
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
                                backupStatusMessage = "Respaldo exportado exitosamente en \(url.lastPathComponent)"
                            case .failure(let error):
                                backupStatusMessage = "Error al exportar: \(error.localizedDescription)"
                            }
                        }
                    }) {
                        Label("Exportar Respaldo...", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button(action: {
                        BackupManager.shared.promptImportBackup { result in
                            switch result {
                            case .success(let url):
                                backupStatusMessage = "Respaldo restaurado exitosamente desde \(url.lastPathComponent)"
                            case .failure(let error):
                                backupStatusMessage = "Error al restaurar: \(error.localizedDescription)"
                            }
                        }
                    }) {
                        Label("Restaurar Respaldo...", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        TranscriptViewerWindowController.shared.show()
                    }) {
                        Label("Abrir Visor", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                    }
                }
                
                if let status = backupStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: status.contains("Error") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(status.contains("Error") ? .red : .green)
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
                Label("Respaldo y Datos", systemImage: "externaldrive.fill")
            }
        }
        .frame(width: 540, height: 380)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
        .sheet(item: $accountToConfigure) { acc in
            AccountOptionsSheet(account: acc, isPresented: Binding(get: { accountToConfigure != nil }, set: { if !$0 { accountToConfigure = nil } }))
        }
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
            return "Email de Teams:"
        case .whatsapp:
            return "Teléfono (ej. +34600000000):"
        case .xmpp:
            return "JID / Usuario:"
        default:
            return "Usuario / Email:"
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
            Text("Añadir Cuenta de Mensajería")
                .font(.system(size: 13, weight: .bold))
            
            Form {
                Picker("Protocolo:", selection: $selectedProtocol) {
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
                        Text("Microsoft Teams utiliza autenticación web OAuth2. Al hacer clic en Conectar se abrirá tu navegador para iniciar sesión en Microsoft.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                } else if selectedProtocol == .whatsapp {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "qrcode")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 12))
                        Text("WhatsApp utiliza vinculación por código QR o par telefónico. Al hacer clic en Conectar se iniciará el proceso de vinculación.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    SecureField("Contraseña:", text: $password)
                        .font(.system(size: 11))
                    
                    DisclosureGroup("Opciones Avanzadas (Servidor, Puerto...)", isExpanded: $showAdvancedOptions) {
                        TextField("Servidor (ej. jabber.org):", text: $server)
                            .font(.system(size: 11))
                        TextField("Puerto (ej. 5222):", text: $port)
                            .font(.system(size: 11))
                        TextField("Resource XMPP (ej. Adium):", text: $resource)
                            .font(.system(size: 11))
                        Toggle("Usar Conexión Segura (SSL/TLS)", isOn: $useSSL)
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 10, weight: .medium))
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedProtocol) { _, _ in
                // Advanced options are protocol-specific (e.g. XMPP server/port/resource);
                // stale values must not silently carry over to a newly selected protocol.
                server = ""
                port = ""
                resource = ""
                useSSL = true
                showAdvancedOptions = false
            }

            HStack {
                Button("Cancelar") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Conectar") {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opciones Avanzadas por Servicio")
                        .font(.system(size: 13, weight: .bold))
                    Text("\(account.username) (\(account.accountProtocol.rawValue))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Form {
                Section(header: Text("Servidor y Conexión").font(.system(size: 10, weight: .bold))) {
                    TextField("Servidor (Server host):", text: $server)
                        .font(.system(size: 11))
                    TextField("Puerto:", text: $port)
                        .font(.system(size: 11))
                    TextField("Resource / Identificador:", text: $resource)
                        .font(.system(size: 11))
                    Toggle("Usar Conexión Segura (SSL/TLS)", isOn: $useSSL)
                        .font(.system(size: 11))
                }
                
                Section(header: Text("Opciones Libpurple Extra (clave=valor por línea)").font(.system(size: 10, weight: .bold))) {
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
                Button("Cancelar") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Guardar Cambios") {
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
                Text("Motor de Eventos de Adium")
                    .font(.system(size: 13, weight: .bold))
                
                Text("Configura cómo responde Adium a los eventos del sistema (sonidos, rebote del Dock y badges).")
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
                Text(rule.eventType.rawValue)
                    .font(.system(size: 11, weight: .bold))
                
                Spacer()
                
                Button(action: {
                    EventManager.shared.triggerEvent(
                        rule.eventType,
                        title: "Prueba: \(rule.eventType.rawValue)",
                        content: "Prueba de sonido y reacción del evento."
                    )
                }) {
                    Label("Probar Evento", systemImage: "play.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Toggle("Reproducir sonido", isOn: $playSound)
                        .font(.system(size: 11))
                    
                    if playSound {
                        Picker("Efecto:", selection: $soundName) {
                            ForEach(EventManager.availableSounds, id: \.self) { sound in
                                Text(sound).tag(sound)
                            }
                        }
                        .font(.system(size: 10))
                        .frame(width: 150)
                    }
                }
                
                GridRow {
                    Toggle("Rebote de icono en Dock", isOn: $bounceDock)
                        .font(.system(size: 11))
                    
                    Toggle("Contador Badge en Dock", isOn: $updateBadge)
                        .font(.system(size: 11))
                }
                
                GridRow {
                    Toggle("Notificación de macOS", isOn: $showNotification)
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

