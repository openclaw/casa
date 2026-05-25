import XCTest
import HomeKit
@testable import Casa

final class CasaTests: XCTestCase {
    func testHTTPRequestParse() {
        let raw = "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let data = Data(raw.utf8)
        let parsed = HTTPRequest.parse(from: data, maxHeaderBytes: 4096, maxBodyBytes: 1024 * 1024)
        if case let .complete(request, _) = parsed {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/health")
            XCTAssertEqual(request.keepAlive, false)
        } else {
            XCTFail("Expected complete request")
        }
    }

    func testHTTPResponseEnvelope() throws {
        let response = HTTPResponse.ok(.object(["status": .string("ok")]), requestId: "req-1", started: Date(timeIntervalSince1970: 0))
        let data = response.encoded(keepAlive: true)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("HTTP/1.1 200"))
        XCTAssertTrue(text.contains("\"requestId\""))
        XCTAssertTrue(text.contains("\"ok\""))
    }

    func testSchemaPayloadIncludesWritableCharacteristics() throws {
        let metadata = CasaCharacteristicMetadata(
            format: HMCharacteristicMetadataFormatBool,
            minValue: nil,
            maxValue: nil,
            stepValue: nil,
            validValues: [],
            units: ""
        )
        let characteristic = CasaCharacteristic(
            id: "char-1",
            type: "type-1",
            properties: ["write"],
            metadata: metadata,
            value: true
        )
        let service = CasaService(
            id: "svc-1",
            name: "Service",
            type: "type",
            accessoryId: "acc-1",
            characteristics: [characteristic]
        )
        let accessory = CasaAccessory(
            id: "acc-1",
            name: "Accessory",
            category: "Category",
            room: "Room",
            hasCameraProfile: false,
            services: [service]
        )

        let payload = HomeKitPayload.schema([accessory])
        let data = payload.encodedData()
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(json?.first?["writable"] as? Bool, true)
        XCTAssertEqual(json?.first?["id"] as? String, "char-1")
    }

    func testSchemaIncludesValidValuesAndRange() throws {
        let metadata = CasaCharacteristicMetadata(
            format: HMCharacteristicMetadataFormatInt,
            minValue: 0,
            maxValue: 100,
            stepValue: 5,
            validValues: [0, 50, 100],
            units: "%"
        )
        let characteristic = CasaCharacteristic(
            id: "char-2",
            type: "type-2",
            properties: ["read", "write"],
            metadata: metadata,
            value: 50
        )
        let service = CasaService(
            id: "svc-2",
            name: "Service",
            type: "type",
            accessoryId: "acc-2",
            characteristics: [characteristic]
        )
        let accessory = CasaAccessory(
            id: "acc-2",
            name: "Accessory",
            category: "Category",
            room: "Room",
            hasCameraProfile: false,
            services: [service]
        )

        let payload = HomeKitPayload.schema([accessory])
        let data = payload.encodedData()
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let entry = json?.first
        XCTAssertEqual(entry?["stepValue"] as? Double, 5)
        XCTAssertEqual(entry?["validValues"] as? [Double], [0, 50, 100])
        XCTAssertEqual(entry?["minValue"] as? Double, 0)
        XCTAssertEqual(entry?["maxValue"] as? Double, 100)
    }

    func testSchemaMapsNonFiniteNumbersToNull() throws {
        let metadata = CasaCharacteristicMetadata(
            format: HMCharacteristicMetadataFormatFloat,
            minValue: Double.nan,
            maxValue: Double.infinity,
            stepValue: -Double.infinity,
            validValues: [Double.nan, 1],
            units: ""
        )
        let characteristic = CasaCharacteristic(
            id: "char-3",
            type: "type-3",
            properties: ["read"],
            metadata: metadata,
            value: Double.nan
        )
        let service = CasaService(
            id: "svc-3",
            name: "Service",
            type: "type",
            accessoryId: "acc-3",
            characteristics: [characteristic]
        )
        let accessory = CasaAccessory(
            id: "acc-3",
            name: "Accessory",
            category: "Category",
            room: "Room",
            hasCameraProfile: false,
            services: [service]
        )

        let data = HomeKitPayload.schema([accessory]).encodedData()
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let entry = json?.first
        XCTAssertTrue(entry?["minValue"] is NSNull)
        XCTAssertTrue(entry?["maxValue"] is NSNull)
        XCTAssertTrue(entry?["stepValue"] is NSNull)
        let validValues = entry?["validValues"] as? [Any]
        XCTAssertTrue(validValues?.first is NSNull)
        XCTAssertEqual(validValues?.last as? Double, 1)
    }

    func testSettingsDefaultsAreOff() throws {
        let suiteName = "casa.tests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = CasaSettings.makeForTests(defaults: defaults)

        XCTAssertEqual(settings.port, 14663)
        XCTAssertEqual(settings.authToken, "")
        XCTAssertEqual(settings.autoStart, false)
        XCTAssertEqual(settings.homeKitEnabled, false)
        XCTAssertEqual(settings.onboardingComplete, false)
    }

    func testSettingsPersistence() throws {
        let suiteName = "casa.tests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = CasaSettings.makeForTests(defaults: defaults)

        settings.homeKitEnabled = true
        settings.onboardingComplete = true
        settings.autoStart = true

        let reloaded = CasaSettings.makeForTests(defaults: defaults)
        XCTAssertEqual(reloaded.homeKitEnabled, true)
        XCTAssertEqual(reloaded.onboardingComplete, true)
        XCTAssertEqual(reloaded.autoStart, true)
    }

    func testCLIStatusUnsupportedOnNonCatalyst() {
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(CLIInstaller.status().canInstall)
        #else
        let status = CLIInstaller.status()
        XCTAssertEqual(status.isInstalled, false)
        XCTAssertEqual(status.canInstall, false)
        XCTAssertNotNil(status.reason)
        #endif
    }
}
