// 功能16: 窗口管理
// 对应: 主窗口、设置窗口、关于窗口的创建与显示
// 优先级: P1

import AppKit

/// 窗口管理器 (功能16)
public final class WindowManager {
    public static let shared = WindowManager()
    
    private var windows: [String: NSWindow] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - 创建主窗口
    public func createMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "仙人指路"
        window.minSize = NSSize(width: 800, height: 600)
        
        register(window: window, id: "main")
        return window
    }
    
    // MARK: - 创建设置窗口
    public func createSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        
        register(window: window, id: "settings")
        return window
    }
    
    // MARK: - 创建关于窗口
    public func createAboutWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于"
        
        register(window: window, id: "about")
        return window
    }
    
    // MARK: - 模块窗口 (功能20)
    public func createModuleWindow(module: String, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 400, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = module
        
        register(window: window, id: "module.\(module)")
        return window
    }
    
    // MARK: - 显示/隐藏窗口
    public func showWindow(id: String) {
        lock.lock()
        let window = windows[id]
        lock.unlock()
        
        window?.makeKeyAndOrderFront(nil)
    }
    
    public func hideWindow(id: String) {
        lock.lock()
        let window = windows[id]
        lock.unlock()
        
        window?.orderOut(nil)
    }
    
    public func closeWindow(id: String) {
        lock.lock()
        let window = windows.removeValue(forKey: id)
        lock.unlock()
        
        window?.close()
    }
    
    // MARK: - 获取窗口
    public func getWindow(id: String) -> NSWindow? {
        lock.lock()
        defer { lock.unlock() }
        return windows[id]
    }
    
    // MARK: - 私有方法
    private func register(window: NSWindow, id: String) {
        lock.lock()
        windows[id] = window
        lock.unlock()
    }
}

// MARK: - 窗口配置
public struct WindowConfiguration {
    public let id: String
    public let title: String
    public let size: NSSize
    public let styleMask: NSWindow.StyleMask
    public let isResizable: Bool
}