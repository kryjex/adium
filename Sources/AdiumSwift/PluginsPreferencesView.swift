import SwiftUI
import AppKit

/// The Plugins tab of Preferences. It lists the protocol plugins already on
/// disk and the plugins the catalog offers, so the user can enable, disable,
/// or install one without a rebuild.
public struct PluginsPreferencesTab: View {
    @Bindable var pluginManager = PluginManager.shared

    /// Catalog entry ids currently downloading. A row shows a spinner
    /// instead of its button while its id is in this set.
    @State private var installingIDs: Set<String> = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if pluginManager.needsRestart {
                    Text(t("Restart Adium to apply plugin changes."))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if let error = pluginManager.lastCatalogError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                installedSection
                Divider()
                availableSection

                Spacer()
            }
            .padding(16)
        }
        .task {
            await pluginManager.loadCatalog()
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Installed Plugins"))
                .font(.system(size: 12, weight: .bold))

            if pluginManager.installed.isEmpty {
                Text(t("No plugins installed."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(pluginManager.installed) { plugin in
                    installedRow(plugin)
                }
            }
        }
    }

    private func installedRow(_ plugin: PluginManager.InstalledPlugin) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(plugin.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .accessibilityLabel(plugin.isEnabled ? t("Enabled") : t("Disabled"))

            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name)
                    .font(.system(size: 11, weight: .bold))
                Text(plugin.id)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let entry = catalogEntry(for: plugin), pluginManager.installedVersionOutdated(for: entry) {
                installOrUpdateButton(title: t("Update"), entry: entry)
            }

            Toggle(isOn: Binding(
                get: { plugin.isEnabled },
                set: { pluginManager.setEnabled($0, filename: plugin.id) }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(t("Enable \(plugin.name)"))
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(t("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plugin.path)])
            }
        }
    }

    /// This finds the catalog entry behind an installed plugin, if any.
    /// A plugin installed by hand, outside the catalog, has none.
    private func catalogEntry(for plugin: PluginManager.InstalledPlugin) -> PluginCatalogEntry? {
        guard let catalogEntryID = plugin.catalogEntryID else { return nil }
        return pluginManager.catalog.first { $0.id == catalogEntryID }
    }

    // MARK: - Available

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Available Plugins"))
                .font(.system(size: 12, weight: .bold))

            if pluginManager.catalog.isEmpty {
                Text(t("No plugins in the catalog."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if availableEntries.isEmpty {
                Text(t("All catalog plugins are installed."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(availableEntries) { entry in
                    availableRow(entry)
                }
            }
        }
    }

    /// Catalog entries not already on disk, matched by filename against
    /// the installed plugin ids.
    private var availableEntries: [PluginCatalogEntry] {
        let installedFilenames = Set(pluginManager.installed.map { $0.id })
        return pluginManager.catalog.filter { !installedFilenames.contains($0.filename) }
    }

    private func availableRow(_ entry: PluginCatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 11, weight: .bold))
                Text("\(entry.version) · \(entry.license)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(entry.localizedDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Button(t("Source")) {
                    NSWorkspace.shared.open(entry.sourceUrl)
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }

            Spacer()

            installOrUpdateButton(title: t("Install"), entry: entry)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Install / Update

    /// Same control for a fresh install and a version update: both call
    /// PluginManager.install(_:). A row shows a spinner while its download
    /// runs, and disables the button when the catalog has no binary yet.
    @ViewBuilder
    private func installOrUpdateButton(title: String, entry: PluginCatalogEntry) -> some View {
        if installingIDs.contains(entry.id) {
            ProgressView()
                .controlSize(.small)
        } else if entry.binaryUrl == nil {
            Button(title) { }
                .font(.system(size: 10))
                .disabled(true)
                .help(t("This plugin has no downloadable binary yet."))
        } else {
            Button(title) {
                startInstall(entry)
            }
            .font(.system(size: 10))
        }
    }

    private func startInstall(_ entry: PluginCatalogEntry) {
        installingIDs.insert(entry.id)
        Task {
            _ = await pluginManager.install(entry)
            installingIDs.remove(entry.id)
        }
    }
}
