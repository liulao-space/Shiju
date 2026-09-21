import AppKit
import Carbon

/// 一个全局快捷键的「配方」：虚拟键码 + 修饰键。
///
/// 存**键码**而不是字符：键码跟键盘布局无关。存字符的话，用户录一个键、
/// 之后换了输入法或键盘布局，快捷键就对不上了。
///
/// 同时刻意做成「不依赖 AppKit 事件对象」的值类型——判据能单测，
/// 而不是只能靠人按一遍键去试（见 Scripts/test-trigger.sh）。
struct HotKeySpec: Equatable {

    /// Carbon 虚拟键码（`kVK_*`）。
    var keyCode: UInt32

    /// Carbon 修饰键位（`cmdKey` / `optionKey` / `controlKey` / `shiftKey`）。
    var modifiers: UInt32

    // MARK: - 修饰键

    static let cmd = UInt32(cmdKey)
    static let opt = UInt32(optionKey)
    static let ctrl = UInt32(controlKey)
    static let shift = UInt32(shiftKey)

    /// 从 AppKit 的修饰键标志转成 Carbon 的位。
    ///
    /// **只读 ⌘⌥⌃⇧ 这四位**，别的位一律不带出去：`modifierFlags` 里还混着
    /// `.numericPad` / `.function` / `.capsLock` 以及一批内部位，它们不是
    /// Carbon 的修饰键常量，混进 `RegisterEventHotKey` 的参数会导致注册失败
    /// （而且失败得看不出原因）。这条约束由下面那串 `contains` 判断本身保证。
    ///
    /// 早先这里还有一句 `flags.intersection(.deviceIndependentFlagsMask)`。
    /// 它是**多余的**——变异自检把这点抓了出来：把那行删掉，所有断言照样全绿，
    /// 说明它对行为毫无影响（`contains` 只查位，不关心多出来的位）。
    /// 与其留一行假装在防什么的代码，不如删掉、由测试锁住真实行为。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.option) { m |= opt }
        if flags.contains(.control) { m |= ctrl }
        if flags.contains(.shift) { m |= shift }
        return m
    }

    /// 至少要有一个「非 ⇧」的修饰键。
    ///
    /// 只按一个字母当全局快捷键，会把那个键从**所有**应用手里抢走——
    /// 用户录完之后连打字都不正常了，而且不会立刻联想到是这里干的。
    /// ⇧ 不算数：⇧A 就是一个大写字母，同样是正常输入。
    static func isValid(modifiers: UInt32) -> Bool {
        modifiers & (cmd | opt | ctrl) != 0
    }

    /// 从一次按键事件构造。修饰键不合法（只有 ⇧ 或没有）时返回 nil。
    static func from(event: NSEvent) -> HotKeySpec? {
        let mods = carbonModifiers(from: event.modifierFlags)
        guard isValid(modifiers: mods) else { return nil }
        return HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    // MARK: - 持久化

    /// `键码-修饰键位`。存 UserDefaults 用。
    /// 空串是合法的「用户主动清掉了这个快捷键」，读回来是 nil。
    var raw: String { "\(keyCode)-\(modifiers)" }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(raw: String) {
        let parts = raw.split(separator: "-")
        guard parts.count == 2,
              let code = UInt32(parts[0]),
              let mods = UInt32(parts[1]),
              Self.isValid(modifiers: mods) else { return nil }
        self.keyCode = code
        self.modifiers = mods
    }

    // MARK: - 显示

    /// macOS 的书写习惯：⌃⌥⇧⌘ 按这个顺序排，键名放最后。
    var display: String {
        var s = ""
        if modifiers & Self.ctrl != 0 { s += "⌃" }
        if modifiers & Self.opt != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        keyNames[code] ?? "键码 \(code)"
    }

    /// 键码 → 显示名。只覆盖「用户会拿来当快捷键」的那些，
    /// 认不出来的退化成「键码 N」而不是猜一个错的名字。
    private static let keyNames: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (code, name) in [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "空格"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Escape, "⎋"),
            (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
            (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ] {
            m[UInt32(code)] = name
        }
        return m
    }()
}

/// 全局快捷键的注册中心。
///
/// 用 Carbon 的 `RegisterEventHotKey` 而不是 NSEvent 键盘监听：
/// 后者需要额外的「输入监控」权限，前者只需要辅助功能权限（我们本来就有）。
///
/// **支持多个快捷键**。早先的实现把回调和事件 handler 存成单例字段，
/// 注册第二个快捷键会把第一个的回调覆盖掉——加第二个的时候会静默只生效一个，
/// 而且症状是「某个快捷键突然不灵了」，很难联想到是注册中心的问题。
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    /// 'SHJQ'
    private static let signature = OSType(0x53484A51)

    private struct Registration {
        let id: UInt32
        var spec: HotKeySpec
        var ref: EventHotKeyRef?
        /// 最近一次装不上的原因。**挂在登记项上**，而不是另开一张按 id 索引的表：
        /// 注册失败的那次早先连登记项都不建，用 id 做 key 会留下一条永远清不掉的
        /// 陈旧记录——用户后来改好了，窗口里还挂着上一轮的报错。
        var failure: String?
        let handler: () -> Void
    }

    private var registrations: [Registration] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var suspended = false

    /// 当前所有「装不上」的原因，按登记顺序排。设置窗口直接显示它。
    ///
    /// 是个数组而不是一个「最近失败」：`applyHotKeys` 会依次处理两个快捷键，
    /// 只留一个字段的话，后一个注册成功会把前一个的失败提示冲掉——
    /// 用户刚设错的偏偏是前一个，看到的就是「没有任何提示」。
    var activeFailures: [String] { registrations.compactMap(\.failure) }

    // MARK: - 登记

    /// 登记一个快捷键，返回它的登记 id。
    ///
    /// **注册不上也会登记下来**（`ref` 为 nil，`failure` 记着原因）。这样它是一个
    /// 「存在但没绑上」的槽位：用户换一个好组合时走 `update` 就地重试，不必重新
    /// 分配 id；失败原因也挂在这个槽位上，设置窗口才读得到。
    ///
    /// 早先这里是「失败就 return nil 且不登记」，而 `nextID` 又没往前走——
    /// 于是两个槽位会共用同一个 id，后一个注册成功就把前一个的失败记录清掉了。
    @discardableResult
    func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        var reg = Registration(id: id, spec: spec, ref: nil, failure: nil, handler: handler)
        if !suspended { rebind(&reg) }
        registrations.append(reg)
        return id
    }

    func unregister(id: UInt32) {
        guard let idx = registrations.firstIndex(where: { $0.id == id }) else { return }
        if let ref = registrations[idx].ref { UnregisterEventHotKey(ref) }
        // 槽位没了，它的失败提示跟着走——不清的话设置窗口会一直挂着
        // 「XX 已被占用」，而用户已经把这个快捷键清空了。
        registrations.remove(at: idx)
    }

    /// 换一个组合。注册不上时**把旧的装回去**再返回 false——
    /// 否则用户改了个冲突的组合，结果是新旧两个都没了。
    @discardableResult
    func update(id: UInt32, spec: HotKeySpec) -> Bool {
        guard let idx = registrations.firstIndex(where: { $0.id == id }) else { return false }
        let oldSpec = registrations[idx].spec
        if let ref = registrations[idx].ref { UnregisterEventHotKey(ref) }
        registrations[idx].ref = nil
        registrations[idx].spec = spec

        if suspended { return true }        // 挂起期间不试，留给 resume
        rebind(&registrations[idx])
        if registrations[idx].failure == nil { return true }

        // 装不上：把旧的装回去，但**保留这次的失败原因**。
        // 回滚那一次如果成功，会把 failure 清成 nil，于是设置窗口里那句
        // 「已被占用」被自己冲掉——用户看不到任何反馈，只会以为改成功了。
        let failure = registrations[idx].failure
        registrations[idx].spec = oldSpec
        rebind(&registrations[idx])
        registrations[idx].failure = failure
        return false
    }

    // MARK: - 录制期间挂起

    /// 录制快捷键时必须把已注册的全部摘掉。
    ///
    /// 否则用户按到「当前已占用」的那个组合时，Carbon 会在系统层把它吃掉，
    /// 录制控件根本收不到 keyDown——表现是「想改快捷键，结果一按就触发了旧功能，
    /// 而且改不了」。
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for i in registrations.indices {
            if let ref = registrations[i].ref {
                UnregisterEventHotKey(ref)
                registrations[i].ref = nil
            }
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for i in registrations.indices where registrations[i].ref == nil {
            rebind(&registrations[i])
        }
    }

    // MARK: - 内部

    fileprivate func fire(id: UInt32) {
        registrations.first(where: { $0.id == id })?.handler()
    }

    /// 按登记项当前的 `spec` 装一次，把结果（ref 与失败原因）写回去。
    private func rebind(_ reg: inout Registration) {
        let (ref, failure) = install(reg.spec, id: reg.id)
        reg.ref = ref
        reg.failure = failure
    }

    /// 装一次。**失败不吞**：原因要一路带到设置窗口去。
    private func install(_ spec: HotKeySpec, id: UInt32) -> (ref: EventHotKeyRef?, failure: String?) {
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode,
                                         spec.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else {
            Diag.note("快捷键 \(spec.display) 注册失败（status \(status)），多半已被别的应用占用")
            return (nil, "\(spec.display) 已被系统或其他应用占用")
        }
        return (ref, nil)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // 事件里带的是 EventHotKeyID，据此派发到对应的回调——
        // 这是「一个 handler 管多个快捷键」的关键。
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr { HotKeyCenter.shared.fire(id: hkID.id) }
            return noErr
        }, 1, &type, nil, &eventHandler)
    }
}

/// 用户可改的偏好。存 UserDefaults。
enum Settings {

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let openPanel = "hotkey.openPanel"
        static let capture = "hotkey.capture"
    }

    /// 默认「打开面板」= ⌥⌘S。
    static let defaultOpenPanel = HotKeySpec(keyCode: UInt32(kVK_ANSI_S),
                                             modifiers: HotKeySpec.opt | HotKeySpec.cmd)

    /// 默认「收录选中文字」= ⌥⌘C（原来硬编码的 ⌥⌘S 让位给打开面板）。
    static let defaultCapture = HotKeySpec(keyCode: UInt32(kVK_ANSI_C),
                                           modifiers: HotKeySpec.opt | HotKeySpec.cmd)

    /// nil = 用户主动清掉了这个快捷键。
    ///
    /// 「没设置过」和「设成空」必须区分开：前者要回落到默认值，
    /// 后者要真的保持没有快捷键。所以判据是 `object(forKey:) == nil`
    /// 而不是 `string(forKey:) == ""`。
    private static func spec(_ key: String, fallback: HotKeySpec) -> HotKeySpec? {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        return HotKeySpec(raw: raw)
    }

    private static func set(_ spec: HotKeySpec?, key: String) {
        defaults.set(spec?.raw ?? "", forKey: key)
    }

    static var openPanelHotKey: HotKeySpec? {
        get { spec(Key.openPanel, fallback: defaultOpenPanel) }
        set { set(newValue, key: Key.openPanel) }
    }

    static var captureHotKey: HotKeySpec? {
        get { spec(Key.capture, fallback: defaultCapture) }
        set { set(newValue, key: Key.capture) }
    }
}
