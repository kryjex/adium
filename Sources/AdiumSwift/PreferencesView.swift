import SwiftUI

public struct PreferencesView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("playSoundEffects") private var playSoundEffects: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    
    @State private var showAddAccountSheet = false
    @State private var selectedAccountID: UUID?
    
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
                                    Text(acc.accountProtocol.rawValue)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Circle()
                                    .fill(acc.isConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                    .help(acc.isConnected ? "Conectado" : "Desconectado")
                            }
                            .tag(acc.id)
                            .contextMenu {
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
                        
                        // Classic macOS + / - toolbar bar
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
        }
        .frame(width: 480, height: 300)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
    }
}

struct AddAccountSheet: View {
    @Binding var isPresented: Bool
    @Bindable var bridge = PurpleBridgeService.shared
    
    @State private var selectedProtocol: AccountProtocol = .teams
    @State private var username: String = ""
    @State private var password: String = ""
    
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
    
    var body: some View {
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
                }
            }
            .formStyle(.grouped)
            
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
                    bridge.connectAccount(username: trimmedUser, protocolType: selectedProtocol, password: pass)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)
            }
        }
        .padding(16)
        .frame(width: 380, height: (selectedProtocol == .teams || selectedProtocol == .whatsapp) ? 260 : 240)
    }
}
