import Foundation
import HomeKit
import Network
import UIKit

final class HomeKitServer: ObservableObject {
    private let homeKit: HomeKitManager
    private let settings: CasaSettings
    private let logger: CasaLogger
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "casa.server.queue")
    private var handlers: [UUID: HTTPConnectionHandler] = [:]

    var port: UInt16 { settings.port }
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    init(homeKit: HomeKitManager, settings: CasaSettings, logger: CasaLogger) {
        self.homeKit = homeKit
        self.settings = settings
        self.logger = logger
    }

    func start() {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: self.port) ?? 9123

        do {
            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: queue)
            DispatchQueue.main.async {
                self.isRunning = true
                self.lastError = nil
            }
            logger.log(level: "info", message: "server_started", metadata: [
                "port": String(self.port)
            ])
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Failed to start server: \(error.localizedDescription)"
            }
            logger.log(level: "error", message: "server_failed", metadata: [
                "error": String(describing: error)
            ])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.lastError = nil
        }
        logger.log(level: "info", message: "server_stopped")
    }

    private func handle(connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            logger.log(level: "warn", message: "connection_rejected", metadata: [
                "endpoint": "\(connection.endpoint)"
            ])
            connection.cancel()
            return
        }

        let handlerId = UUID()
        let handler = HTTPConnectionHandler(
            connection: connection,
            queue: queue,
            logger: logger,
            route: { [weak self] request in
                guard let self = self else {
                    return HTTPResponse.serverError(message: "Server unavailable")
                }
                return await self.route(request)
            },
            onClose: { [weak self] in
                self?.queue.async {
                    self?.handlers[handlerId] = nil
                }
            }
        )
        queue.async {
            self.handlers[handlerId] = handler
        }
        handler.start()
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            let v4 = IPv4Address("127.0.0.1")
            let v6 = IPv6Address("::1")
            return host == .ipv4(v4!) || host == .ipv6(v6!)
        default:
            return false
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let started = Date()
        let requestId = UUID().uuidString

        func ok(_ payload: JSONValue) -> HTTPResponse {
            HTTPResponse.ok(payload, requestId: requestId, started: started)
        }

        func error(_ status: Int, _ code: String, _ message: String, details: JSONValue? = nil) -> HTTPResponse {
            HTTPResponse.error(status: status, code: code, message: message, details: details, requestId: requestId, started: started)
        }

        guard isAuthorized(request) else {
            logger.log(level: "warn", message: "request_unauthorized", metadata: [
                "method": request.method,
                "path": request.path
            ])
            return error(401, "unauthorized", "Missing or invalid auth token")
        }

        let homeKitEnabled = await MainActor.run { self.settings.homeKitEnabled }

        let response: HTTPResponse

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let status = await MainActor.run { self.isRunning }
            response = ok(.object([
                "status": .string(status ? "running" : "stopped")
            ]))

        case ("GET", "/homekit/homes"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            let homes = await MainActor.run { self.homeKit.homes }
            response = ok(HomeKitPayload.homes(HomeKitMapper.homes(from: homes)))

        case ("GET", "/homekit/rooms"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            let homes = await MainActor.run { self.homeKit.homes }
            response = ok(HomeKitPayload.rooms(HomeKitMapper.rooms(from: homes)))

        case ("GET", "/homekit/services"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            let accessories = await MainActor.run { self.homeKit.accessories }
            response = ok(HomeKitPayload.services(HomeKitMapper.services(from: accessories)))

        case ("GET", "/homekit/accessories"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            let accessories = await MainActor.run { self.homeKit.accessories }
            response = ok(HomeKitPayload.accessories(HomeKitMapper.accessories(from: accessories)))

        case ("GET", "/homekit/scenes"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            let scenes = await MainActor.run { self.homeKit.scenes }
            let homes = await MainActor.run { self.homeKit.homes }
            response = ok(HomeKitPayload.scenes(HomeKitMapper.scenes(from: scenes, homes: homes)))

        case ("GET", _):
            if let accessoryId = request.pathParameter(prefix: "/homekit/accessories/") {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                let accessory = await MainActor.run { self.homeKit.accessory(with: accessoryId) }
                guard let accessory else {
                    response = error(404, "not_found", "Accessory not found")
                    break
                }
                response = ok(HomeKitPayload.accessoryPayload(HomeKitMapper.accessory(from: accessory)))
                break
            }
            if let characteristicId = request.pathParameter(prefix: "/homekit/characteristics/") {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                let characteristic = await MainActor.run { self.homeKit.characteristic(with: characteristicId) }
                guard let characteristic else {
                    response = error(404, "not_found", "Characteristic not found")
                    break
                }
                let value = await readValue(characteristic)
                response = ok(HomeKitPayload.characteristicPayload(HomeKitMapper.characteristic(from: characteristic, valueOverride: value)))
                break
            }
            if request.path.hasPrefix("/homekit/cameras/") {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                let remainder = String(request.path.dropFirst("/homekit/cameras/".count))
                let cameraId = remainder
                let camera = await MainActor.run { self.homeKit.camera(with: cameraId) }
                guard let camera else {
                    response = error(404, "not_found", "Camera not found")
                    break
                }
                response = ok(HomeKitPayload.cameraPayload(HomeKitMapper.camera(from: camera)))
                break
            }
            if request.path == "/homekit/cameras" {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                let cameras = await MainActor.run { self.homeKit.cameras }
                response = ok(HomeKitPayload.cameras(HomeKitMapper.cameras(from: cameras)))
                break
            }
            if request.path == "/homekit/schema" {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                let accessories = await MainActor.run { self.homeKit.accessories }
                response = ok(HomeKitPayload.schema(HomeKitMapper.accessories(from: accessories)))
                break
            }
            response = error(404, "not_found", "Route not found")

        case ("PUT", _):
            if let characteristicId = request.pathParameter(prefix: "/homekit/characteristics/") {
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                response = await writeCharacteristic(id: characteristicId, body: request.body, requestId: requestId, started: started)
                break
            }
            response = error(404, "not_found", "Route not found")

        case ("POST", _):
            if let sceneId = request.pathParameter(prefix: "/homekit/scenes/"),
               sceneId.hasSuffix("/execute") {
                let id = String(sceneId.dropLast("/execute".count))
                guard homeKitEnabled else {
                    response = error(403, "module_disabled", "HomeKit module disabled")
                    break
                }
                guard let (home, actionSet) = await MainActor.run(body: { self.homeKit.scene(with: id) }) else {
                    response = error(404, "not_found", "Scene not found")
                    break
                }
                do {
                    try await self.homeKit.executeScene(home, actionSet: actionSet)
                    logger.log(level: "info", message: "scene_executed", metadata: [
                        "id": id,
                        "name": actionSet.name
                    ])
                    response = ok(.object([
                        "status": .string("executed"),
                        "name": .string(actionSet.name)
                    ]))
                } catch {
                    logger.log(level: "error", message: "scene_execute_failed", metadata: [
                        "id": id,
                        "error": error.localizedDescription
                    ])
                    response = HTTPResponse.error(
                        status: 500,
                        code: "execute_failed",
                        message: error.localizedDescription,
                        requestId: requestId,
                        started: started
                    )
                }
                break
            }
            fallthrough

        case ("POST", "/homekit/characteristic"):
            guard homeKitEnabled else {
                response = error(403, "module_disabled", "HomeKit module disabled")
                break
            }
            response = await writeCharacteristic(body: request.body, requestId: requestId, started: started)

        default:
            response = error(405, "method_not_allowed", "Method not allowed")
        }

        logger.logRequest(
            method: request.method,
            path: request.path,
            status: response.status,
            requestId: requestId,
            latencyMs: response.latencyMs
        )
        return response
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return true }

        if let header = request.headers["authorization"]?.lowercased(), header.hasPrefix("bearer ") {
            let value = header.replacingOccurrences(of: "bearer ", with: "")
            return value == token
        }
        if let header = request.headers["x-casa-token"] {
            return header == token
        }
        return false
    }

    private func writeCharacteristic(
        id: String? = nil,
        body: Data?,
        requestId: String,
        started: Date
    ) async -> HTTPResponse {
        func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
            HTTPResponse.error(status: status, code: code, message: message, requestId: requestId, started: started)
        }

        guard let body = body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return error(400, "invalid_payload", "Body must be JSON")
        }

        let idString = id ?? (payload["id"] as? String)
        guard let idString = idString,
              let characteristicId = UUID(uuidString: idString) else {
            return error(400, "invalid_id", "Characteristic id is required")
        }

        let characteristic = await MainActor.run { self.homeKit.characteristic(with: characteristicId) }
        guard let characteristic else {
            logger.log(level: "warn", message: "characteristic_not_found", metadata: [
                "id": idString
            ])
            return error(404, "not_found", "Characteristic not found")
        }
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            logger.log(level: "warn", message: "characteristic_read_only", metadata: [
                "id": idString
            ])
            return error(405, "read_only", "Characteristic is read-only")
        }

        let value = payload["value"]
        await writeValue(characteristic, value: value)
        logger.log(level: "info", message: "characteristic_write", metadata: [
            "id": idString
        ])

        return HTTPResponse.ok(.object([
            "status": .string("queued")
        ]), requestId: requestId, started: started)
    }

    private func readValue(_ characteristic: HMCharacteristic) async -> Any? {
        await withCheckedContinuation { continuation in
            characteristic.readValue { _ in
                self.logger.log(level: "info", message: "characteristic_read", metadata: [
                    "id": characteristic.uniqueIdentifier.uuidString
                ])
                continuation.resume(returning: characteristic.value)
            }
        }
    }

    private func writeValue(_ characteristic: HMCharacteristic, value: Any?) async {
        await withCheckedContinuation { continuation in
            characteristic.writeValue(value) { _ in
                self.logger.log(level: "info", message: "characteristic_write_complete", metadata: [
                    "id": characteristic.uniqueIdentifier.uuidString
                ])
                continuation.resume()
            }
        }
    }

}

extension HomeKitServer: @unchecked Sendable {}

private final class HTTPConnectionHandler {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logger: CasaLogger
    private let route: (HTTPRequest) async -> HTTPResponse
    private let onClose: () -> Void
    private var buffer = Data()
    private var isProcessing = false
    private var shouldClose = false
    private var didClose = false
    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 1 * 1024 * 1024

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        logger: CasaLogger,
        route: @escaping (HTTPRequest) async -> HTTPResponse,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.logger = logger
        self.route = route
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.shouldClose = true
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self = self else { return }
            if let data = data {
                self.buffer.append(data)
                self.processBuffer()
                if !self.shouldClose {
                    self.receive()
                }
            } else {
                self.close()
            }
        }
    }

    private func processBuffer() {
        guard !isProcessing else { return }
        while true {
            switch HTTPRequest.parse(from: buffer, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes) {
            case .incomplete:
                return
            case .invalid(let status, let message):
                logger.log(level: "warn", message: "request_invalid", metadata: [
                    "status": String(status),
                    "message": message
                ])
                let response = HTTPResponse.error(
                    status: status,
                    code: "bad_request",
                    message: message,
                    requestId: UUID().uuidString,
                    started: Date()
                )
                send(response, keepAlive: false)
                return
            case .complete(let request, let consumed):
                buffer.removeSubrange(0..<consumed)
                isProcessing = true
                Task {
                    let response = await route(request)
                    self.send(response, keepAlive: request.keepAlive)
                }
                return
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(content: response.encoded(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.isProcessing = false
            if keepAlive {
                self.processBuffer()
            } else {
                self.close()
            }
        })
    }

    private func close() {
        if !didClose {
            didClose = true
            onClose()
        }
        shouldClose = true
        connection.cancel()
    }
}

enum HTTPParseResult {
    case incomplete
    case invalid(status: Int, message: String)
    case complete(HTTPRequest, Int)
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data?
    let keepAlive: Bool

    func pathParameter(prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = String(path.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    static func parse(from data: Data, maxHeaderBytes: Int, maxBodyBytes: Int) -> HTTPParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes {
                return .invalid(status: 431, message: "Header too large")
            }
            return .incomplete
        }
        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        if headerData.count > maxHeaderBytes {
            return .invalid(status: 431, message: "Header too large")
        }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid(status: 400, message: "Header is not valid UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid(status: 400, message: "Missing request line")
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 3 else {
            return .invalid(status: 400, message: "Invalid request line")
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let version = String(requestParts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .invalid(status: 400, message: "Unsupported HTTP version")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1]
            } else if !line.isEmpty {
                return .invalid(status: 400, message: "Invalid header line")
            }
        }

        if version == "HTTP/1.1", headers["host"] == nil {
            return .invalid(status: 400, message: "Missing Host header")
        }

        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.contains("chunked") {
            return .invalid(status: 501, message: "Chunked transfer encoding is not supported")
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > maxBodyBytes {
            return .invalid(status: 413, message: "Body too large")
        }
        let bodyStart = headerRange.upperBound
        let totalLength = bodyStart + contentLength
        guard data.count >= totalLength else {
            return .incomplete
        }
        let body = contentLength > 0 ? data.subdata(in: bodyStart..<totalLength) : nil

        let keepAlive: Bool
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" {
            keepAlive = connection == "keep-alive"
        } else {
            keepAlive = connection != "close"
        }

        let path: String
        var query: [String: String] = [:]
        if let components = URLComponents(string: target) {
            path = components.path
            if let items = components.queryItems {
                for item in items {
                    if let value = item.value {
                        query[item.name] = value
                    }
                }
            }
        } else {
            return .invalid(status: 400, message: "Invalid request target")
        }

        return .complete(
            HTTPRequest(
                method: method,
                path: path,
                query: query,
                headers: headers,
                body: body,
                keepAlive: keepAlive
            ),
            totalLength
        )
    }
}

struct HTTPResponse {
    let status: Int
    let body: JSONValue
    let requestId: String
    let latencyMs: Int
    let rawBody: Data?
    let contentType: String

    static func ok(_ body: JSONValue, requestId: String, started: Date) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            body: body,
            requestId: requestId,
            latencyMs: HTTPResponse.latencyMs(since: started),
            rawBody: nil,
            contentType: "application/json"
        )
    }

    static func error(
        status: Int,
        code: String,
        message: String,
        details: JSONValue? = nil,
        requestId: String,
        started: Date
    ) -> HTTPResponse {
        var errorPayload: [String: JSONValue] = [
            "code": .string(code),
            "message": .string(message)
        ]
        if let details = details {
            errorPayload["details"] = details
        }

        let body: JSONValue = .object([
            "requestId": .string(requestId),
            "ok": .bool(false),
            "error": .object(errorPayload),
            "latencyMs": .number(Double(HTTPResponse.latencyMs(since: started)))
        ])
        return HTTPResponse(
            status: status,
            body: body,
            requestId: requestId,
            latencyMs: HTTPResponse.latencyMs(since: started),
            rawBody: nil,
            contentType: "application/json"
        )
    }

    static func serverError(message: String) -> HTTPResponse {
        HTTPResponse(
            status: 500,
            body: .object([
                "requestId": .string(UUID().uuidString),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("server_error"),
                    "message": .string(message)
                ]),
                "latencyMs": .number(0)
            ]),
            requestId: UUID().uuidString,
            latencyMs: 0,
            rawBody: nil,
            contentType: "application/json"
        )
    }

    static func raw(status: Int, contentType: String, body: Data, requestId: String, started: Date) -> HTTPResponse {
        HTTPResponse(
            status: status,
            body: .null,
            requestId: requestId,
            latencyMs: HTTPResponse.latencyMs(since: started),
            rawBody: body,
            contentType: contentType
        )
    }

    func encoded(keepAlive: Bool) -> Data {
        let bodyData: Data
        let contentTypeHeader: String
        if let rawBody = rawBody {
            bodyData = rawBody
            contentTypeHeader = contentType
        } else {
            if status >= 400 {
                bodyData = body.encodedData()
            } else {
                let envelope: JSONValue = .object([
                    "requestId": .string(requestId),
                    "ok": .bool(true),
                    "data": body,
                    "latencyMs": .number(Double(latencyMs))
                ])
                bodyData = envelope.encodedData()
            }
            contentTypeHeader = contentType
        }

        let connection = keepAlive ? "keep-alive" : "close"
        let response = "HTTP/1.1 \(status) \(HTTPResponse.reasonPhrase(for: status))\r\n" +
            "Content-Type: \(contentTypeHeader)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: \(connection)\r\n" +
            "X-Request-Id: \(requestId)\r\n" +
            "Cache-Control: no-store\r\n\r\n"
        var data = Data(response.utf8)
        data.append(bodyData)
        return data
    }

    private static func latencyMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000.0)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    func encodedData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

enum HomeKitPayload {
    static func homes(_ homes: [CasaHome]) -> JSONValue {
        .array(homes.map { home in
            .object([
                "id": .string(home.id),
                "name": .string(home.name)
            ])
        })
    }

    static func rooms(_ rooms: [CasaRoom]) -> JSONValue {
        .array(rooms.map { room in
            .object([
                "id": .string(room.id),
                "name": .string(room.name),
                "homeId": .string(room.homeId)
            ])
        })
    }

    static func services(_ services: [CasaService]) -> JSONValue {
        .array(services.map { service in
            .object([
                "id": .string(service.id),
                "name": .string(service.name),
                "type": .string(service.type),
                "accessoryId": .string(service.accessoryId)
            ])
        })
    }

    static func accessories(_ accessories: [CasaAccessory]) -> JSONValue {
        .array(accessories.map { accessoryPayload($0) })
    }

    static func accessoryPayload(_ accessory: CasaAccessory) -> JSONValue {
        .object([
            "id": .string(accessory.id),
            "name": .string(accessory.name),
            "category": .string(accessory.category),
            "room": .string(accessory.room),
            "hasCameraProfile": .bool(accessory.hasCameraProfile),
            "services": .array(accessory.services.map { service in
                JSONValue.object([
                    "id": .string(service.id),
                    "name": .string(service.name),
                    "type": .string(service.type),
                    "characteristics": characteristics(service.characteristics)
                ])
            })
        ])
    }

    static func characteristicPayload(_ characteristic: CasaCharacteristic) -> JSONValue {
        .object([
            "id": .string(characteristic.id),
            "type": .string(characteristic.type),
            "metadata": .object([
                "format": .string(characteristic.metadata.format),
                "minValue": jsonValue(characteristic.metadata.minValue),
                "maxValue": jsonValue(characteristic.metadata.maxValue),
                "stepValue": jsonValue(characteristic.metadata.stepValue),
                "validValues": jsonArray(characteristic.metadata.validValues),
                "units": .string(characteristic.metadata.units)
            ]),
            "properties": .array(characteristic.properties.map { .string($0) }),
            "value": jsonValue(characteristic.value)
        ])
    }

    static func cameras(_ cameras: [CasaCamera]) -> JSONValue {
        .array(cameras.map { cameraPayload($0) })
    }

    static func cameraPayload(_ camera: CasaCamera) -> JSONValue {
        .object([
            "id": .string(camera.id),
            "accessoryId": .string(camera.accessoryId),
            "name": .string(camera.name)
        ])
    }

    static func scenes(_ scenes: [CasaScene]) -> JSONValue {
        .array(scenes.map { scene in
            .object([
                "id": .string(scene.id),
                "name": .string(scene.name),
                "homeId": .string(scene.homeId),
                "type": .string(scene.type),
                "isExecuting": .bool(scene.isExecuting)
            ])
        })
    }

    static func schema(_ accessories: [CasaAccessory]) -> JSONValue {
        let entries = accessories.flatMap { accessory in
            accessory.services.flatMap { service in
                service.characteristics.map { characteristic in
                    let format = characteristic.metadata.format
                    let writable = characteristic.properties.contains("write")
                    return JSONValue.object([
                        "id": .string(characteristic.id),
                        "accessoryId": .string(accessory.id),
                        "serviceId": .string(service.id),
                        "type": .string(characteristic.type),
                        "format": .string(format),
                        "writable": .bool(writable),
                        "minValue": jsonValue(characteristic.metadata.minValue),
                        "maxValue": jsonValue(characteristic.metadata.maxValue),
                        "stepValue": jsonValue(characteristic.metadata.stepValue),
                        "validValues": jsonArray(characteristic.metadata.validValues),
                        "units": .string(characteristic.metadata.units),
                        "valueType": .string(valueType(from: format))
                    ])
                }
            }
        }
        return .array(entries)
    }

    private static func jsonArray(_ values: [Any]) -> JSONValue {
        .array(values.map { jsonValue($0) })
    }


    private static func valueType(from format: String) -> String {
        switch format {
        case HMCharacteristicMetadataFormatBool:
            return "bool"
        case HMCharacteristicMetadataFormatInt,
             HMCharacteristicMetadataFormatFloat:
            return "number"
        case HMCharacteristicMetadataFormatString:
            return "string"
        case HMCharacteristicMetadataFormatData,
             HMCharacteristicMetadataFormatTLV8:
            return "data"
        case HMCharacteristicMetadataFormatUInt8,
             HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32,
             HMCharacteristicMetadataFormatUInt64:
            return "number"
        default:
            return "unknown"
        }
    }

    private static func characteristics(_ characteristics: [CasaCharacteristic]) -> JSONValue {
        .array(characteristics.map { characteristicPayload($0) })
    }

    static func jsonValue(_ value: Any?) -> JSONValue {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let date as Date:
            return .string(ISO8601DateFormatter().string(from: date))
        case let data as Data:
            return .string(data.base64EncodedString())
        case nil:
            return .null
        default:
            return .string("\(String(describing: value))")
        }
    }
}

private enum HomeKitMapper {
    static func homes(from homes: [HMHome]) -> [CasaHome] {
        homes.map { home in
            CasaHome(id: home.uniqueIdentifier.uuidString, name: home.name)
        }
    }

    static func rooms(from homes: [HMHome]) -> [CasaRoom] {
        homes.flatMap { home in
            home.rooms.map { room in
                CasaRoom(id: room.uniqueIdentifier.uuidString, name: room.name, homeId: home.uniqueIdentifier.uuidString)
            }
        }
    }

    static func services(from accessories: [HMAccessory]) -> [CasaService] {
        accessories.flatMap { accessory in
            accessory.services.map { service in
                CasaService(
                    id: service.uniqueIdentifier.uuidString,
                    name: service.name,
                    type: service.serviceType,
                    accessoryId: accessory.uniqueIdentifier.uuidString,
                    characteristics: service.characteristics.map { characteristic(from: $0, valueOverride: nil) }
                )
            }
        }
    }

    static func accessories(from accessories: [HMAccessory]) -> [CasaAccessory] {
        accessories.map { accessory(from: $0) }
    }

    static func accessory(from accessory: HMAccessory) -> CasaAccessory {
        CasaAccessory(
            id: accessory.uniqueIdentifier.uuidString,
            name: accessory.name,
            category: accessory.category.localizedDescription,
            room: accessory.room?.name ?? "",
            hasCameraProfile: accessory.cameraProfiles?.isEmpty == false,
            services: accessory.services.map { service in
                CasaService(
                    id: service.uniqueIdentifier.uuidString,
                    name: service.name,
                    type: service.serviceType,
                    accessoryId: accessory.uniqueIdentifier.uuidString,
                    characteristics: service.characteristics.map { characteristic(from: $0, valueOverride: nil) }
                )
            }
        )
    }

    static func characteristic(from characteristic: HMCharacteristic, valueOverride: Any?) -> CasaCharacteristic {
        let metadata = CasaCharacteristicMetadata(
            format: characteristic.metadata?.format ?? "",
            minValue: characteristic.metadata?.minimumValue,
            maxValue: characteristic.metadata?.maximumValue,
            stepValue: characteristic.metadata?.stepValue,
            validValues: characteristic.metadata?.validValues ?? [],
            units: characteristic.metadata?.units ?? ""
        )
        return CasaCharacteristic(
            id: characteristic.uniqueIdentifier.uuidString,
            type: characteristic.characteristicType,
            properties: characteristic.properties,
            metadata: metadata,
            value: valueOverride ?? characteristic.value
        )
    }

    static func scenes(from scenes: [HMActionSet], homes: [HMHome]) -> [CasaScene] {
        scenes.map { scene in
            let homeId = homes.first { $0.actionSets.contains(scene) }?.uniqueIdentifier.uuidString ?? ""
            return CasaScene(
                id: scene.uniqueIdentifier.uuidString,
                name: scene.name,
                homeId: homeId,
                type: scene.actionSetType,
                isExecuting: scene.isExecuting
            )
        }
    }

    static func cameras(from cameras: [HMCameraProfile]) -> [CasaCamera] {
        cameras.map { camera(from: $0) }
    }

    static func camera(from camera: HMCameraProfile) -> CasaCamera {
        CasaCamera(
            id: camera.uniqueIdentifier.uuidString,
            accessoryId: camera.accessory?.uniqueIdentifier.uuidString ?? "",
            name: camera.accessory?.name ?? "Camera"
        )
    }
}

private extension HomeKitManager {
    var cameras: [HMCameraProfile] {
        accessories.flatMap { $0.cameraProfiles ?? [] }
    }

    func accessory(with id: String) -> HMAccessory? {
        accessories.first { $0.uniqueIdentifier.uuidString == id }
    }

    func camera(with id: String) -> HMCameraProfile? {
        cameras.first { $0.uniqueIdentifier.uuidString == id }
    }
}
