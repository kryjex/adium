import SwiftUI
import AppKit

public struct FileTransferView: View {
    @Bindable var manager = FileTransferManager.shared

    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                
                Text("Transferencias de Archivos")
                    .font(.system(size: 14, weight: .bold))
                
                Spacer()
                
                if !manager.transfers.isEmpty {
                    Text("\(manager.transfers.count) elementos")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Material.bar)

            // Error Banner
            if let error = manager.lastErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))

                    Text(error)
                        .font(.system(size: 9.5))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    Spacer()

                    Button(action: { manager.clearError() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Descartar")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.18))
            }

            Divider()

            // Body: Empty State vs Transfers List
            if manager.transfers.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.6))
                    
                    Text("Sin transferencias de archivos")
                        .font(.system(size: 13, weight: .bold))
                    
                    Text("Los archivos enviados o recibidos aparecerán aquí con su barra de progreso y velocidad estimada.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.transfers) { item in
                        FileTransferRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
            
            Divider()
            
            // Footer Controls
            HStack {
                Button("Limpiar Completadas") {
                    manager.transfers.removeAll(where: { $0.state == .completed || $0.state == .cancelled || $0.state == .failed })
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .disabled(manager.transfers.allSatisfy({ $0.state == .transferring || $0.state == .pending }))
                
                Spacer()
                
                Button("Cerrar") {
                    FileTransferWindowController.shared.close()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 10))
            }
            .padding(10)
            .background(Material.bar)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320, idealHeight: 400)
    }
}

struct FileTransferRow: View {
    let item: FileTransferItem
    @Bindable var manager = FileTransferManager.shared
    
    var stateColor: Color {
        switch item.state {
        case .pending: return .orange
        case .transferring: return .accentColor
        case .paused: return .yellow
        case .completed: return .green
        case .cancelled: return .gray
        case .failed: return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.direction == .incoming ? "square.and.arrow.down.fill" : "square.and.arrow.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(item.direction == .incoming ? .blue : .purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    
                    Text("\(item.direction.rawValue) • Contacto: \(item.contactName)")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // State Badge
                Text(item.state.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(stateColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(stateColor.opacity(0.15)))
            }
            
            // Progress Bar
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
            
            // Metrics & Action Buttons
            HStack {
                Text(item.formattedBytes)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if item.state == .transferring {
                    Text(item.formattedSpeed)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                
                // Buttons
                HStack(spacing: 6) {
                    if item.state == .pending && item.direction == .incoming {
                        Button("Aceptar") {
                            promptSaveAndAccept(item)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 9, weight: .bold))
                    }
                    
                    if item.state == .pending || item.state == .transferring || item.state == .paused {
                        Button("Cancelar") {
                            manager.cancelTransfer(item)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.red)
                        .font(.system(size: 9))
                    }
                    
                    if item.state == .completed, let path = item.localPath {
                        Button("Mostrar en Finder") {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func promptSaveAndAccept(_ item: FileTransferItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        if panel.runModal() == .OK, let url = panel.url {
            manager.acceptTransfer(item, saveToPath: url.path)
        }
    }
}
