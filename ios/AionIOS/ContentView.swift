import SwiftUI
import FamilyControls

/// 单 Tab 纯壳：Aion 网页 + JS 桥（健康/定位/监管都走网页页面）
struct ContentView: View {
    @StateObject private var webModel = WebModel()
    @ObservedObject private var pickerModel = AppPickerModel.shared
    /// 重试页上的线路选择（2026-09-21）：网页打不开时也能扳道岔。
    /// 初始值用 .auto（属性初始化器是 nonisolated 上下文，读 @MainActor 的
    /// APIClient.preference 会被编译器拒），真实值在 onAppear 里同步。
    @State private var routePreference: RoutePreference = .auto
    @State private var routeBusy = false
    @State private var routeError: String?

    var body: some View {
        ZStack {
            AionWebView(model: webModel)
            if webModel.failed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                    Text("连不上 Aion")
                        .font(.headline)
                    Text("检查老电脑是否在线，或换一条线路")
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
                                Text(pref.displayName)
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
                .onAppear { routePreference = APIClient.preference }  // 设置页改过线路时同步选中态
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
