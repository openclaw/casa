import SwiftUI
import HomeKit

struct ContentView: View {
    @EnvironmentObject private var model: CasaAppModel
    @State private var mainSelection: MainSelection = .apiDocs
    @State private var accessorySelection: UUID? = nil
    @State private var sceneSelection: UUID? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.settings.onboardingComplete {
                tabView
            } else {
                OnboardingView()
                    .environmentObject(model)
            }

            if let toast = model.toastMessage {
                ToastView(message: toast)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toastMessage)
    }

    private var accessoryBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { accessorySelection },
            set: { newValue in
                accessorySelection = newValue
                if newValue != nil {
                    sceneSelection = nil
                    mainSelection = .apiDocs
                }
            }
        )
    }

    private var sceneBinding: Binding<UUID?> {
        Binding<UUID?>(
            get: { sceneSelection },
            set: { newValue in
                sceneSelection = newValue
                if newValue != nil {
                    accessorySelection = nil
                    mainSelection = .apiDocs
                }
            }
        )
    }

    private var tabView: some View {
        TabView(selection: $mainSelection) {
            apiDocsView
                .tabItem {
                    Label("HomeKit API", systemImage: "doc.text.magnifyingglass")
                }
                .tag(MainSelection.apiDocs)

            LogsView()
                .tabItem {
                    Label("Diagnostics & Logs", systemImage: "waveform.path.ecg")
                }
                .tag(MainSelection.logs)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(MainSelection.settings)
        }
    }

    private var apiDocsView: some View {
        HStack(spacing: 0) {
            if model.settings.homeKitEnabled {
                SidebarView(
                    accessories: model.homeKit.accessories,
                    scenes: model.homeKit.scenes,
                    accessorySelection: accessoryBinding,
                    sceneSelection: sceneBinding
                )
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                .background(Color(UIColor.systemGroupedBackground))

                Divider()
            }

            ApiDocsView(
                accessories: model.homeKit.accessories,
                scenes: model.homeKit.scenes,
                selectedAccessoryId: accessoryBinding,
                selectedSceneId: sceneBinding
            )
        }
    }

}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            .accessibilityLabel(message)
    }
}

private enum MainSelection: Hashable {
    case apiDocs
    case logs
    case settings
}


private struct SidebarView: View {
    @EnvironmentObject private var model: CasaAppModel
    @ObservedObject private var settings = CasaSettings.shared
    let accessories: [HMAccessory]
    let scenes: [HMActionSet]
    @Binding var accessorySelection: UUID?
    @Binding var sceneSelection: UUID?

    var body: some View {
        List {
            Section("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBadge(status: serverStatus)
                Text("Port \(settings.port, format: .number.grouping(.never))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(settings.authToken.isEmpty ? "Auth: off" : "Auth: on")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text("HomeKit")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        StatusBadge(status: moduleStatusHomeKit())
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Accessories") {
                Button {
                    accessorySelection = nil
                    sceneSelection = nil
                } label: {
                    sidebarRow(title: "All accessories", isSelected: accessorySelection == nil && sceneSelection == nil)
                }
                .buttonStyle(.plain)

                ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                    Button {
                        accessorySelection = accessory.uniqueIdentifier
                        sceneSelection = nil
                    } label: {
                        sidebarRow(title: accessory.name, isSelected: accessorySelection == accessory.uniqueIdentifier)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Scenes") {
                Button {
                    sceneSelection = SceneSelection.allScenesId
                    accessorySelection = nil
                } label: {
                    sidebarRow(title: "All scenes", isSelected: sceneSelection == SceneSelection.allScenesId)
                }
                .buttonStyle(.plain)

                ForEach(scenes, id: \.uniqueIdentifier) { scene in
                    Button {
                        sceneSelection = scene.uniqueIdentifier
                        accessorySelection = nil
                    } label: {
                        sidebarRow(title: scene.name, isSelected: sceneSelection == scene.uniqueIdentifier)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sidebarRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private var serverStatus: ModuleStatus {
        if model.server.isRunning {
            return ModuleStatus(text: "Running", tone: .ok)
        }
        return ModuleStatus(text: "Stopped", tone: .muted)
    }

    private func moduleStatusHomeKit() -> ModuleStatus {
        if settings.homeKitEnabled {
            return ModuleStatus(text: "Enabled", tone: .ok)
        }
        return ModuleStatus(text: "Disabled", tone: .muted)
    }
}
