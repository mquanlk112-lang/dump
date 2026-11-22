import Foundation
import UIKit
import MachO
import Darwin

struct DeviceSnapshot {
    let deviceName: String
    let model: String
    let systemVersion: String
    let batteryLevel: Int?
    let batteryState: String
    let isLowPowerMode: Bool
    let thermalState: ProcessInfo.ThermalState
    let appMemoryMB: Double?
    let uptime: TimeInterval

    static func capture() -> DeviceSnapshot {
        let device = UIDevice.current
        let level = device.batteryLevel
        let battery: Int? = level >= 0 ? Int((level * 100).rounded()) : nil

        return DeviceSnapshot(
            deviceName: device.name,
            model: modelName(),
            systemVersion: "iOS \(device.systemVersion)",
            batteryLevel: battery,
            batteryState: batteryStateName(device.batteryState),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            appMemoryMB: currentProcessMemoryMB(),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: return "Đang sạc"
        case .full: return "Đã đầy"
        case .unplugged: return "Không sạc"
        case .unknown: return "Không xác định"
        @unknown default: return "Không xác định"
        }
    }

    private static func modelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let known: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd gen)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max"
        ]
        return known[identifier] ?? identifier
    }

    private static func currentProcessMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_048_576
    }
}

extension ProcessInfo.ThermalState {
    var displayName: String {
        switch self {
        case .nominal: return "Bình thường"
        case .fair: return "Ấm"
        case .serious: return "Nóng"
        case .critical: return "Rất nóng"
        @unknown default: return "Không xác định"
        }
    }

    var detail: String {
        switch self {
        case .nominal: return "Không ghi nhận áp lực nhiệt đáng kể."
        case .fair: return "Thiết bị đang ấm; nên theo dõi khi chạy tác vụ nặng."
        case .serious: return "Hệ thống có thể giảm hiệu năng để kiểm soát nhiệt."
        case .critical: return "Nhiệt độ ở mức nghiêm trọng; nên dừng tác vụ nặng và để máy nguội."
        @unknown default: return "Không đọc được trạng thái nhiệt."
        }
    }
}
