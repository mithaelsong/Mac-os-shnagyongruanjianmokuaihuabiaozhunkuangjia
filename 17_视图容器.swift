// 功能17: 视图容器
// 对应: 提供一个“空槽”（NSView），让模块把自己的界面贴上去
// 优先级: P1

import AppKit

/// 视图容器 (功能17)
/// 主窗口提供 NSView 空槽，模块把自己的界面贴上去
public final class ViewContainer: NSView {
    
    // MARK: - 槽位定义
    public enum Slot {
        case center      // 主内容区
        case left        // 左侧边栏
        case right       // 右侧边栏
        case top         // 顶部工具栏
        case bottom      // 底部状态栏
        case custom(String)  // 自定义槽位
        
        public var identifier: String {
            switch self {
            case .center: return "slot.center"
            case .left: return "slot.left"
            case .right: return "slot.right"
            case .top: return "slot.top"
            case .bottom: return "slot.bottom"
            case .custom(let id): return "slot.\(id)"
            }
        }
    }
    
    // MARK: - 属性
    private var slots: [String: NSView] = [:]
    private let lock = NSLock()
    
    // MARK: - 初始化
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDefaultSlots()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDefaultSlots()
    }
    
    // MARK: - 安装模块视图
    @discardableResult
    public func installModuleView(_ view: NSView, in slot: Slot) -> Bool {
        let id = slot.identifier
        
        lock.lock()
        
        // 移除旧视图
        if let oldView = slots[id] {
            oldView.removeFromSuperview()
        }
        
        // 安装新视图
        slots[id] = view
        lock.unlock()
        
        // 添加到容器
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        // 发送事件
        EventBus.shared.emit(.moduleViewInstalled, userInfo: [
            "slot": id,
            "view": view
        ])
        
        return true
    }
    
    // MARK: - 移除模块视图
    public func uninstallModuleView(from slot: Slot) {
        let id = slot.identifier
        
        lock.lock()
        let view = slots.removeValue(forKey: id)
        lock.unlock()
        
        view?.removeFromSuperview()
    }
    
    // MARK: - 获取槽位视图
    public func getView(in slot: Slot) -> NSView? {
        lock.lock()
        defer { lock.unlock() }
        return slots[slot.identifier]
    }
    
    // MARK: - 私有方法
    private func setupDefaultSlots() {
        // 创建默认槽位容器
        let centerView = NSView()
        centerView.identifier = NSUserInterfaceItemIdentifier("slot.center")
        slots[Slot.center.identifier] = centerView
        addSubview(centerView)
    }
}

// MARK: - 通知扩展
public extension Notification.Name {
    static let moduleViewInstalled = Notification.Name("com.xianrenzhilu.module.viewInstalled")
    static let moduleViewUninstalled = Notification.Name("com.xianrenzhilu.module.viewUninstalled")
}