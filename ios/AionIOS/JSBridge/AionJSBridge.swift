import Foundation
import WebKit
import UIKit

/// JS 桥：网页 ↔ 原生。
/// 网页经 window.__aionCall(bridge, action, args) 进原生；原生经 __aionBridgeDispatch 推缓存/事件。
/// 注入脚本定义 window.AionBle / AionHealthKit / AionLocation / AionAppSupervision。
/// 玩具回调走 chat.js 自建的 window.toyNativeBle（网页零改动）。
@MainActor
final class AionJSBridge {
    static let shared = AionJSBridge()

    /// WKScriptMessageHandler 名字（注入脚本 postMessage 用）
    static let handlerName = "aionBridge"

    weak var webView: WKWebView?
    private init() {}

    // MARK: - 注入脚本（atDocumentStart + 全 frame，子页 iframe 也要桥）

    static let injectScript = """
    (function(){
      // API 基址（2026-08-25 网页资源打包）：本地 aionres 页面无 location.host，
      // 所有 WS/fetch 绝对化都靠它；原生探测切换候选后经 cache 推送全 frame 更新。
      window.AION_API_BASE = window.AION_API_BASE || '{{API_BASE}}';
      // Aion 页面全同源：桥状态统一挂 top window，跨 frame 共享 pending/缓存/事件。
      // 健康/监管页从聊天 sidebar 打开时是 iframe 子页——若不共享，子页的 promise
      // 永远等不到原生回执（evaluateJavaScript 只打到 main frame）。
      var root = window;
      try {
        if (window.top && window.top !== window) { root = window.top; }
      } catch (e) { root = window; }   // 沙箱拒绝访问 top 时降级为本 frame

      function linkFrame(w, r) {
        w.__aionCall = r.__aionCall;
        w.__aionResolve = r.__aionResolve;
        w.__aionBridgeDispatch = r.__aionBridgeDispatch;
        w.__aionSyncCache = r.__aionSyncCache;
        w.AionBle = r.AionBle;
        w.AionHealthKit = r.AionHealthKit;
        w.AionLocation = r.AionLocation;
        w.AionAppSupervision = r.AionAppSupervision;
        w.AionCamera = r.AionCamera;
        w.AionAudio = r.AionAudio;
        w.AionVideo = r.AionVideo;
        w.AionPhoneCamera = r.AionPhoneCamera;
        w.AionStatusBar = r.AionStatusBar;
      }

      if (root.__aionBridgeInstalled) { linkFrame(window, root); return; }
      root.__aionBridgeInstalled = true;

      // 原生推的同步缓存（网页同步读；更新时派发事件）
      root.__aionSyncCache = {};

      root.__aionBridgeDispatch = function(name, payload) {
        try {
          if (name === 'cache') {
            Object.assign(root.__aionSyncCache, payload || {});
            if (payload && payload.apiBase) {
              root.AION_API_BASE = payload.apiBase;
              for (var fi = 0; fi < root.frames.length; fi++) {
                try { root.frames[fi].AION_API_BASE = payload.apiBase; } catch(e) {}
              }
            }
          }
          var evtName = (name === 'cache') ? 'aion-cache-updated' : 'aion-event-' + name;
          root.dispatchEvent(new CustomEvent(evtName, {detail: payload}));
          // 同源子 frame 也派发（iframe 页面的监听者才能收到）
          for (var i = 0; i < root.frames.length; i++) {
            try { root.frames[i].dispatchEvent(new CustomEvent(evtName, {detail: payload})); } catch(e) {}
          }
        } catch(e) {}
      };

      // JS→原生：postMessage + promise 封装（30 秒兜底超时）
      var reqSeq = 0, pending = {};
      root.__aionCall = function(bridge, action, args) {
        var id = ++reqSeq;
        try {
          window.webkit.messageHandlers.aionBridge.postMessage({id:id, bridge:bridge, action:action, args:args || {}});
        } catch(e) { return Promise.resolve(undefined); }
        return new Promise(function(resolve){
          pending[id] = resolve;
          setTimeout(function(){ if (pending[id]) { delete pending[id]; resolve(undefined); } }, 30000);
        });
      };
      root.__aionResolve = function(id, result) {
        if (pending[id]) { pending[id](result); delete pending[id]; }
      };

      // 玩具：复用安卓 window.AionBle 语义（chat.js 已有兼容层，网页零改动）
      root.AionBle = {
        connect: function(){ return root.__aionCall('ble','connect'); },
        disconnect: function(){ return root.__aionCall('ble','disconnect'); },
        sendData: function(hex){ return root.__aionCall('ble','sendData',{hex:hex}); },
        isConnected: function(){ return !!root.__aionSyncCache.bleConnected; }
      };

      // 健康
      root.AionHealthKit = {
        getAuthStatus: function(){ return root.__aionCall('health','getAuthStatus'); },
        requestAuth: function(){ return root.__aionCall('health','requestAuth'); },
        isAuthorized: function(){ return !!root.__aionSyncCache.healthAuthorized; }
      };

      // 定位
      root.AionLocation = {
        getStatus: function(){ return root.__aionCall('location','getStatus'); },
        start: function(){ return root.__aionCall('location','start'); },
        stop: function(){ return root.__aionCall('location','stop'); },
        statusText: function(){ return root.__aionSyncCache.locationStatus || ''; }
      };

      // 监管：同步读缓存（返回 JSON 字符串，对齐安卓桥语义）+ 异步变更
      root.AionAppSupervision = {
        platform: 'ios',
        call: function(method, params){ return root.__aionCall('supervision', method, params || {}); },
        getSnapshot: function(){ return JSON.stringify(root.__aionSyncCache.supervisionSnapshot || null); },
        getEmergencyGate: function(){ return JSON.stringify(root.__aionSyncCache.emergencyGate || null); },
        getDeviceInfo: function(){ return {deviceId: root.__aionSyncCache.deviceId || '', platform: 'ios'}; }
      };

      // 摄像头（对齐安卓 CameraBridge 契约）：帧/拍照/状态走 prompt 同步通道——
      // 网页 rAF 每帧同步读 getFrame()，WKWebView 无原生同步桥，prompt 是唯一同步路
      function aionSync(cmd){ try { return prompt('__aion_sync:' + cmd) || ''; } catch(e){ return ''; } }
      root.AionCamera = {
        start: function(facing){ return root.__aionCall('camera','start',{facing:facing}); },
        stop: function(){ return root.__aionCall('camera','stop'); },
        flip: function(){ return root.__aionCall('camera','flip'); },
        setZoom: function(z){ return root.__aionCall('camera','setZoom',{zoom:z}); },
        getFrame: function(){ return aionSync('camera:getFrame'); },
        capture: function(){ return aionSync('camera:capture'); },
        isRunning: function(){ return aionSync('camera:isRunning') === '1'; },
        getFacing: function(){ return aionSync('camera:getFacing'); },
        getLastFrameAt: function(){ return parseFloat(aionSync('camera:getLastFrameAt')) || 0; },
        getRotatedWidth: function(){ return parseInt(aionSync('camera:getRotatedWidth')) || 0; },
        getRotatedHeight: function(){ return parseInt(aionSync('camera:getRotatedHeight')) || 0; }
      };

      // 麦克风：帧由原生每 40ms 主动推 onAionAudioChunk + _voiceNativeOnChunk
      root.AionAudio = {
        start: function(){ return root.__aionCall('audio','start'); },
        stop: function(){ return root.__aionCall('audio','stop'); },
        isRecording: function(){ return !!root.__aionSyncCache.audioRecording; }
      };

      // 录视频：stopRecord 同步返回整段 MP4 base64（契约如此）
      root.AionVideo = {
        startRecord: function(w, h){ return root.__aionCall('video','startRecord',{w:w,h:h}); },
        stopRecord: function(){ return aionSync('video:stopRecord'); },
        cancel: function(){ return root.__aionCall('video','cancel'); }
      };

      // 远程查岗拍照（对齐安卓 AionPhoneCamera 契约；iOS 前台降级版）
      root.AionPhoneCamera = {
        arm: function(facing, zoom){ return root.__aionCall('phonecam','arm',{facing:facing,zoom:zoom}); },
        disarm: function(){ return root.__aionCall('phonecam','disarm'); },
        requestPreview: function(facing, zoom){ return root.__aionCall('phonecam','requestPreview',{facing:facing,zoom:zoom}); },
        setPreviewVisible: function(v){ return root.__aionCall('phonecam','setPreviewVisible',{visible:v}); },
        stopPreview: function(){ return root.__aionCall('phonecam','stopPreview'); },
        getPreviewFrame: function(){ return root.__aionSyncCache.phonePreviewFrame || ''; },
        getCapabilities: function(){ return root.__aionSyncCache.phoneCamCaps || '{}'; }
      };

      // 状态栏深浅色（chat.js:5380 主题联动）
      root.AionStatusBar = {
        setBarStyle: function(theme){ return root.__aionCall('statusbar','setBarStyle',{theme:theme}); }
      };

      linkFrame(window, root);
    })();
    """

    // MARK: - 网页 → 原生

    func handle(_ message: WKScriptMessage) {
        guard let req = BridgeRequest(message: message) else { return }
        webView = message.webView ?? webView
        Task {
            let result = await self.dispatch(req)
            await self.resolve(id: req.id, result: result)
        }
    }

    private func resolve(id: Int, result: Any?) async {
        guard let webView else { return }
        var js: String
        if let result, JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result),
           let json = String(data: data, encoding: .utf8) {
            js = "window.__aionResolve(\(id), \(json))"
        } else {
            js = "window.__aionResolve(\(id), undefined)"
        }
        try? await webView.evaluateJavaScript(js)
    }

    private func dispatch(_ req: BridgeRequest) async -> Any? {
        switch req.bridge {
        case "ble":
            return await ToyBLEManager.shared.handle(action: req.action, args: req.args)

        case "health":
            switch req.action {
            case "getAuthStatus":
                return [
                    "authorized": AionHealthKit.shared.authorized,
                    "lastUploadInfo": AionHealthKit.shared.lastUploadInfo,
                ]
            case "requestAuth":
                await AionHealthKit.shared.requestAuthorization()
                pushCache()
                return ["authorized": AionHealthKit.shared.authorized]
            default:
                return nil
            }

        case "location":
            switch req.action {
            case "getStatus":
                return [
                    "auth": AionLocation.shared.authStateText,
                    "lastUpload": AionLocation.shared.lastUploadInfo,
                ]
            case "start":
                AionLocation.shared.start()
                pushCache()
                return ["auth": AionLocation.shared.authStateText]
            case "stop":
                AionLocation.shared.stop()
                pushCache()
                return ["auth": AionLocation.shared.authStateText]
            default:
                return nil
            }

        case "supervision":
            return await SupervisionBridge.shared.handle(action: req.action, args: req.args)

        case "camera":
            return await AionCameraModule.shared.handle(action: req.action, args: req.args)

        case "audio":
            return await AionAudioModule.shared.handle(action: req.action, args: req.args)

        case "video":
            return await AionVideoModule.shared.handle(action: req.action, args: req.args)

        case "phonecam":
            return await AionPhoneCameraModule.shared.handle(action: req.action, args: req.args)

        case "statusbar":
            // 主题联动状态栏：亮色主题 → 深色文字（冰湖蓝白底），反之浅色
            let theme = (req.args["theme"] as? String) ?? "light"
            StatusBarStyleController.apply(theme)
            return true

        default:
            return nil
        }
    }

    // MARK: - 原生 → 网页

    /// 推状态缓存到网页（同步读 + aion-cache-updated 事件）
    func pushCache() {
        guard let webView else { return }
        let cache: [String: Any] = [
            "apiBase": APIClient.shared.baseURL.absoluteString,
            "deviceId": DeviceIdentity.deviceId,
            "healthAuthorized": AionHealthKit.shared.authorized,
            "healthUploadInfo": AionHealthKit.shared.lastUploadInfo,
            "locationStatus": AionLocation.shared.authStateText,
            "familyAuth": (LockModel.shared.authorizationStatus == .approved) ? "approved" : "denied",
            "bleConnected": ToyBLEManager.shared.isConnected,
            "supervisionSnapshot": CommandExecutor.shared.buildSnapshotPayload(
                groups: CommandExecutor.shared.loadGroups()
            ),
            "emergencyGate": EmergencyGate.shared.gate,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cache),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.__aionBridgeDispatch && window.__aionBridgeDispatch('cache', \(json))"
        )
    }

    /// 调 chat.js 自建的 window.toyNativeBle 回调（onConnected/onDisconnected/onError/onLog）
    func callToyNative(_ fn: String, arg: String? = nil) {
        guard let webView else { return }
        let argJs = arg.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? ""
        webView.evaluateJavaScript(
            "window.toyNativeBle && window.toyNativeBle.\(fn) && window.toyNativeBle.\(fn)(\(argJs))"
        )
    }

    /// 调网页全局回调（onAionPhoneCameraCaptureState 等）
    func callWebFunction(_ fn: String, arg: String? = nil) {
        guard let webView else { return }
        let argJs = arg.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? ""
        webView.evaluateJavaScript(
            "window.\(fn) && window.\(fn)(\(argJs))"
        )
    }

    /// 部分键更新同步缓存（摄像头状态/查岗预览帧等高频小推）
    func pushCachePartial(_ dict: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.__aionBridgeDispatch && window.__aionBridgeDispatch('cache', \(json))"
        )
    }

    /// 推音频帧：主 frame + 全部子 frame 的 onAionAudioChunk / _voiceNativeOnChunk
    /// （voice-call/chatroom 可能跑在 iframe 里，原生 evaluateJavaScript 只打主 frame）
    func pushAudioChunk(_ b64: String) {
        guard let webView else { return }
        webView.evaluateJavaScript("""
        (function(b64){
          var fns=['onAionAudioChunk','_voiceNativeOnChunk'];
          for(var i=0;i<fns.length;i++){
            var fn=window[fns[i]];
            if(typeof fn==='function'){ try{fn(b64);}catch(e){} }
            for(var j=0;j<window.frames.length;j++){
              try{ var w=window.frames[j];
                if(typeof w[fns[i]]==='function'){ w[fns[i]](b64); } }catch(e){}
            }
          }
        })('\(b64)')
        """)
    }
}

/// 状态栏深浅色（网页主题联动）
enum StatusBarStyleController {
    static func apply(_ theme: String) {
        let style: UIUserInterfaceStyle = (theme == "dark") ? .dark : .light
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    window.rootViewController?.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
