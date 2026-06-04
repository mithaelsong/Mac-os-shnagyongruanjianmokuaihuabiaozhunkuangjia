// 功能19: 工具栏管理
// 对应: 模块可以添加工具栏按钮
// 优先级: P2

import AppKit

/// 工具栏项定义
public struct ToolbarItemDefinition {
    public let identifier: String
    public let label: String
    public let icon: NSImage?
    public let action: () -> Void
    public let tooltip: String?
    
    public init(identifier: String, label: String, icon: NSImage? = nil,
                tooltip: String? = nil, action: @escaping () -> Void) {
        self.identifier = identifier
        self.label = label
        self.icon = icon
        self.action = action
        self.tooltip = tooltip
    }
}

/// 工具栏管理器 (功能19)
public final class ToolbarManager: NSObject, NSToolbarDelegate {
    public static let shared = ToolbarManager()
    
    private var items: [String: ToolbarItemDefinition] = [:]
    private var moduleItems: [String: [String]] = [:] // module -> item IDs
    private let lock = NSLock()
    
    private var toolbar: NSToolbar?
    
    private override init() {}
    
    // MARK: - 设置工具栏
    public func setupToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        
        window.toolbar = toolbar
        self.toolbar = toolbar
    }
    
    // MARK: - 注册工具栏项
    public func registerItem(_ definition: ToolbarItemDefinition, for module: String) {
        lock.lock()
        items[definition.identifier] = definition
        moduleItems[module, default: []].append(definition.identifier)
        lock.unlock()
        
        // 刷新工具栏
        toolbar?.insertItem(withItemIdentifier: NSToolbarItem.Identifier(definition.identifier), at: items.count - 1)
    }
    
    // MARK: - 移除模块的工具栏项
    public func unregisterItems(for module: String) {
        lock.lock()
        let ids = moduleItems.removeValue(forKey: module) ?? []
        for id in ids {
            items.removeValue(forKey: id)
        }
        lock.unlock()
        
        // 刷新工具栏
        for id in ids {
            toolbar?.removeItem(at: toolbar?.items.firstIndex(where: { $0.itemIdentifier.rawValue == id }) ?? 0)
        }
    }
    
    // MARK: - NSToolbarDelegate
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        
        lock.lock()
        let definition = items[itemIdentifier.rawValue]
        lock.unlock()
        
        guard let def = definition else { return nil }
        
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = def.label
        item.toolTip = def.tooltip
        
        if let icon = def.icon {
            item.image = icon
        }
        
        item.target = self
        item.action = #selector(handleToolbarAction(_:))
        item.tag = itemIdentifier.rawValue.hashValue
        
        return item
    }
    
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        lock.lock()
        let ids = items.keys.map { NSToolbarItem.Identifier($0) }
        lock.unlock()
        return ids
    }
    
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }
    
    // MARK: - 动作处理
    @objc private func handleToolbarAction(_ sender: NSToolbarItem) {
        let id = sender.itemIdentifier.rawValue
        
        lock.lock()
        let definition = items[id]
        lock.unlock()
        
        definition?.action()
    }
}