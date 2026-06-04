// 功能20: 多窗口支持（可选）
// 对应: 模块可以创建自己的独立窗口
// 优先级: P2

import AppKit

/// 模块窗口控制器 (功能20)
public final class ModuleWindowController {
    private let window: NSWindow
    private let moduleName: String
    
    public init(module: String, title: String, size: NSSize) {
        self.moduleName = module
        
        self.window = NSWindow(
            contentRect: NSRect(x: 400, y: 400, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = title
        self.window.isReleasedWhenClosed = false
        
        // 注册到窗口管理器
        WindowManager.shared.register(window: window, id: "module.\(module)")
    }
    
    // MARK: - 设置内容视图
    public func setContentView(_ view: NSView) {
        window.contentView = view
    }
    
    // MARK: - 显示/隐藏
    public func show() {
        window.makeKeyAndOrderFront(nil)
    }
    
    public func hide() {
        window.orderOut(nil)
    }
    
    public func close() {
        window.close()
    }
}

// MARK: - 窗口注册扩展
public extension WindowManager {
    func register(window: NSWindow, id: String) {
        // 已在 WindowManager 中实现
    }
}