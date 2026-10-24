import SwiftUI
import FamilyControls

/// 单 Tab 纯壳：Aion 网页 + JS 桥（健康/定位/监管都走网页页面）
struct ContentView: View {
    @ObservedObject private var webModel = WebModel.shared
    @ObservedObject private var pickerModel = AppPickerModel.shared
    /// 重试页上的线路选择（2026-09-21）：网页打不开时也能扳道岔。
    /// 初始值用 .auto（属性初始化器是 nonisolated 上下文，读 @MainActor 的
    /// APIClient.preference 会被编译器拒），真实值在 onAppear 里同步。
    @State private var routePreference: RoutePreference = .auto
    @State private var routeBusy = false
    @State private var routeError: String?
    /// 重试页自动探路结果（候选 key → 现在通不通），2026-10-25。
    /// 锁「在家」的人在门外最想知道的是「哪条还能走」——三秒探完直接亮绿点。
    @State private var routeAvailability: [String: Bool] = [:]
    @State private var availabilityBusy = false

    var body: some View {
        ZStack {
            AionWebView(model: webModel)
            if webModel.failed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                    // 2026-10-25：锁定线路时把话说清楚。用户锁了「在家」出门，
                    // 看到的不能只是笼统的「连不上 Aion」——得知道是那条路自己的问题。
                    Text(APIClient.preference == .auto
                         ? "连不上 Aion"
                         : "「\(APIClient.preference.displayName)」连不上")
                        .font(.headline)
                    Text(APIClient.preference == .auto
                         ? "检查老电脑是否在线，或换一条线路"
                         : "你锁定了这条线路，手机现在可能不在它的网络里。要换一条吗？")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") { webModel.retry() }
                        .buttonStyle(.borderedProminent)
                    Divider()
                    Text("走哪条路")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(RoutePreference.allCases) { pref in
                            Button {
                                routeBusy = true
                                routeError = nil
                                Task {
                                    let err = await webModel.switchRoute(pref)
                                    if let err {
                                        routeError = err
                                    } else {
                                        routePreference = pref
                                    }
                                    routeBusy = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    // 探完才画点：绿=这条现在能走，灰=走不了。
                                    // 还没探完就不画，免得给人「全都不通」的错觉。
                                    if let ok = routeAvailability[pref.rawValue] {
                                        Circle()
                                            .fill(ok ? Color.green : Color.secondary.opacity(0.4))
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(pref.displayName)
                                }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        routePreference == pref
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.15),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(routePreference == pref ? Color.white : Color.primary)
                            }
                            .disabled(routeBusy)
                        }
                    }
                    if routeBusy {
                        Text("正在探路…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let routeError {
                        Text(routeError)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .onAppear {
                    routePreference = APIClient.preference  // 设置页改过线路时同步选中态
                    // 2026-10-25：重试页一露头就把三条路都探一遍，能走的亮绿点。
                    guard !availabilityBusy else { return }
                    availabilityBusy = true
                    Task {
                        routeAvailability = await APIClient.shared.probeAvailability()
                        availabilityBusy = false
                    }
                }
            }
            // 应用选择器：直接嵌视图层级（不走 sheet/fullScreenCover 弹层容器——
            // 实测 FamilyActivityPicker 在弹层里 selection 绑定不写回，
            // 内嵌形态是今天白天验证过的可用模式）
            if pickerModel.isPresented {
                AppPickerOverlayView()
                    .onDisappear { pickerModel.finish() }
            }
        }
    }
}
