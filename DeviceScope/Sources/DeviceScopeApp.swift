import SwiftUI
import UIKit

@main
struct DeviceScopeApp: App {
    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .preferredColorScheme(.dark)
        }
    }
}
