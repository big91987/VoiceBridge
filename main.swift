import Cocoa
import ApplicationServices
import IOKit.hid

// MARK: - 双通道说明
// 远控软件（如 UU 远程）在 HID 层就把按键截走，CGEvent 层完全看不到。
// 但公开的 IOHIDManager 监听仍能读到这些按键，因此这里用双通道：
//   上层 CGEventTap —— 能拦则拦（本机场景不脏，空格正常被吞）
//   底层 HID 监听 —— 只读感知（UU 场景兜底触发，代价是漏一个空格到远端）
// 注：HID 层的「过滤/吞掉事件」需要苹果私有授权（entitlement），普通签名拿不到，实测注册成功但回调永不触发，已放弃。

// MARK: - 配置（默认值 = 实测可用组合；改 ~/.voicebridge/config.json 后重启生效）
struct VBConfig: Codable {
    var triggerKeyCode: Int64   // 触发 VoiceBridge 的键（默认 49 = 空格）
    var doubaoKeyCode: Int64    // 唤起豆包语音的键（默认 59 = 左侧 Control）
    var armDelay: Double        // 按住多久才开录（防误触）
    var clipboardWait: Double   // 写剪贴板到按 Cmd+V 的等待（留 UU 同步时间）
    var uuTargetDevice: String  // 只粘到含该设备名的 UU 控制窗口；空 = 当前窗口

    static let `default` = VBConfig(triggerKeyCode: 49, doubaoKeyCode: 59,
                                    armDelay: 0.35, clipboardWait: 1.3, uuTargetDevice: "")
}

let vbConfigDir = NSHomeDirectory() + "/.voicebridge"
let vbConfigPath = vbConfigDir + "/config.yaml"

// 运行期可改：菜单里点选后立即写入 YAML 并生效；手改 YAML 后 1 秒内自动重载
var cfg: VBConfig = VBConfig.default

// 菜单里可选的值
let triggerOptions: [Int64] = [49, 48, 36, 53, 41, 43, 47, 50, 105, 54, 56]
let doubaoOptions:  [Int64] = [59, 62, 58, 61, 105, 96, 97, 98, 100, 101]
let armOptions:     [Int]   = [200, 300, 350, 500, 800]

func saveConfig() {
    let text = """
    # VoiceBridge 配置（改完保存，1 秒内自动重载；菜单里的设置也写进这个文件）
    # 常用键码：
    #   49=空格  48=Tab  36=回车  53=Esc  41=分号  43=逗号  47=句号  50=反引号
    #   59=左Control  62=右Control  58=左Option  61=右Option  54=右Command  55=左Command  56=左Shift
    #   105=F13  103=F11  111=F12  96=F5  97=F6  98=F7  100=F8  101=F9
    triggerKeyCode: \(cfg.triggerKeyCode)
    doubaoKeyCode: \(cfg.doubaoKeyCode)
    armDelay: \(cfg.armDelay)
    clipboardWait: \(cfg.clipboardWait)
    # uuTargetDevice：只粘到窗口内出现该设备名的 UU 控制窗口，留空=粘到当前窗口
    uuTargetDevice: \(cfg.uuTargetDevice)

    """
    try? FileManager.default.createDirectory(atPath: vbConfigDir, withIntermediateDirectories: true)
    try? text.write(toFile: vbConfigPath, atomically: true, encoding: .utf8)
}

func loadConfig() -> VBConfig {
    var c = VBConfig.default
    try? FileManager.default.createDirectory(atPath: vbConfigDir, withIntermediateDirectories: true)
    guard let text = try? String(contentsOfFile: vbConfigPath, encoding: .utf8) else {
        saveConfig()
        return c
    }
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: ":")
        guard parts.count >= 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "triggerKeyCode": if let v = Int64(val) { c.triggerKeyCode = v }
        case "doubaoKeyCode":  if let v = Int64(val) { c.doubaoKeyCode = v }
        case "armDelay":       if let v = Double(val) { c.armDelay = v }
        case "clipboardWait":  if let v = Double(val) { c.clipboardWait = v }
        case "uuTargetDevice": c.uuTargetDevice = val
        default: break
        }
    }
    return c
}

let kVKey: CGKeyCode = 9
let uuBundleID = "com.netease.uuremote"
let uuActivateWait: Double = 0.45

// 递归收集 AX 元素里的文本
func axCollectTexts(_ el: AXUIElement, _ depth: Int, _ acc: inout [String]) {
    if depth > 12 || acc.count > 120 { return }
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
           let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { acc.append(t) }
        }
    }
    var ch: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch) == .success,
       let kids = ch as? [AXUIElement] {
        for k in kids { axCollectTexts(k, depth + 1, &acc) }
    }
}

// 枚举 UU 的控制窗口，返回 (窗口元素, 设备名)
var uuWinCacheAt = Date.distantPast
var uuWinCache: [(AXUIElement, String)] = []

func uuControlWindows(useCache: Bool = false) -> [(AXUIElement, String)] {
    if useCache, Date().timeIntervalSince(uuWinCacheAt) < 2.0 { return uuWinCache }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: uuBundleID).first else { return [] }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement] else { return [] }
    let timeRe = try? NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}:\\d{2}$")
    var out: [(AXUIElement, String)] = []
    for w in wins {
        var texts: [String] = []
        axCollectTexts(w, 0, &texts)
        // 控制窗口的判据：窗口里带“显示屏”，主界面没有
        guard texts.contains(where: { $0.contains("显示屏") }) else { continue }
        for t in texts {
            if t.hasPrefix("control icon") || t.hasPrefix("icon ") || t.hasPrefix("fixed floating") { continue }
            if t.contains("显示屏") || t == "控制中心" { continue }
            if let re = timeRe,
               re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { continue }
            out.append((w, t))
            break
        }
    }
    uuWinCache = out
    uuWinCacheAt = Date()
    return out
}

// 让粘贴路径复用缓存，避免每轮都遍历整棵 AX 树
func uuControlWindowsCached() -> [(AXUIElement, String)] {
    return uuControlWindows(useCache: true)
}

// 修饰键 → CGEventFlags（既用于合成豆包快捷键，也用于识别修饰键型触发键）
let modifierFlags: [Int64: CGEventFlags] = [
    54: .maskCommand,   55: .maskCommand,
    56: .maskShift,     60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate,
    59: .maskControl,   62: .maskControl,
]

func keyName(_ code: Int64) -> String {
    switch code {
    case 49: return "空格"
    case 36: return "回车"
    case 48: return "Tab"
    case 53: return "Esc"
    case 51: return "Delete"
    case 54: return "右侧 Command"
    case 55: return "左侧 Command"
    case 56: return "左侧 Shift"
    case 60: return "右侧 Shift"
    case 58: return "左侧 Option"
    case 61: return "右侧 Option"
    case 59: return "左侧 Control"
    case 62: return "右侧 Control"
    case 41: return "分号"
    case 43: return "逗号"
    case 47: return "句号"
    case 42: return "反斜杠"
    case 50: return "反引号"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    case 105: return "F13"
    default: return "键码\(code)"
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Bridge: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: KeyPanel!
    var textView: NSTextView!
    var caption: NSTextField!
    var statusItem: NSStatusItem!
    var targetSubmenu: NSMenu?
    var passSpaceEvents = 0   // 短按补发的空格要放行，避免被自己的监听再次截获
    var tap: CFMachPort?
    var src: CGEventSource!
    var hidManager: IOHIDManager?
    var lastTriggerAt = Date.distantPast
    var hidOwnsPress = false

    var holding = false
    var recording = false
    var busy = false
    var sawOtherKey = false
    var pendingStart: DispatchWorkItem?
    var ctrlHeld = false
    var tapEnabled = false
    var tapSource: CFRunLoopSource?
    var pollTimer: Timer?
    var configTimer: Timer?
    var lastConfigMTime = Date.distantPast

    // MARK: 启动
    func applicationDidFinishLaunching(_ n: Notification) {
        cfg = loadConfig()
        lastConfigMTime = ((try? FileManager.default.attributesOfItem(atPath: vbConfigPath))?[.modificationDate] as? Date) ?? Date()
        src = CGEventSource(stateID: .hidSystemState)
        buildStatusItem()
        buildPanel()
        checkPermissions()
        setupHIDMonitor()
        installTap()
        startConfigWatcher()
        log("VoiceBridge 已启动 · 按住\(keyName(cfg.triggerKeyCode))说话，唤起豆包用 \(keyName(cfg.doubaoKeyCode)) · 松开自动粘贴到远端")
    }

    func startConfigWatcher() {
        configTimer?.invalidate()
        configTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let m = ((try? FileManager.default.attributesOfItem(atPath: vbConfigPath))?[.modificationDate] as? Date) ?? Date.distantPast
            if m != self.lastConfigMTime {
                self.lastConfigMTime = m
                let old = cfg
                cfg = loadConfig()
                if old.triggerKeyCode != cfg.triggerKeyCode || old.doubaoKeyCode != cfg.doubaoKeyCode
                    || old.armDelay != cfg.armDelay || old.clipboardWait != cfg.clipboardWait {
                    self.rebuildMenu()
                    self.caption.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
                    self.log("[配置] 文件已变更并重载：触发=\(keyName(cfg.triggerKeyCode)) 豆包=\(keyName(cfg.doubaoKeyCode)) 按住=\(cfg.armDelay)s")
                }
            }
        }
    }

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        print("[\(f.string(from: Date()))] \(s)")
        fflush(stdout)
    }

    // MARK: 权限
    func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        log("辅助功能权限: \(trusted ? "已授权" : "未授权")")
        if !trusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        let listen = CGPreflightListenEventAccess()
        log("输入监控权限: \(listen ? "已授权" : "未授权")")
        if !listen {
            _ = CGRequestListenEventAccess()
        }
    }

    // MARK: 菜单栏
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let head = NSMenuItem(title: "按住\(keyName(cfg.triggerKeyCode))说话 · 唤起豆包用 \(keyName(cfg.doubaoKeyCode))", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(NSMenuItem.separator())

        // 触发键
        let trig = NSMenuItem(title: "触发键：\(keyName(cfg.triggerKeyCode))", action: nil, keyEquivalent: "")
        let trigSub = NSMenu()
        for k in triggerOptions {
            let it = NSMenuItem(title: keyName(k), action: #selector(setTriggerKey(_:)), keyEquivalent: "")
            it.tag = Int(k)
            it.target = self
            it.state = Int(k) == Int(cfg.triggerKeyCode) ? .on : .off
            trigSub.addItem(it)
        }
        trig.submenu = trigSub
        menu.addItem(trig)

        // 唤起豆包的键
        let db = NSMenuItem(title: "唤起豆包的键：\(keyName(cfg.doubaoKeyCode))", action: nil, keyEquivalent: "")
        let dbSub = NSMenu()
        for k in doubaoOptions {
            let it = NSMenuItem(title: keyName(k), action: #selector(setDoubaoKey(_:)), keyEquivalent: "")
            it.tag = Int(k)
            it.target = self
            it.state = Int(k) == Int(cfg.doubaoKeyCode) ? .on : .off
            dbSub.addItem(it)
        }
        db.submenu = dbSub
        menu.addItem(db)

        // 按住时长
        let armMs = Int((cfg.armDelay * 1000).rounded())
        let arm = NSMenuItem(title: "按住时长：\(armMs) ms", action: nil, keyEquivalent: "")
        let armSub = NSMenu()
        for ms in armOptions {
            let it = NSMenuItem(title: "\(ms) ms", action: #selector(setArmDelay(_:)), keyEquivalent: "")
            it.tag = ms
            it.target = self
            it.state = armMs == ms ? .on : .off
            armSub.addItem(it)
        }
        arm.submenu = armSub
        menu.addItem(arm)

        // 粘贴目标（UU 多窗口）
        let curTarget = cfg.uuTargetDevice.isEmpty ? "自动（当前窗口）" : cfg.uuTargetDevice
        let tgt = NSMenuItem(title: "粘贴目标：\(curTarget)", action: nil, keyEquivalent: "")
        let tgtSub = NSMenu()
        targetSubmenu = tgtSub
        fillTargetItems(tgtSub)
        tgt.submenu = tgtSub
        menu.addItem(tgt)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开输入监控设置", action: #selector(openIMSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // 填充“粘贴目标”子菜单（打开菜单时刷新，能列出当前的 UU 控制窗口）
    func fillTargetItems(_ sub: NSMenu) {
        sub.removeAllItems()
        let autoIt = NSMenuItem(title: "自动（当前窗口）", action: #selector(setUUTarget(_:)), keyEquivalent: "")
        autoIt.tag = -1
        autoIt.target = self
        autoIt.state = cfg.uuTargetDevice.isEmpty ? .on : .off
        sub.addItem(autoIt)
        let wins = uuControlWindows()
        if wins.isEmpty {
            let none = NSMenuItem(title: "没检测到 UU 控制窗口", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            sub.addItem(NSMenuItem.separator())
            for (_, name) in wins {
                let it = NSMenuItem(title: name, action: #selector(setUUTarget(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = name
                it.state = name == cfg.uuTargetDevice ? .on : .off
                sub.addItem(it)
            }
        }
    }

    @objc func setUUTarget(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            cfg.uuTargetDevice = ""
        } else if let n = sender.representedObject as? String {
            cfg.uuTargetDevice = n
        }
        saveConfig()
        rebuildMenu()
        log("[配置] 粘贴目标 → \(cfg.uuTargetDevice.isEmpty ? "自动" : cfg.uuTargetDevice)")
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let sub = targetSubmenu { fillTargetItems(sub) }
    }

    @objc func setTriggerKey(_ sender: NSMenuItem) {
        cfg.triggerKeyCode = Int64(sender.tag)
        saveConfig()
        rebuildMenu()
        caption.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
        log("[配置] 触发键 → \(keyName(cfg.triggerKeyCode))（键码 \(sender.tag)）")
    }

    @objc func setDoubaoKey(_ sender: NSMenuItem) {
        cfg.doubaoKeyCode = Int64(sender.tag)
        saveConfig()
        rebuildMenu()
        log("[配置] 唤起豆包的键 → \(keyName(cfg.doubaoKeyCode))（键码 \(sender.tag)）")
    }

    @objc func setArmDelay(_ sender: NSMenuItem) {
        cfg.armDelay = Double(sender.tag) / 1000.0
        saveConfig()
        rebuildMenu()
        log("[配置] 按住时长 → \(sender.tag) ms")
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openIMSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: vbConfigPath)) }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: 浮窗
    func buildPanel() {
        let w: CGFloat = 620, h: CGFloat = 112
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.72).cgColor
        container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        let scroll = NSScrollView(frame: NSRect(x: 18, y: 34, width: w - 36, height: h - 50))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = NSFont.systemFont(ofSize: 17)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.isRichText = false
        scroll.documentView = tv
        textView = tv
        container.addSubview(scroll)

        let cap = NSTextField(frame: NSRect(x: 20, y: 10, width: w - 40, height: 20))
        cap.isEditable = false
        cap.isBordered = false
        cap.drawsBackground = false
        cap.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        cap.font = NSFont.systemFont(ofSize: 12)
        cap.stringValue = "按住\(keyName(cfg.triggerKeyCode))说话 · 松开自动粘贴"
        caption = cap
        container.addSubview(cap)

        panel.contentView = container
    }

    func panelOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        let w = panel.frame.width
        return NSPoint(x: f.midX - w / 2, y: f.minY + 40)
    }

    // MARK: HID 层监听（诊断：验证能否在比 CGEvent 更底层看到空格）
    func setupHIDMonitor() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x06
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let callback: IOHIDValueCallback = { _, _, _, value in
            let elem = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(elem)
            let usage = IOHIDElementGetUsage(elem)
            let v = IOHIDValueGetIntegerValue(value)
            guard page == 7 else { return }
            if usage == 44 {
                FileHandle.standardError.write("[HID] 空格\(v != 0 ? "按下" : "抬起")\n".data(using: .utf8)!)
                DispatchQueue.main.async {
                    if v != 0 {
                        if Date().timeIntervalSince(bridge.lastTriggerAt) < 0.3 {
                            bridge.hidOwnsPress = false
                            return
                        }
                        bridge.hidOwnsPress = true
                        bridge.hidTriggerPressed()
                    } else {
                        if bridge.hidOwnsPress {
                            bridge.hidOwnsPress = false
                            bridge.hidTriggerReleased()
                        }
                    }
                }
            }
        }
        IOHIDManagerRegisterInputValueCallback(mgr, callback, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        FileHandle.standardError.write("[HID] 监听注册: \(r == kIOReturnSuccess ? "成功" : "失败 \(r)")\n".data(using: .utf8)!)
        hidManager = mgr
    }

    // MARK: HID 兜底触发（底层只读：远控软件拿走事件后，CGEvent 层看不到，但这里能看到）
    func hidTriggerPressed() {
        guard cfg.triggerKeyCode == 49 else { return }
        log("[HID] 触发键按下")
        beginHold()
    }

    func hidTriggerReleased() {
        guard cfg.triggerKeyCode == 49 else { return }
        log("[HID] 触发键松开")
        cancelPendingStart()
        if recording { stopRecording() }
    }

    // MARK: 事件监听
    func installTap() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let b = Unmanaged<Bridge>.fromOpaque(refcon).takeUnretainedValue()
            return b.handle(proxy: proxy, type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("!! 事件监听创建失败：请在系统设置 → 隐私与安全性 → 输入监控 里授权本 App")
            return
        }
        tap = t
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: t, enable: true)
        tapEnabled = true
        log("事件监听已安装")
    }

    func destroyTap() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
            CFMachPortInvalidate(t)
        }
        tap = nil
        tapSource = nil
        tapEnabled = false
        log("[tap] 已销毁")
    }

    func setTap(_ on: Bool) {
        guard let tap = tap, tapEnabled != on else { return }
        CGEvent.tapEnable(tap: tap, enable: on)
        tapEnabled = on
        log("[tap] \(on ? "开启" : "关闭")")
    }

    func startPollingRelease() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(cfg.triggerKeyCode)) {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.holding = false
                self.log("[轮询] 触发键已松开")
                self.stopRecording()
            }
        }
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        if passSpaceEvents > 0 {
            passSpaceEvents -= 1
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == cfg.triggerKeyCode {
            // 修饰键型触发键（如右侧 Command）：走 flagsChanged，且不吞事件，以免破坏其它组合键
            if type == .flagsChanged, let flag = modifierFlags[code] {
                if event.flags.contains(flag) { beginHold() } else { cancelPendingStart() }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return nil }
                lastTriggerAt = Date()
                beginHold()
                return nil
            }
            if type == .keyUp {
                let wasRecording = recording
                cancelPendingStart()
                if !wasRecording {
                    // 短按（没到按住时长）：补发一个空格，保持轻敲空格的原功能
                    passSpaceEvents = 2
                    let src = CGEventSource(stateID: .hidSystemState)
                    CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
                    log("[短按] 补发空格")
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { sawOtherKey = true }
        return Unmanaged.passUnretained(event)
    }

    func beginHold() {
        guard !holding && !busy else { return }
        holding = true
        sawOtherKey = false
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.holding, !self.sawOtherKey, !self.busy else { return }
            self.startRecording()
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.armDelay, execute: work)
    }

    func cancelPendingStart() {
        if !recording {
            holding = false
            pendingStart?.cancel()
            pendingStart = nil
        }
    }

    // MARK: 合成豆包快捷键（唤起录音）
    func doubaoBarVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let wd = (b["Width"] as? Double) ?? 0
            let ht = (b["Height"] as? Double) ?? 0
            if owner.contains("豆包输入法") { return true }
            if owner.lowercased().contains("doubao") && wd > 80 && wd < 260 && ht > 20 && ht < 70 { return true }
        }
        return false
    }

    func synthDoubao(_ down: Bool) {
        let kc = CGKeyCode(cfg.doubaoKeyCode)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: down) else { return }
        if let flag = modifierFlags[cfg.doubaoKeyCode] {
            // 修饰键：发 flagsChanged，只带这一个修饰位（清掉其它修饰，避免继承物理状态）
            e.type = .flagsChanged
            e.flags = down ? flag : []
        } else {
            // 普通键：发 keyDown / keyUp
            e.type = down ? .keyDown : .keyUp
            e.flags = []
        }
        e.post(tap: .cghidEventTap)
        ctrlHeld = down
        log(down ? "[合成] \(keyName(cfg.doubaoKeyCode)) down → 豆包开始录音"
                 : "[合成] \(keyName(cfg.doubaoKeyCode)) up → 豆包结束录音")
    }

    // MARK: 录音
    func startRecording() {
        guard !recording, !busy else { return }
        recording = true
        destroyTap()
        textView.string = ""
        caption.stringValue = "● 正在听… 说完松开\(keyName(cfg.triggerKeyCode))"
        panel.setFrameOrigin(panelOrigin())
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        log("[开始] 浮窗已抢焦点")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.recording else { return }
            self.log("[诊断] isKey=\(self.panel.isKeyWindow) appActive=\(NSApp.isActive) first=\(type(of: self.panel.firstResponder ?? NSView()))")
            self.synthDoubao(true)
            self.startPollingRelease()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self else { return }
                self.log("[诊断] 豆包录音条: \(self.doubaoBarVisible() ? "已出现" : "没出现")")
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        busy = true
        pollTimer?.invalidate()
        pollTimer = nil
        if ctrlHeld { synthDoubao(false) }
        caption.stringValue = "转写中…"
        log("[结束] 等待豆包出字")
        waitStable { [weak self] text in
            self?.finish(text)
        }
    }

    func waitStable(_ done: @escaping (String) -> Void) {
        var last = ""
        var stable = 0
        var ticks = 0
        func tick() {
            ticks += 1
            let s = textView.string
            if s != last {
                last = s
                stable = 0
            } else {
                stable += 1
            }
            let stableEnough = stable >= 2 && !s.isEmpty
            let tooLong = ticks > 28   // ~7s
            if stableEnough || tooLong {
                done(s)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
    }

    func finish(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 按住分号期间键盘自动重复，会往浮窗里灌一串分号，剥掉开头和结尾的标点
        while let f = clean.first, "；;，,。.、 ".contains(f) { clean.removeFirst() }
        while let l = clean.last, "；;，,。.、 ".contains(l) { clean.removeLast() }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        log("[文本] \(clean.isEmpty ? "(空)" : clean)")
        guard !clean.isEmpty else {
            hidePanel()
            busy = false
            installTap()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clean, forType: .string)
        log("[剪贴板] 已写入 \(clean.count) 字")
        hidePanel()
        guard activateUU() else {
            log("[UU] 目标窗口不可用，跳过本次粘贴")
            busy = false
            installTap()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.clipboardWait) { [weak self] in
            self?.sendCmdV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.busy = false
                self?.installTap()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                let cur = NSPasteboard.general.string(forType: .string) ?? "(空)"
                self.log("[回读] 剪贴板=\(cur.prefix(40)) cc=\(NSPasteboard.general.changeCount)")
            }
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    @discardableResult
    func activateUU() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: uuBundleID).first else {
            log("!! 没找到 UU 远程进程")
            return false
        }
        let target = cfg.uuTargetDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            let wins = uuControlWindowsCached()
            let hit = wins.first { $0.1.contains(target) || target.contains($0.1) }
            if let (win, name) = hit {
                // 只激活 App（不把所有窗口挤到前台），再把命中的窗口置前
                app.activate(options: [])
                let r = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                log("[UU] 目标窗口已置前：\(name) raise=\(r.rawValue)")
                return true
            }
            log("[UU] 没找到设备窗口「\(target)」；当前枚举到 \(wins.count) 个：\(wins.map { $0.1 }.joined(separator: " / "))")
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var wref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wref)
            let wl = (wref as? [AXUIElement]) ?? []
            log("[UU] AX诊断 err=\(err.rawValue) windows=\(wl.count) trusted=\(AXIsProcessTrusted())")
            if let first = wl.first {
                var tt: [String] = []
                axCollectTexts(first, 0, &tt)
                log("[UU] 窗口0文本数=\(tt.count) 前5=\(tt.prefix(5).joined(separator: " | "))")
            }
            return false
        }
        app.activate(options: [])
        log("[UU] 已激活")
        return true
    }

    func sendCmdV() {
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: kVKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(30000)
        up.post(tap: .cghidEventTap)
        log("[粘贴] 已发送 Cmd+V")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bridge = Bridge()
app.delegate = bridge
app.run()
