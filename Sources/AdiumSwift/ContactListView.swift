import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContactListView: View {
    @Bindable var bridge = PurpleBridgeService.shared
    @AppStorage("showOfflineContacts") private var showOfflineContacts: Bool = true
    @AppStorage("contactSortOrder") private var sortOrderRaw: String = ContactSortOrder.name.rawValue
    
    @State private var searchText = ""
    @State private var showAddAccountSheet = false
    @State private var showCreateGroupSheet = false
    @State private var groupToRename: String? = nil
    @State private var contactToRename: Contact? = nil
    @State private var contactToCombine: Contact? = nil
    @State private var isEditingStatusMessage = false
    @State private var statusMessageDraft = ""
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isStatusMessageFocused: Bool
    
    @Binding var selectedContactID: UUID?
    
    var sortOrder: ContactSortOrder {
        ContactSortOrder(rawValue: sortOrderRaw) ?? .name
    }
    
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
    
    // Structure representing items to render per group
    struct GroupSectionData {
        let group: ContactGroup
        let items: [DisplayItem]
        let onlineCount: Int
        let totalCount: Int
    }
    
    enum DisplayItem: Identifiable {
        case contact(Contact)
        case metacontact(Metacontact, [Contact])
        
        var id: UUID {
            switch self {
            case .contact(let c): return c.id
            case .metacontact(let m, _): return m.id
            }
        }
    }
    
    private func contactMatchesFilter(_ contact: Contact) -> Bool {
        let matchesSearch = searchText.isEmpty ||
            contact.displayName.localizedCaseInsensitiveContains(searchText) ||
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            contact.handle.localizedCaseInsensitiveContains(searchText) ||
            (contact.alias?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (contact.customStatusMessage?.localizedCaseInsensitiveContains(searchText) ?? false)

        let matchesStatus = showOfflineContacts || contact.status != .offline
        return matchesSearch && matchesStatus
    }

    var groupSections: [GroupSectionData] {
        var allGroupNames = bridge.contactGroups.map { $0.name }
        for c in bridge.contacts {
            if !allGroupNames.contains(c.group) {
                allGroupNames.append(c.group)
            }
        }

        // Metacontact membership spans groups: a contact keeps its own `group`,
        // but if it belongs to a metacontact it should only ever render as part
        // of that metacontact's row (anchored to the primary contact's group),
        // never standalone in any group section.
        var membersByMetacontactID: [UUID: [Contact]] = [:]
        for c in bridge.contacts {
            if let metaID = c.metacontactID {
                membersByMetacontactID[metaID, default: []].append(c)
            }
        }
        let allMetaMemberIDs = Set(membersByMetacontactID.values.flatMap { $0.map(\.id) })

        let isFilterActive = !searchText.isEmpty || !showOfflineContacts

        return allGroupNames.compactMap { groupName -> GroupSectionData? in
            let groupObj = bridge.contactGroups.first(where: { $0.name == groupName }) ?? ContactGroup(name: groupName)

            let groupContacts = bridge.contacts.filter { $0.group == groupName }
            let filteredContacts = groupContacts.filter(contactMatchesFilter)

            let onlineCount = groupContacts.filter({ $0.status != .offline }).count
            let totalCount = groupContacts.count

            var items: [DisplayItem] = []

            let groupMetacontacts = bridge.metacontacts.filter { meta in
                guard let members = membersByMetacontactID[meta.id], !members.isEmpty else { return false }
                let primary = primaryContact(for: meta, in: members)
                return primary?.group == groupName
            }
            for meta in groupMetacontacts {
                let members = membersByMetacontactID[meta.id] ?? []
                let subContacts = members.filter(contactMatchesFilter)
                if !subContacts.isEmpty {
                    items.append(.metacontact(meta, subContacts))
                }
            }

            let standalone = filteredContacts.filter { !allMetaMemberIDs.contains($0.id) }
            for c in standalone {
                items.append(.contact(c))
            }

            // Hide the section when it has nothing to show after filtering, unless
            // it's a genuinely empty group and no search/status filter is active
            // (so users can still see newly created empty groups).
            if items.isEmpty && (isFilterActive || !groupContacts.isEmpty) {
                return nil
            }

            let sortedItems = items.sorted { item1, item2 in
                switch (item1, item2) {
                case (.contact(let c1), .contact(let c2)):
                    return compareContacts(c1, c2, order: sortOrder)
                case (.contact(let c1), .metacontact(let m2, let sc2)):
                    let c2 = sc2.first ?? Contact(name: m2.name, handle: "", status: .offline)
                    return compareContacts(c1, c2, order: sortOrder)
                case (.metacontact(let m1, let sc1), .contact(let c2)):
                    let c1 = sc1.first ?? Contact(name: m1.name, handle: "", status: .offline)
                    return compareContacts(c1, c2, order: sortOrder)
                case (.metacontact(let m1, let sc1), .metacontact(let m2, let sc2)):
                    let c1 = sc1.first ?? Contact(name: m1.name, handle: "", status: .offline)
                    let c2 = sc2.first ?? Contact(name: m2.name, handle: "", status: .offline)
                    return compareContacts(c1, c2, order: sortOrder)
                }
            }
            
            return GroupSectionData(group: groupObj, items: sortedItems, onlineCount: onlineCount, totalCount: totalCount)
        }
    }
    
    private func primaryContact(for meta: Metacontact, in members: [Contact]) -> Contact? {
        if let pID = meta.primaryContactID, let found = members.first(where: { $0.id == pID }) {
            return found
        }
        return members.first
    }

    private func compareContacts(_ c1: Contact, _ c2: Contact, order: ContactSortOrder) -> Bool {
        switch order {
        case .name:
            return c1.displayName.localizedCaseInsensitiveCompare(c2.displayName) == .orderedAscending
        case .status:
            if c1.status.sortPriority != c2.status.sortPriority {
                return c1.status.sortPriority < c2.status.sortPriority
            }
            return c1.displayName.localizedCaseInsensitiveCompare(c2.displayName) == .orderedAscending
        }
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
                
                // Filter & Sort Menu
                Menu {
                    Toggle("Mostrar Desconectados", isOn: $showOfflineContacts)
                    Divider()
                    Picker("Ordenamiento", selection: $sortOrderRaw) {
                        ForEach(ContactSortOrder.allCases, id: \.rawValue) { sort in
                            Text(sort.rawValue).tag(sort.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .help("Filtrado y Ordenamiento")
                
                // Add Group Button
                Button(action: { showCreateGroupSheet = true }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Crear nuevo grupo")
                
                // Transcript Viewer Button
                Button(action: { TranscriptViewerWindowController.shared.show() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Abrir visor de transcripciones e historial (⌘⌥T / ⌘⇧T)")
                
                // File Transfers Button
                Button(action: { FileTransferWindowController.shared.show() }) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Transferencias de archivos (⌘⌥L)")
                
                // Add Account Button
                Button(action: { showAddAccountSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Añadir nueva cuenta (⌘⇧A)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Material.bar)

            // Custom Status Message Row
            HStack(spacing: 4) {
                if isEditingStatusMessage {
                    TextField("Mensaje de estado…", text: $statusMessageDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .focused($isStatusMessageFocused)
                        .onSubmit { commitStatusMessage() }
                        .onAppear { isStatusMessageFocused = true }

                    Button(action: commitStatusMessage) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Guardar mensaje de estado")
                } else {
                    Button(action: {
                        statusMessageDraft = bridge.myStatusMessage
                        isEditingStatusMessage = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 8))
                            Text(bridge.myStatusMessage.isEmpty ? "Añadir mensaje de estado…" : bridge.myStatusMessage)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Establecer un mensaje de estado personalizado")

                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
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
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onReceive(NotificationCenter.default.publisher(for: .focusContactSearch)) { _ in
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openNewConversation)) { _ in
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAddAccount)) { _ in
                showAddAccountSheet = true
            }
            
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
                    ForEach(groupSections, id: \.group.name) { section in
                        Section(header: GroupHeaderView(
                            group: section.group,
                            onlineCount: section.onlineCount,
                            totalCount: section.totalCount,
                            onRename: { groupToRename = section.group.name },
                            onDelete: { bridge.deleteGroup(name: section.group.name) }
                        )) {
                            if section.group.isExpanded {
                                ForEach(section.items) { item in
                                    switch item {
                                    case .contact(let contact):
                                        ContactRowView(
                                            contact: contact,
                                            onRename: { contactToRename = contact },
                                            onCombine: { contactToCombine = contact },
                                            onSelectAvatar: { selectAvatarForContact(contact) }
                                        )
                                        .tag(contact.id)
                                    case .metacontact(let meta, let subContacts):
                                        MetacontactRowView(
                                            metacontact: meta,
                                            subContacts: subContacts,
                                            selectedContactID: $selectedContactID
                                        )
                                        .tag(primaryContact(for: meta, in: subContacts)?.id ?? meta.id)
                                    }
                                }
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
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 320, minHeight: 380, idealHeight: 550)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(isPresented: $showAddAccountSheet)
        }
        .sheet(isPresented: $showCreateGroupSheet) {
            CreateGroupSheet(isPresented: $showCreateGroupSheet)
        }
        .sheet(item: Binding(get: { groupToRename.map { GroupRenameWrapper(name: $0) } }, set: { groupToRename = $0?.name })) { wrapper in
            RenameGroupSheet(groupName: wrapper.name, isPresented: Binding(get: { groupToRename != nil }, set: { if !$0 { groupToRename = nil } }))
        }
        .sheet(item: $contactToRename) { contact in
            SetAliasSheet(contact: contact, isPresented: Binding(get: { contactToRename != nil }, set: { if !$0 { contactToRename = nil } }))
        }
        .sheet(item: $contactToCombine) { contact in
            CombineContactsSheet(sourceContact: contact, isPresented: Binding(get: { contactToCombine != nil }, set: { if !$0 { contactToCombine = nil } }))
        }
    }
    
    private func selectAvatarForContact(_ contact: Contact) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            bridge.setAvatar(data: data, for: contact.id)
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

    private func commitStatusMessage() {
        bridge.setStatusMessage(statusMessageDraft)
        isEditingStatusMessage = false
    }
}

// Wrapper struct for sheet item binding
struct GroupRenameWrapper: Identifiable {
    var id: String { name }
    let name: String
}

// MARK: - Subviews & Rows

struct GroupHeaderView: View {
    let group: ContactGroup
    let onlineCount: Int
    let totalCount: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        HStack(spacing: 6) {
            Button(action: { bridge.toggleGroupExpanded(name: group.name) }) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Text(group.name)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.primary)
            
            Spacer()
            
            Text("\(onlineCount)/\(totalCount)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Renombrar Grupo...") {
                onRename()
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Eliminar Grupo", systemImage: "trash")
            }
        }
    }
}

struct ContactAvatarView: View {
    let name: String
    let avatarData: Data?
    let status: OnlineStatus
    let isBlocked: Bool
    var size: CGFloat = 26

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        } else if let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    var avatarGradient: LinearGradient {
        let hash = abs(name.hashValue)
        let colors: [[Color]] = [
            [.blue, .purple],
            [.teal, .blue],
            [.indigo, .cyan],
            [.orange, .red],
            [.pink, .purple],
            [.mint, .teal]
        ]
        let pair = colors[hash % colors.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let data = avatarData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundColor(.white)
                    )
            }

            if isBlocked {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundColor(.red)
                    .background(Circle().fill(Color.white))
            } else {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
            }
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

struct ContactRowView: View {
    let contact: Contact
    let onRename: () -> Void
    let onCombine: () -> Void
    let onSelectAvatar: () -> Void
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        HStack(spacing: 8) {
            ContactAvatarView(
                name: contact.displayName,
                avatarData: contact.avatarData,
                status: contact.status,
                isBlocked: contact.isBlocked,
                size: 26
            )
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(contact.isBlocked ? .secondary : .primary)
                        .strikethrough(contact.isBlocked, color: .secondary)
                        .lineLimit(1)
                    
                    if contact.alias != nil {
                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    
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
                } else {
                    Text(contact.handle)
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Renombrar / Establecer Alias...") {
                onRename()
            }
            if contact.alias != nil {
                Button("Quitar Alias") {
                    bridge.setAlias(nil, for: contact.id)
                }
            }
            
            Button("Cambiar Icono / Avatar...") {
                onSelectAvatar()
            }
            
            Divider()
            
            Button("Combinar en Metacontacto...") {
                onCombine()
            }
            
            Menu("Mover a Grupo") {
                ForEach(bridge.contactGroups, id: \.id) { group in
                    Button(group.name) {
                        bridge.moveContact(contact.id, toGroup: group.name)
                    }
                }
            }
            
            Divider()
            
            Button(contact.isBlocked ? "Desbloquear Contacto" : "Bloquear Contacto") {
                bridge.toggleBlockContact(contact.id)
            }
        }
    }
}

struct MetacontactRowView: View {
    let metacontact: Metacontact
    let subContacts: [Contact]
    @Binding var selectedContactID: UUID?
    @State private var isExpanded: Bool = false
    @Bindable var bridge = PurpleBridgeService.shared
    
    var primaryContact: Contact? {
        if let pID = metacontact.primaryContactID, let found = subContacts.first(where: { $0.id == pID }) {
            return found
        }
        return subContacts.first
    }
    
    var highestStatus: OnlineStatus {
        if subContacts.contains(where: { $0.status == .available }) { return .available }
        if subContacts.contains(where: { $0.status == .away }) { return .away }
        if subContacts.contains(where: { $0.status == .busy }) { return .busy }
        return .offline
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                ContactAvatarView(
                    name: metacontact.name,
                    avatarData: metacontact.avatarData ?? primaryContact?.avatarData,
                    status: highestStatus,
                    isBlocked: false,
                    size: 26
                )
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(metacontact.name)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        
                        Label("Metacontacto", systemImage: "person.2.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                        
                        Spacer()
                        
                        // Show all bundled protocol icons
                        HStack(spacing: 2) {
                            ForEach(subContacts, id: \.id) { sc in
                                Image(systemName: sc.accountProtocol.iconName)
                                    .font(.system(size: 8))
                                    .foregroundColor(sc.id == primaryContact?.id ? .accentColor : .secondary)
                            }
                        }
                    }
                    
                    Text("\(subContacts.count) cuentas combinadas (\(primaryContact?.accountProtocol.rawValue ?? ""))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .contextMenu {
                Menu("Establecer Cuenta Principal") {
                    ForEach(subContacts, id: \.id) { sc in
                        Button("\(sc.displayName) (\(sc.accountProtocol.rawValue))") {
                            bridge.setPrimaryContact(contactID: sc.id, inMetacontact: metacontact.id)
                        }
                    }
                }
                
                Button(role: .destructive) {
                    bridge.unlinkMetacontact(metacontact.id)
                } label: {
                    Label("Desvincular Metacontacto", systemImage: "link.badge.plus")
                }
            }
            
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(subContacts, id: \.id) { sc in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(sc.id == primaryContact?.id ? Color.accentColor : Color.clear)
                                .frame(width: 4, height: 4)
                            
                            Image(systemName: sc.accountProtocol.iconName)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                            
                            Text(sc.displayName)
                                .font(.system(size: 10, weight: sc.id == primaryContact?.id ? .semibold : .regular))
                            
                            Spacer()
                            
                            Text(sc.status.rawValue)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 28)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedContactID = sc.id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Context Sheets

struct CreateGroupSheet: View {
    @Binding var isPresented: Bool
    @State private var groupName = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Crear Nuevo Grupo")
                .font(.system(size: 13, weight: .bold))
            
            TextField("Nombre del grupo:", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            
            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Crear") {
                    bridge.createGroup(name: groupName)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct RenameGroupSheet: View {
    let groupName: String
    @Binding var isPresented: Bool
    @State private var newName = ""
    @Bindable var bridge = PurpleBridgeService.shared

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Consistent with createGroup's own duplicate check (case-insensitive),
    // excluding the group being renamed itself.
    private var isDuplicateName: Bool {
        let trimmed = trimmedNewName
        guard !trimmed.isEmpty else { return false }
        return bridge.contactGroups.contains { group in
            group.name != groupName && group.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Renombrar Grupo '\(groupName)'")
                .font(.system(size: 13, weight: .bold))

            TextField("Nuevo nombre:", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onAppear { newName = groupName }

            if isDuplicateName {
                Text("Ya existe un grupo con ese nombre.")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar") {
                    if trimmedNewName != groupName {
                        bridge.renameGroup(oldName: groupName, newName: trimmedNewName)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedNewName.isEmpty || isDuplicateName)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct SetAliasSheet: View {
    let contact: Contact
    @Binding var isPresented: Bool
    @State private var aliasText = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Renombrar Contacto (Alias Local)")
                .font(.system(size: 13, weight: .bold))
            
            Text("Establece un alias para '\(contact.name)' visible solo en tu lista.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            TextField("Alias:", text: $aliasText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onAppear { aliasText = contact.alias ?? contact.name }
            
            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar") {
                    bridge.setAlias(aliasText, for: contact.id)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct CombineContactsSheet: View {
    let sourceContact: Contact
    @Binding var isPresented: Bool
    @State private var selectedTargetID: UUID?
    @State private var metacontactName = ""
    @Bindable var bridge = PurpleBridgeService.shared
    
    var availableTargets: [Contact] {
        bridge.contacts.filter { $0.id != sourceContact.id }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Combinar en Metacontacto")
                .font(.system(size: 13, weight: .bold))
            
            Text("Selecciona otro contacto para unificar sus cuentas bajo una sola entrada de metacontacto.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Form {
                TextField("Nombre del Metacontacto:", text: $metacontactName)
                    .font(.system(size: 11))
                    .onAppear { metacontactName = sourceContact.displayName }
                
                Picker("Combinar con:", selection: $selectedTargetID) {
                    Text("Selecciona un contacto...").tag(UUID?.none)
                    ForEach(availableTargets, id: \.id) { target in
                        Text("\(target.displayName) (\(target.accountProtocol.rawValue))").tag(UUID?.some(target.id))
                    }
                }
                .font(.system(size: 11))
            }
            .formStyle(.grouped)
            
            HStack {
                Button("Cancelar") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Combinar") {
                    if let targetID = selectedTargetID {
                        bridge.combineContacts([sourceContact.id, targetID], name: metacontactName)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTargetID == nil)
            }
        }
        .padding(16)
        .frame(width: 360, height: 260)
    }
}
