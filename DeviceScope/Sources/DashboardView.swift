import SwiftUI
import UIKit
import Combine
import ActivityKit

struct DashboardView: View {
    @State private var snapshot = DeviceSnapshot.capture()
    @State private var showingAbout = false
    @State private var isLiveActivityActive = false
    @State private var liveActivityMessage = "Nhấn Bật trước khi mở game. Dynamic Island hiển thị lần đọc gần nhất; iOS có thể tạm dừng cập nhật khi game ở foreground."
    @State private var lastLiveActivityUpdate = Date.distantPast
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.055, blue: 0.10), Color(red: 0.055, green: 0.08, blue: 0.14), Color(red: 0.025, green: 0.035, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    deviceCard
                    liveActivityCard
                    thermalCard
                    metricsGrid
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showingAbout) { aboutSheet }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            snapshot = DeviceSnapshot.capture()
            refreshLiveActivityStatus()
        }
        .onReceive(refreshTimer) { _ in
            snapshot = DeviceSnapshot.capture()
            updateLiveActivity(force: false)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DEVICESCOPE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    
                    .foregroundStyle(Color.cyan.opacity(0.9))
                Text("Tổng quan thiết bị")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                snapshot = DeviceSnapshot.capture()
                updateLiveActivity(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
            }
            .accessibilityLabel("Làm mới dữ liệu")
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("THIẾT BỊ", systemImage: "iphone.gen3")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [Color.cyan.opacity(0.24), Color.blue.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 88)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Color.cyan)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.deviceName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(snapshot.model)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(snapshot.systemVersion)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cyan.opacity(0.9))
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(.white.opacity(0.10))
            HStack {
                Label("Chế độ nguồn thấp", systemImage: "battery.25percent")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(snapshot.isLowPowerMode ? "Đang bật" : "Đang tắt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(snapshot.isLowPowerMode ? Color.orange : Color.green)
            }
        }
        .padding(18)
        .background(cardBackground)
    }


    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("DYNAMIC ISLAND")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(isLiveActivityActive ? "Đang hiển thị trạng thái" : "Hiện trạng thái khi chơi game")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                Button(action: toggleLiveActivity) {
                    HStack(spacing: 6) {
                        Image(systemName: isLiveActivityActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(isLiveActivityActive ? "Tắt" : "Bật")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isLiveActivityActive ? Color.red.opacity(0.22) : Color.cyan.opacity(0.20),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            isLiveActivityActive ? Color.red.opacity(0.35) : Color.cyan.opacity(0.35),
                            lineWidth: 1
                        )
                    )
                }
                .accessibilityLabel(isLiveActivityActive ? "Tắt trạng thái Dynamic Island" : "Bật trạng thái Dynamic Island")
            }
            Text(liveActivityMessage)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.46))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(cardBackground)
    }

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
            liveActivityMessage = "Đang chạy. Nội dung là lần đọc gần nhất; mở lại DeviceScope để làm mới số liệu."
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
                Task {
                    await activity.end(using: nil, dismissalPolicy: .immediate)
                }
            }
            isLiveActivityActive = false
            liveActivityMessage = "Đã tắt trạng thái trên Dynamic Island."
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
                let content = ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(120)
                )
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } else {
                _ = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            }
            isLiveActivityActive = true
            lastLiveActivityUpdate = Date()
            liveActivityMessage = "Đã bật. Mở game để xem chỉ số trên Dynamic Island; số liệu sẽ là lần đọc gần nhất của ứng dụng."
        } catch {
            isLiveActivityActive = false
            liveActivityMessage = "Không bật được Live Activity: \\(error.localizedDescription)"
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
                    let content = ActivityContent(
                        state: state,
                        staleDate: Date().addingTimeInterval(120)
                    )
                    await activity.update(content)
                } else {
                    await activity.update(using: state)
                }
            }
        }
    }

    private var thermalCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(thermalColor.opacity(0.14)).frame(width: 48, height: 48)
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(thermalColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("TÌNH TRẠNG NHIỆT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    
                    .foregroundStyle(.white.opacity(0.5))
                Text(snapshot.thermalState.displayName)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(snapshot.thermalState.detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHỈ SỐ ĐANG ĐỌC")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                
                .foregroundStyle(.white.opacity(0.48))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MetricCard(
                    title: "PIN",
                    value: snapshot.batteryLevel.map { "\($0)%" } ?? "N/A",
                    detail: snapshot.batteryState,
                    icon: "battery.100percent",
                    tint: .green
                )
                MetricCard(
                    title: "RAM ỨNG DỤNG",
                    value: snapshot.appMemoryMB.map { String(format: "%.1f MB", $0) } ?? "N/A",
                    detail: "Bộ nhớ riêng của DeviceScope",
                    icon: "memorychip",
                    tint: .cyan
                )
                MetricCard(
                    title: "THỜI GIAN MÁY CHẠY",
                    value: formatUptime(snapshot.uptime),
                    detail: "Kể từ lần khởi động gần nhất",
                    icon: "clock.arrow.circlepath",
                    tint: .purple
                )
                MetricCard(
                    title: "LOW POWER",
                    value: snapshot.isLowPowerMode ? "ON" : "OFF",
                    detail: "Trạng thái iOS cung cấp",
                    icon: "bolt.fill",
                    tint: snapshot.isLowPowerMode ? .orange : .yellow
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("DeviceScope chỉ đọc các chỉ số iOS cho phép ứng dụng thông thường truy cập.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
            Button("Giới thiệu và giới hạn") { showingAbout = true }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.cyan)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 5)
    }

    private var aboutSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("DeviceScope không ép xung CPU, không giải phóng RAM của ứng dụng khác và không tắt tiến trình hệ thống. iOS không cấp các quyền đó cho ứng dụng thông thường.")
                Text("Chỉ số RAM hiển thị là bộ nhớ đang được chính DeviceScope sử dụng, không phải tổng RAM trống của iPhone.")
                Text("Trạng thái nhiệt được đọc từ ProcessInfo. Đây là mức nhiệt hệ thống báo cáo, không phải số đo nhiệt độ chính xác theo °C.")
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .padding(20)
            .navigationTitle("Giới thiệu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { showingAbout = false }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var thermalColor: Color {
        switch snapshot.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
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

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Circle().fill(tint.opacity(0.9)).frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    
                    .foregroundStyle(.white.opacity(0.47))
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.085), lineWidth: 1))
        )
    }
}
