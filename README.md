# Aion iOS —— 徐聿的 iPhone 分身

一个 App 三个身份（Phase 1 只做了前两个）：

1. **Aion 聊天壳**：WKWebView 加载 `http://100.73.222.35:8080`（Tailscale 一个 IP 家里出门通吃，ATS 已豁免明文）
2. **应用锁**：FamilyControls 授权 + FamilyActivityPicker 选 App + ManagedSettings 施盾/解盾
3. **健康上报**（Phase 2）：HealthKit 读 Watch 数据推给老电脑，替代 HAE

## 架构

- 工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（project.yml）声明式生成，本地 Windows 只写纯文本
- 构建：GitHub Actions macOS 云机 → unsigned IPA
- 安装：AltStore 免费 Apple ID 侧载（7 天自动续签，AltServer 装主力机）

## 构建

push 到 main 或手动 workflow_dispatch → Actions 产 `AionIOS-unsigned.ipa` → 主力机 AltServer 侧载。

## Phase 2 待办

- [ ] MonitorExtension：eventDidReachThreshold 读 App Group selection 自动施盾（named ManagedSettingsStore）
- [ ] 老电脑：`/api/ios-lock` 命令端点
- [ ] App：上报设备标签+使用时长，BGTaskScheduler 轮询执行远程锁
- [ ] HealthKit 健康上报模块
- [ ] 自定义 shield 锁屏文案（「念宝，时间到啦，去找舟宝聊聊💙」）
