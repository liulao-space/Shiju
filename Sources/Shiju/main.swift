import AppKit

// 菜单栏常驻应用：没有 Dock 图标，所有交互从状态栏的「拾」进入。
// 顶层变量是全局变量，会保持强引用——NSApplication.delegate 本身是弱引用，
// 写成局部变量会被提前释放。
let appDelegate = AppDelegate()

let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
