import Foundation

struct CasaHome {
    let id: String
    let name: String
}

struct CasaRoom {
    let id: String
    let name: String
    let homeId: String
}

struct CasaCharacteristicMetadata {
    let format: String
    let minValue: Any?
    let maxValue: Any?
    let stepValue: Any?
    let validValues: [Any]
    let units: String
}

struct CasaCharacteristic {
    let id: String
    let type: String
    let properties: [String]
    let metadata: CasaCharacteristicMetadata
    let value: Any?
}

struct CasaService {
    let id: String
    let name: String
    let type: String
    let accessoryId: String
    let characteristics: [CasaCharacteristic]
}

struct CasaAccessory {
    let id: String
    let name: String
    let category: String
    let room: String
    let hasCameraProfile: Bool
    let services: [CasaService]
}

struct CasaCamera {
    let id: String
    let accessoryId: String
    let name: String
}

struct CasaScene {
    let id: String
    let name: String
    let homeId: String
    let type: String
    let isExecuting: Bool
}

enum SceneSelection {
    static let allScenesId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
