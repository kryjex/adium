import SwiftUI

public struct ContactListView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    @State private var searchText = ""
    @State private var showAddAccountSheet = false
    @Binding var selectedContactID: UUID?
    
    public init(selectedContactID: Binding<UUID?> = .constant(nil)) {
        self._selectedContactID = selectedContactID
    }
    
    public init(selectedContact: Binding<Contact?>) {
        self._selectedContactID = Binding(
            get: { selectedContact.wrappedValue?.id },
            set: { newID in
                if let newID = newID {
                    selectedContact.wrappedValue = PurpleBridgeService.shared.contacts.first(where: { $0.id == newID })
                } else {
                    selectedContact.wrappedValue = nil
                }
            }
        )
    }
    
    var groupedContacts: [String: [Contact]] {
        let filtered = bridge.contacts.filter { contact in
            let matchesSearch = searchText.isEmpty || contact.name.localizedCaseInsensitiveContains(searchText) || contact.handle.localizedCaseInsensitiveContains(searchText)
            let matchesStatus = showOfflineContacts || contact.status != .offline
            return matchesSearch && matchesStatus
        }
        return Dictionary(grouping: filtered, by: { $0.group })
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header: My Status Bar (Classic Adium Header)
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(bridge.myStatus))
                    .frame(width: 10, height: 10)
                
                Menu {
                    ForEach(OnlineStatus.allCases, id: \.self) { status in
                        Button(action: { bridge.setUserStatus(status) }) {
                            Label(status.rawValue, systemImage: status.iconName)
                        }
                    }
                } label: {
                    Text(bridge.myStatus.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .menuStyle(.borderlessButton)
                
                Spacer()
                
                Button(action: { showAddAccountSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Añadir nueva cuenta")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Material.bar)
            
            Divider()
            
            // Connection Error Banner
            if bridge.hasAccountError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    
                    Text(bridge.accountErrorSummary ?? "Error de conexión")
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button("Reconectar") {
                        bridge.reconnectAccounts()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 9, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.15))
                
                Divider()
            }
            
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                TextField("Buscar contacto...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Body: Empty state vs Contact list
            if bridge.accounts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                    
                    Text("Sin Cuentas Configuradas")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("Añade tu cuenta de Microsoft Teams, WhatsApp o XMPP para cargar tus contactos y comenzar a chatear.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    Button(action: { showAddAccountSheet = true }) {
                        Label("Añadir Cuenta", systemImage: "plus.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bridge.contacts.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    
                    Text(bridge.hasAccountError ? "Error al conectar cuenta" : "Conectando cuenta...")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("Conectado a \(bridge.accounts.first?.username ?? ""). Esperando eventos de libpurple...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    HStack(spacing: 8) {
                        Button("Reconectar") {
                            bridge.reconnectAccounts()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        
                        Button("Gestionar Cuentas") {
                            showAddAccountSheet = true
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedContactID) {
                    ForEach(groupedContacts.keys.sorted(), id: \.self) { group in
                        Section(header: Text(group).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)) {
                            ForEach(groupedContacts[group] ?? []) { contact in
                                CompactContactRow(contact: contact)
                                    .tag(contact.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            
            Divider()
            
            // Status Footer (Bridge state)
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.hasAccountError ? Color.red : (bridge.isLibpurpleLoaded ? Color.green : Color.orange))
                    .frame(width: 6, height: 6)
                Text(bridge.connectionState)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if bridge.accounts.contains(where: { !$0.isConnected }) {
                    Button(action: { bridge.reconnectAccounts() }) {
                        Label("Reconectar", systemImage: "arrow.clockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("Reconectar cuentas desconectadas")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Material.bar)
        }
        .frame(minWidth: 200, idealWidth: 230, maxWidth: 300, minHeight: 350, idealHeight: 500)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
    }
    
    private func statusColor(_ status: OnlineStatus) -> Color {
        switch status {
        case .available: return .green
        case .away: return .yellow
        case .busy: return .red
        case .offline: return .gray
        }
    }
}

struct CompactContactRow: View {
    let contact: Contact
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(contact.status))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(contact.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: contact.accountProtocol.iconName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                if let msg = contact.customStatusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private func statusColor(_ status: OnlineStatus) -> Color {
        switch status {
        case .available: return .green
        case .away: return .yellow
        case .busy: return .red
        case .offline: return .gray
        }
    }
}
