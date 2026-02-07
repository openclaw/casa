import SwiftUI
import UIKit
import HomeKit

struct ApiDocsView: View {
    @EnvironmentObject private var model: CasaAppModel
    @ObservedObject private var settings = CasaSettings.shared
    let accessories: [HMAccessory]
    let scenes: [HMActionSet]
    @Binding var selectedAccessoryId: UUID?
    @Binding var selectedSceneId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if settings.homeKitEnabled {
                    if selectedSceneId != nil {
                        sceneFilter
                    } else {
                        accessoryFilter
                    }
                } else {
                    Text("HomeKit module is disabled. Enable it in Settings to view HomeKit endpoints.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(endpoints) { endpoint in
                    EndpointCard(endpoint: endpoint, onCopy: copyToPasteboard)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 10)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local API")
                .font(.title2)
            Text("Base URL: \(baseURL)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(authNote)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var accessoryFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessory Filter")
                .font(.headline)
            Picker("Accessory", selection: $selectedAccessoryId) {
                Text("All accessories").tag(Optional<UUID>.none)
                ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                    Text(accessory.name).tag(Optional(accessory.uniqueIdentifier))
                }
            }
            .pickerStyle(.menu)

            if let accessory = selectedAccessory {
                Text("Filtering examples for \(accessory.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var sceneFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene Filter")
                .font(.headline)
            Picker("Scene", selection: $selectedSceneId) {
                Text("All scenes").tag(Optional<UUID>.none)
                ForEach(scenes, id: \.uniqueIdentifier) { scene in
                    Text(scene.name).tag(Optional(scene.uniqueIdentifier))
                }
            }
            .pickerStyle(.menu)

            if let scene = selectedScene {
                Text("Filtering examples for \(scene.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var selectedScene: HMActionSet? {
        guard let selectedSceneId else { return nil }
        return scenes.first { $0.uniqueIdentifier == selectedSceneId }
    }

    private var baseURL: String {
        "http://127.0.0.1:\(settings.port)"
    }

    private var authHeader: String {
        guard !settings.authToken.isEmpty else { return "" }
        return " -H 'X-Casa-Token: \(settings.authToken)'"
    }

    private var authNote: String {
        if settings.authToken.isEmpty {
            return "Auth: disabled"
        }
        return "Auth: X-Casa-Token header required"
    }

    private var endpoints: [ApiEndpoint] {
        let boolBody = "{\"value\": true}"
        let accessoryId = selectedAccessory?.uniqueIdentifier.uuidString ?? "<id>"
        let characteristicId = selectedCharacteristicId ?? "<uuid>"
        let sceneId = selectedScene?.uniqueIdentifier.uuidString ?? "<id>"
        var result: [ApiEndpoint] = [
            ApiEndpoint(
                method: "GET",
                path: "/health",
                description: "Server status",
                curl: "curl \(baseURL)/health\(authHeader)",
                response: "{\"status\": \"running\"}"
            )
        ]

        guard settings.homeKitEnabled else { return result }

        if selectedSceneId != nil {
            result.append(contentsOf: [
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/scenes",
                    description: "List all scenes",
                    curl: "curl \(baseURL)/homekit/scenes\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\", \"type\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "POST",
                    path: "/homekit/scenes/:id/execute",
                    description: "Execute a scene",
                    curl: "curl -X POST \(baseURL)/homekit/scenes/\(sceneId)/execute\(authHeader)",
                    response: "{\"name\": \"...\", \"status\": \"executed\"}"
                )
            ])
        } else {
            result.append(contentsOf: [
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/accessories",
                    description: "List all accessories",
                    curl: "curl \(baseURL)/homekit/accessories\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/rooms",
                    description: "List all rooms",
                    curl: "curl \(baseURL)/homekit/rooms\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/services",
                    description: "List all services",
                    curl: "curl \(baseURL)/homekit/services\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/accessories/:id",
                    description: "Fetch one accessory with services",
                    curl: "curl \(baseURL)/homekit/accessories/\(accessoryId)\(authHeader)",
                    response: "{\"id\": \"...\", \"services\": []}"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/characteristics/:id",
                    description: "Read a characteristic",
                    curl: "curl \(baseURL)/homekit/characteristics/\(characteristicId)\(authHeader)",
                    response: "{\"id\": \"...\", \"value\": true}"
                ),
                ApiEndpoint(
                    method: "PUT",
                    path: "/homekit/characteristics/:id",
                    description: "Write a characteristic (writable only; read-only returns 405)",
                    curl: "curl -X PUT \(baseURL)/homekit/characteristics/\(characteristicId)\(authHeader) -H 'Content-Type: application/json' -d '\(boolBody)'",
                    request: boolBody,
                    response: "{\"status\": \"queued\"}"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/schema",
                    description: "Discover writable characteristics and metadata",
                    curl: "curl \(baseURL)/homekit/schema\(authHeader)",
                    response: "[{\"id\": \"...\", \"writable\": true, \"valueType\": \"bool\"}]"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/scenes",
                    description: "List all scenes",
                    curl: "curl \(baseURL)/homekit/scenes\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\", \"type\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "POST",
                    path: "/homekit/scenes/:id/execute",
                    description: "Execute a scene",
                    curl: "curl -X POST \(baseURL)/homekit/scenes/<id>/execute\(authHeader)",
                    response: "{\"name\": \"...\", \"status\": \"executed\"}"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/cameras",
                    description: "List cameras",
                    curl: "curl \(baseURL)/homekit/cameras\(authHeader)",
                    response: "[{\"id\": \"...\", \"name\": \"...\"}]"
                ),
                ApiEndpoint(
                    method: "GET",
                    path: "/homekit/cameras/:id",
                    description: "Fetch one camera",
                    curl: "curl \(baseURL)/homekit/cameras/<id>\(authHeader)",
                    response: "{\"id\": \"...\", \"name\": \"...\"}"
                )
            ])
        }

        return result
    }

    private func copyToPasteboard(_ value: String) {
        Task { @MainActor in
            CasaPasteboard.copy(value)
            model.showToast("Copied to clipboard")
        }
    }

    private var selectedAccessory: HMAccessory? {
        guard let selectedAccessoryId else { return nil }
        return accessories.first { $0.uniqueIdentifier == selectedAccessoryId }
    }

    private var selectedCharacteristicId: String? {
        guard let accessory = selectedAccessory else { return nil }
        for service in accessory.services {
            if let characteristic = service.characteristics.first {
                return characteristic.uniqueIdentifier.uuidString
            }
        }
        return nil
    }

}

private struct ApiEndpoint: Identifiable {
    let id = UUID()
    let method: String
    let path: String
    let description: String
    let curl: String
    let request: String?
    let response: String?

    init(method: String, path: String, description: String, curl: String, request: String? = nil, response: String? = nil) {
        self.method = method
        self.path = path
        self.description = description
        self.curl = curl
        self.request = request
        self.response = response
    }
}

private struct EndpointCard: View {
    let endpoint: ApiEndpoint
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(endpoint.method)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                Text(endpoint.path)
                    .font(.headline)
                Spacer()
                Button("Copy curl") {
                    onCopy(endpoint.curl)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            Text(endpoint.description)
                .font(.caption)
                .foregroundColor(.secondary)

            CodeBlock(title: "curl", text: endpoint.curl, onCopy: onCopy)

            if let request = endpoint.request {
                CodeBlock(title: "request", text: request, onCopy: onCopy)
            }

            if let response = endpoint.response {
                CodeBlock(title: "response", text: response, onCopy: onCopy)
            }
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct CodeBlock: View {
    let title: String
    let text: String
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Copy") {
                    onCopy(text)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(8)
        }
    }
}
