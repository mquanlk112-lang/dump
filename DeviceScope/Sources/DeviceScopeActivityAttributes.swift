import ActivityKit
import Foundation

struct DeviceScopeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let batteryPercent: Int
        let batteryState: String
        let thermalLabel: String
        let memoryMB: Int
        let lastUpdated: Date
    }

    let deviceModel: String
}
