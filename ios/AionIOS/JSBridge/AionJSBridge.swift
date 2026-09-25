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
      // 隧道 token（{{AION_TOKEN}} 占位由原生注入时替换）。CF 候选下 WKWebView 的
      // fetch/XHR 不发送原生注入的 Cookie（导航会带、fetch 不带——iOS 14+ 平台行为，
      // credentials 选项不可靠，2026-08-25 实测 /api/* 全 401 实锤）→ 同源请求
      // 显式补 X-Aion-Token 头：同源自定义头是简单请求、无预检、WebKit 必发。
      // LAN/TS 下 token 为空不补。⚠️ 必须在 __aionBridgeInstalled 检查之前
      //（隐藏 iframe 先注入挂标记，主 frame 后注入会跳过——打包期踩过的坑）。
      var __aionTok = '{{AION_TOKEN}}';
      try {
        if (!window.__aionTokPatched) {
          window.__aionTokPatched = true;
          var _f0 = window.fetch;
          window.fetch = function(u, o) {
            if (__aionTok && (typeof u !== 'string' || u.indexOf('/') === 0)) {
              o = o || {};
              try {
                // ⚠️ 无条件覆盖：页面自己的 fetch 拦截器在外层先执行，
                // 会先塞进 LAN token——「已有头就不覆盖」会让它抢先
                //（2026-08-25 401 实锤）。内层 wrapper 最后定稿隧道 token。
                var hs = new Headers(o.headers || {});
                hs.set('X-Aion-Token', __aionTok);
                o.headers = hs;
              } catch(e) {}
            }
            return _f0.call(window, u, o);
          };
          var _xo = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(m, u) {
            var r = _xo.apply(this, arguments);
            if (__aionTok) {
              try { this.setRequestHeader('X-Aion-Token', __aionTok); } catch(e) {}
            }
            return r;
          };
          // WS：query 的 token 换成隧道 token（服务器 WS 裁决认 query/header/Cookie 三路，
          // 页面自带的 LAN token 在隧道上无效）
          var _WS = window.WebSocket;
          window.WebSocket = function(u, p) {
            if (__aionTok && typeof u === 'string') {
              try {
                var _u = new URL(u, window.location.href);
                _u.searchParams.set('token', __aionTok);
                u = _u.toString();
              } catch(e) {}
            }
            return new _WS(u, p);
          };
        }
      } catch(eTok) {}
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
        w.AionRoute = r.AionRoute;
        w.AionAlarm = r.AionAlarm;
        w.AionSong = r.AionSong;
      }

      if (root.__aionBridgeInstalled) { linkFrame(window, root); return; }
      root.__aionBridgeInstalled = true;

      // 原生推的同步缓存（网页同步读；更新时派发事件）
      root.__aionSyncCache = {};

      root.__aionBridgeDispatch = function(name, payload) {
        try {
          if (name === 'cache') {
            Object.assign(root.__aionSyncCache, payload || {});
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
        getCurrentPosition: function(){ return root.__aionCall('location','getCurrentPosition'); },
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

      // 线路选择（2026-09-21，设置页卡片）：自动 / 在家 / Tailscale / 隧道。
      // get → {preference, base, options}；set(value) → 原生立即切换并重载页面。
      root.AionRoute = {
        get: function(){ return root.__aionCall('route','get'); },
        set: function(v){ return root.__aionCall('route','set',{value:v}); }
      };

      // 系统闹钟（AlarmKit，iOS 26+）：网页可手动触发同步 / 查状态
      root.AionAlarm = {
        sync: function(){ return root.__aionCall('alarm','sync'); },
        status: function(){ return root.__aionCall('alarm','status'); },
        cancelAll: function(){ return root.__aionCall('alarm','cancelAll'); }
      };

      // 原生放歌（2026-09-22）：闹铃到点时把徐聿点的歌直接放出来（锁屏也放得出来）
      root.AionSong = {
        play: function(path, title, artist){ return root.__aionCall('song','play',{path:path,title:title,artist:artist}); },
        stop: function(){ return root.__aionCall('song','stop'); },
        status: function(){ return root.__aionCall('song','status'); }
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
        if let result {
            // Swift Bool/数字不是 JSONSerialization 认可的对象（isValidJSONObject 返回 false），
            // 之前 start()/stop() 等布尔返回全走 else 分支 → 网页拿到 undefined（2026-09-07
            // 「相机/麦克风有允许还失败」根因）。Bool 用插值直接出 true/false 字面量。
            if let b = result as? Bool {
                js = "window.__aionResolve(\(id), \(b))"
            } else if let n = result as? NSNumber {
                js = "window.__aionResolve(\(id), \(n))"
            } else if JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result),
                      let json = String(data: data, encoding: .utf8) {
                js = "window.__aionResolve(\(id), \(json))"
            } else {
                js = "window.__aionResolve(\(id), undefined)"
            }
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
            case "getCurrentPosition":
                // 2026-09-25 网页「同步位置」：要一次实时坐标（1-3 秒）。
                // 失败返回 error 字段，网页据此回退到旧的远程请求路径。
                do {
                    let loc = try await AionLocation.shared.currentPosition()
                    return [
                        "lng": loc.coordinate.longitude,
                        "lat": loc.coordinate.latitude,
                        "accuracy": max(0, loc.horizontalAccuracy),
                    ]
                } catch {
                    return ["error": error.localizedDescription]
                }
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

        case "route":
            switch req.action {
            case "get":
                return APIClient.shared.routeInfo()
            case "set":
                // 先探路再切（3s），把结果回给网页：通了页面会重载，不通则原地
                // 不动 + 提示原因（2026-09-21：切没开的 TS 会卡 60 秒加载超时）
                let value = (req.args["value"] as? String) ?? "auto"
                return await APIClient.shared.requestPreference(RoutePreference(rawValue: value) ?? .auto)
            default:
                return nil
            }

        case "alarm":
            // AlarmKit 系统闹钟（iOS 26+）。低版本返回 supported=false，网页据此隐藏入口。
            guard #available(iOS 26.0, *) else { return ["supported": false] }
            switch req.action {
            case "sync":
                return await AionAlarmKit.shared.sync(reason: "bridge")
            case "status":
                return AionAlarmKit.shared.status()
            case "cancelAll":
                return AionAlarmKit.shared.cancelAll()
            default:
                return nil
            }

        case "song":
            // 原生放歌（2026-09-22）：闹铃到点时把徐聿点的歌放出来，锁屏也放得出来
            switch req.action {
            case "play":
                let path = (req.args["path"] as? String) ?? ""
                guard !path.isEmpty else { return ["ok": false, "error": "path required"] }
                AionSongPlayer.shared.play(
                    path: path,
                    title: req.args["title"] as? String,
                    artist: req.args["artist"] as? String
                )
                return ["ok": true]
            case "stop":
                AionSongPlayer.shared.stop()
                return ["ok": true]
            default:
                return AionSongPlayer.shared.status()
            }

        default:
            return nil
        }
    }

    // MARK: - 原生 → 网页

    /// 推状态缓存到网页（同步读 + aion-cache-updated 事件）
    func pushCache() {
        guard let webView else { return }
        let cache: [String: Any] = [
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

    /// 同上，但参数是**真正的布尔字面量**。
    /// ⚠️ callWebFunction 会把任何参数包成字符串，而 JS 里 `!!'false'` 恒为 true ——
    /// 布尔语义（onAionAppForegroundChanged）必须走这条，否则「切到后台」会被网页当成「在前台」。
    func callWebFunctionBool(_ fn: String, _ value: Bool) {
        guard let webView else { return }
        webView.evaluateJavaScript(
            "window.\(fn) && window.\(fn)(\(value ? "true" : "false"))"
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
