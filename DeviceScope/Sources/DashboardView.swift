import SwiftUI
import UIKit
import Combine
import ActivityKit
import CoreFoundation

struct DashboardView: View {
    @State private var snapshot = DeviceSnapshot.capture()
    @State private var selectedTab = 0
    @State private var isLiveActivityActive = false
    @State private var liveActivityMessage = "Live Activity hiển thị snapshot gần nhất trên Dynamic Island."
    @State private var lastLiveActivityUpdate = Date.distantPast
    @State private var systemHUDMessage = "Bật HUD một lần, sau đó chuyển sang Free Fire để xem trạng thái thiết bị."
    @AppStorage("devicescope.systemHUD.enabled") private var isSystemHUDEnabled = false

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.66, green: 0.20, blue: 1.0)
    private let accentBlue = Color(red: 0.29, green: 0.20, blue: 1.0)
    private let canvas = Color(red: 0.025, green: 0.018, blue: 0.075)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.045, green: 0.018, blue: 0.13), canvas, Color(red: 0.018, green: 0.012, blue: 0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case 1: gamePage
                    case 2: toolsPage
                    case 3: infoPage
                    default: homePage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            snapshot = DeviceSnapshot.capture()
            refreshLiveActivityStatus()
            if isSystemHUDEnabled {
                postSystemHUDCommand("show")
            }
        }
        .onReceive(refreshTimer) { _ in
            snapshot = DeviceSnapshot.capture()
            updateLiveActivity(force: false)
        }
    }

    private var homePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                header
                systemStatusCard
                hudControlCard
                deviceMetricsSection
                footerNote
            }
            .padding(.horizontal, 17)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private var gamePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                header
                sectionHeading("CHẾ ĐỘ KHI CHƠI", subtitle: "Bảng trạng thái nổi dành cho lúc chơi game")
                hudControlCard
                panel {
                    HStack(spacing: 12) {
                        iconTile("gamecontroller.fill", tint: .purple)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Không can thiệp Free Fire")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("HUD được vẽ bởi SpringBoard. Tweak không đọc bộ nhớ, dữ liệu trận đấu hoặc thay đổi tiến trình game.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.60))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                panel {
                    Label("Không có ESP hoặc dữ liệu người chơi", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.green)
                    Text("Chỉ số được phép hiển thị: pin, mức nhiệt hệ thống, RAM ước lượng và thời gian hoạt động.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private var toolsPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                header
                sectionHeading("CÔNG CỤ", subtitle: "Điều khiển HUD và làm mới trạng thái")
                hudControlCard
                panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dynamic Island")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("Live Activity trên iPhone hỗ trợ")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        Spacer()
                        Button(action: toggleLiveActivity) {
                            Text(isLiveActivityActive ? "Tắt" : "Bật")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 10)
                                .background(isLiveActivityActive ? Color.red.opacity(0.25) : accent.opacity(0.32), in: Capsule())
                        }
                    }
                    Text(liveActivityMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.47))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: refreshSnapshot) {
                    Label("Làm mới chỉ số thiết bị", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(LinearGradient(colors: [accent, accentBlue], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private var infoPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                header
                sectionHeading("THÔNG TIN", subtitle: "FF Tool · Device Status Companion")
                panel {
                    Label("Thông tin thiết bị", systemImage: "iphone.gen3")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    infoRow("Thiết bị", value: snapshot.model)
                    infoRow("Phiên bản", value: snapshot.systemVersion)
                    infoRow("Nguồn", value: snapshot.isLowPowerMode ? "Chế độ nguồn thấp bật" : "Chế độ nguồn thấp tắt")
                    infoRow("Pin", value: snapshot.batteryLevel.map { "\($0)% · \(snapshot.batteryState)" } ?? "Không khả dụng")
                }
                panel {
                    Label("Giới hạn minh bạch", systemImage: "info.circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("Nhiệt là mức áp lực nhiệt iOS báo cáo, không phải nhiệt độ °C. RAM trong app là bộ nhớ riêng của FF Tool; HUD hệ thống hiển thị ước lượng RAM trống từ số trang bộ nhớ.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(Color.white.opacity(0.08))
                    Text("Ứng dụng không ép xung CPU, không giải phóng RAM của app khác, không đọc hoặc sửa bộ nhớ Free Fire và không ẩn jailbreak.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("FF Tool · DeviceScope")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.30))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 17)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accentBlue, Color(red: 0.18, green: 0.06, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 25, weight: .black))
                    .foregroundColor(.white)
                    .shadow(color: .white.opacity(0.35), radius: 7)
            }
            .frame(width: 52, height: 52)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.purple.opacity(0.75), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text("FF Tool")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("Free Fire Helper")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.72, green: 0.63, blue: 1.0))
            }
            Spacer()
            Button(action: { selectedTab = 3 }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 44, height: 44)
                    .background(Color.purple.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Thông tin và cài đặt")
        }
        .padding(.bottom, 2)
    }

    private var systemStatusCard: some View {
        let isHot = snapshot.thermalState == .serious || snapshot.thermalState == .critical
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(isHot ? Color.orange : Color.green).frame(width: 9, height: 9)
                    Text("Trạng thái hệ thống")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                }
                Text(isHot ? "Đang nóng" : "Hoạt động tốt")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(isHot ? Color.orange : Color.green)
                Text(isHot ? snapshot.thermalState.detail : "Thiết bị đang hoạt động ổn định.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke((isHot ? Color.orange : Color.green).opacity(0.30), lineWidth: 4).frame(width: 56, height: 56)
                Image(systemName: isHot ? "thermometer.high" : "checkmark")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(isHot ? .orange : .green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.green.opacity(0.09), Color(red: 0.035, green: 0.10, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke((isHot ? Color.orange : Color.green).opacity(0.42), lineWidth: 1))
    }

    private var hudControlCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                iconTile("scope", tint: accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HUD trạng thái thiết bị")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(isSystemHUDEnabled ? "HUD đã được bật" : "Hiển thị trên màn hình khi chơi")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.58))
                }
                Spacer(minLength: 4)
                Toggle("HUD", isOn: Binding(
                    get: { isSystemHUDEnabled },
                    set: { enabled in
                        isSystemHUDEnabled = enabled
                        postSystemHUDCommand(enabled ? "show" : "hide")
                        systemHUDMessage = enabled ? "Đã gửi lệnh bật HUD đến SpringBoard." : "HUD nổi đã được yêu cầu tắt."
                    }
                ))
                .labelsHidden()
                .tint(accent)
                .scaleEffect(0.92)
            }

            Button(action: toggleSystemHUD) {
                HStack(spacing: 10) {
                    Image(systemName: isSystemHUDEnabled ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .heavy))
                    Text(isSystemHUDEnabled ? "Tắt HUD nổi" : "Bật HUD trên màn hình")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    LinearGradient(colors: isSystemHUDEnabled ? [Color(red: 0.43, green: 0.08, blue: 0.72), Color(red: 0.25, green: 0.08, blue: 0.52)] : [accent, accentBlue], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(0.72), lineWidth: 1))
                .shadow(color: accent.opacity(0.20), radius: 12, y: 4)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color.purple.opacity(0.95))
                Text(systemHUDMessage + " HUD chỉ đọc thông số thiết bị; không hiển thị ESP hoặc dữ liệu trận đấu.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(red: 0.79, green: 0.72, blue: 1.0))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(15)
        .background(panelBackground)
    }

    private var deviceMetricsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Trạng Thái Máy", systemImage: "chart.bar.fill")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Đang cập nhật")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.green)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                metricTile(title: "Pin", value: snapshot.batteryLevel.map { "\($0)%" } ?? "N/A", detail: snapshot.batteryState, icon: "battery.100percent", tint: .green)
                metricTile(title: "Nhiệt hệ thống", value: snapshot.thermalState.displayName, detail: "Mức iOS báo cáo", icon: "thermometer.medium", tint: .cyan)
                metricTile(title: "RAM app", value: snapshot.appMemoryMB.map { String(format: "%.1f MB", $0) } ?? "N/A", detail: "FF Tool đang dùng", icon: "memorychip", tint: .mint)
                metricTile(title: "Thời gian hoạt động", value: formatUptime(snapshot.uptime), detail: "Từ lần khởi động gần nhất", icon: "clock", tint: .blue)
            }
        }
        .padding(15)
        .background(panelBackground)
    }

    private var footerNote: some View {
        Text("FF Tool đọc các chỉ số iOS cho phép. Nhiệt không phải số đo °C; RAM app không phải tổng RAM của iPhone.")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.36))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton("Trang chủ", icon: "house.fill", tag: 0)
            tabButton("Game", icon: "gamecontroller.fill", tag: 1)
            tabButton("Công cụ", icon: "wrench.and.screwdriver.fill", tag: 2)
            tabButton("Thông tin", icon: "info.circle", tag: 3)
        }
        .padding(.top, 9)
        .padding(.bottom, 5)
        .background(Color.black.opacity(0.76))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func tabButton(_ title: String, icon: String, tag: Int) -> some View {
        Button { selectedTab = tag } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(selectedTab == tag ? accent : Color.white.opacity(0.48))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.0)
                .foregroundColor(accent)
            Text(subtitle)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(15)
            .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.075, green: 0.045, blue: 0.15).opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.purple.opacity(0.34), lineWidth: 1))
    }

    private func iconTile(_ symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(tint.opacity(0.14))
                .frame(width: 58, height: 58)
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(tint)
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.56))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(Color(red: 0.12, green: 0.075, blue: 0.22).opacity(0.92), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.045), lineWidth: 1))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(.white.opacity(0.50))
            Spacer()
            Text(value).foregroundColor(.white).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func refreshSnapshot() {
        snapshot = DeviceSnapshot.capture()
        updateLiveActivity(force: true)
    }

    private func toggleSystemHUD() {
        let next = !isSystemHUDEnabled
        isSystemHUDEnabled = next
        postSystemHUDCommand(next ? "show" : "hide")
        systemHUDMessage = next
            ? "Đã gửi lệnh bật đến SpringBoard. Khi HUD hiện, chuyển sang Free Fire."
            : "Đã gửi lệnh tắt HUD nổi."
    }

    private func postSystemHUDCommand(_ command: String) {
        let name = CFNotificationName("com.minhquandev.devicescope.hud.\(command)" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    @available(iOS 16.1, *)
    private func makeLiveActivityState() -> DeviceScopeActivityAttributes.ContentState {
        DeviceScopeActivityAttributes.ContentState(
            batteryPercent: snapshot.batteryLevel ?? -1,
            batteryState: snapshot.batteryState,
            thermalLabel: snapshot.thermalState.displayName,
            memoryMB: snapshot.appMemoryMB.map { Int($0.rounded()) } ?? -1,
            lastUpdated: Date()
        )
    }

    private func refreshLiveActivityStatus() {
        guard #available(iOS 16.1, *) else {
            liveActivityMessage = "Live Activity yêu cầu iOS 16.1 trở lên."
            return
        }
        isLiveActivityActive = !Activity<DeviceScopeActivityAttributes>.activities.isEmpty
        if isLiveActivityActive {
            liveActivityMessage = "Đang chạy. Nội dung là snapshot gần nhất."
        }
    }

    private func toggleLiveActivity() {
        guard #available(iOS 16.1, *) else {
            liveActivityMessage = "Live Activity yêu cầu iOS 16.1 trở lên."
            return
        }

        let activeActivities = Activity<DeviceScopeActivityAttributes>.activities
        if !activeActivities.isEmpty {
            for activity in activeActivities {
                Task { await activity.end(using: nil, dismissalPolicy: .immediate) }
            }
            isLiveActivityActive = false
            liveActivityMessage = "Đã tắt Live Activity."
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            isLiveActivityActive = false
            liveActivityMessage = "Live Activities đang bị tắt trong Cài đặt iPhone."
            return
        }

        let attributes = DeviceScopeActivityAttributes(deviceModel: snapshot.model)
        let state = makeLiveActivityState()
        do {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } else {
                _ = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            }
            isLiveActivityActive = true
            lastLiveActivityUpdate = Date()
            liveActivityMessage = "Đã bật. Dynamic Island hiển thị snapshot gần nhất."
        } catch {
            isLiveActivityActive = false
            liveActivityMessage = "Không bật được Live Activity: \(error.localizedDescription)"
        }
    }

    private func updateLiveActivity(force: Bool) {
        guard #available(iOS 16.1, *) else { return }
        let activities = Activity<DeviceScopeActivityAttributes>.activities
        guard !activities.isEmpty else { return }

        let now = Date()
        guard force || now.timeIntervalSince(lastLiveActivityUpdate) >= 30 else { return }
        lastLiveActivityUpdate = now
        let state = makeLiveActivityState()

        for activity in activities {
            Task {
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
                    await activity.update(content)
                } else {
                    await activity.update(using: state)
                }
            }
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
