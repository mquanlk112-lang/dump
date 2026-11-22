import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DeviceScopeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeviceScopeActivityAttributes.self) { context in
            DeviceScopeLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("DeviceScope", systemImage: "iphone.gen3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(batteryText(context.state.batteryPercent))
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("PIN")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        Label(context.state.thermalLabel, systemImage: "thermometer.medium")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(memoryText(context.state.memoryMB))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Text(context.state.lastUpdated, style: .time)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: "battery.100percent")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text(batteryText(context.state.batteryPercent))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }
}

private struct DeviceScopeLockScreenView: View {
    let context: ActivityViewContext<DeviceScopeActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("DEVICESCOPE", systemImage: "iphone.gen3")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(context.attributes.deviceModel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                metric(title: "PIN", value: batteryText(context.state.batteryPercent), icon: "battery.100percent")
                metric(title: "NHIỆT", value: context.state.thermalLabel, icon: "thermometer.medium")
                metric(title: "RAM APP", value: memoryText(context.state.memoryMB), icon: "memorychip")
            }

            HStack {
                Text(context.isStale ? "Dữ liệu cũ · mở app để cập nhật" : "Cập nhật gần nhất")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text(context.state.lastUpdated, style: .time)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .padding(15)
        .activityBackgroundTint(Color(red: 0.035, green: 0.055, blue: 0.10))
        .activitySystemActionForegroundColor(.white)
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func batteryText(_ value: Int) -> String {
    value >= 0 ? "\\(value)%" : "—"
}

private func memoryText(_ value: Int) -> String {
    value >= 0 ? "\\(value) MB" : "—"
}
