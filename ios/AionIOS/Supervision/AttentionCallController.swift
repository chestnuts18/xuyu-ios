import UIKit
import AudioToolbox

/// 「此刻，看着我」唤回弹窗 —— iOS 版，对齐安卓 `AttentionCallDialog.java`。
///
/// 触发链（2026-10-29 接通）：
///   徐聿输出 `[COME_HOME:…]` / `[LOOK_AT_ME:分钟|…]`
///   → 服务端 app_supervision_ai.py 落 attention_state.json（快捷指令 gate 用）
///   → 同时入手机命令队列（旧版提前 return 挡掉了，这天改的）
///   → iOS 15 秒轮询拿到 → CommandExecutor.apply → 这里弹窗
///
/// 与安卓的差异（平台硬限制，不是没做）：安卓能在后台 startActivity 强行拉起，
/// iOS 不允许 —— 所以只在 App 活着（前台轮询）时弹；人在别的 App 里时，
/// 仍靠「打开抖音/小红书 → 快捷指令 gate → 跳回 XuYu」那条路。
@MainActor
final class AttentionCallController: UIViewController {
    private static weak var current: AttentionCallController?

    private let messageText: String
    private let actionText: String
    private let card = UIView()
    private let bodyLabel = UILabel()
    private var vibrateTimer: Timer?

    init(message: String, action: String) {
        self.messageText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actionText = action
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func present(message: String, action: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 已经在显示：直接换文案（look_at_me 窗口内可能连发几条），不叠一层
        if let existing = current {
            existing.update(message: text)
            return
        }
        guard let host = AionRepairFileSaver.topViewController() else {
            AionLogger.shared.log("attention present skipped: no host controller")
            return
        }
        // 系统分享面板/图片查看器之上不插队
        if host is UIAlertController || host is UIActivityViewController { return }
        let controller = AttentionCallController(message: text, action: action)
        current = controller
        host.present(controller, animated: true)
    }

    private func update(message: String) {
        bodyLabel.text = message
        card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.card.transform = .identity
        }
        fireHaptics()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.62)
        buildCard()
        fireHaptics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
            options: [.curveEaseOut]
        ) {
            self.card.alpha = 1
            self.card.transform = .identity
        }
    }

    private func buildCard() {
        card.backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.14, alpha: 0.98)
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        // 标题
        let title = UILabel()
        title.text = "此刻，看着我"
        title.font = .systemFont(ofSize: 16, weight: .medium)
        title.textColor = UIColor(white: 1, alpha: 0.62)
        title.textAlignment = .center

        // 正文
        bodyLabel.text = messageText
        bodyLabel.font = .systemFont(ofSize: 27, weight: .bold)
        bodyLabel.textColor = .white
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.alignment = .center
        bodyLabel.attributedText = NSAttributedString(
            string: messageText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 27, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
        )

        // 确认（冰湖蓝 #5B8DEF）
        let confirm = UIButton(type: .system)
        confirm.setTitle("确认", for: .normal)
        confirm.setTitleColor(.white, for: .normal)
        confirm.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        confirm.backgroundColor = UIColor(red: 0x5B / 255.0, green: 0x8D / 255.0, blue: 0xEF / 255.0, alpha: 1)
        confirm.layer.cornerRadius = 16
        confirm.layer.cornerCurve = .continuous
        confirm.translatesAutoresizingMaskIntoConstraints = false
        confirm.heightAnchor.constraint(equalToConstant: 52).isActive = true
        confirm.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, bodyLabel, confirm])
        stack.axis = .vertical
        stack.spacing = 18
        stack.setCustomSpacing(22, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }

    @objc private func confirmTapped() {
        AionLogger.shared.log("attention dismissed action=\(actionText)")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Self.current = nil
        dismiss(animated: true)
    }

    /// 强震对齐安卓 `AttentionCallDialog.java:99-118`（600ms × 2）。
    /// iOS 没有「无限震」的公开 API，这里是两次 warning 触感 + 系统震动，间隔 0.7 秒。
    private func fireHaptics() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrateTimer?.invalidate()
        vibrateTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
            Task { @MainActor in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
