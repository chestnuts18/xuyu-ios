import SwiftUI
import FamilyControls

/// 单 Tab 纯壳：Aion 网页 + JS 桥（健康/定位/监管都走网页页面）
struct ContentView: View {
    @StateObject private var webModel = WebModel()
    @ObservedObject private var pickerModel = AppPickerModel.shared

    var body: some View {
        ZStack {
            AionWebView(model: webModel)
            if webModel.failed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                    Text("连不上 Aion")
                        .font(.headline)
                    Text("检查老电脑是否在线，或 Tailscale 是否开着")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") { webModel.retry() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
