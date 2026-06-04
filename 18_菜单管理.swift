// 功能18: 菜单管理
// 对应: 主菜单栏的动态添加/移除（模块可以添加自己的菜单项）
// 优先级: P2

import AppKit

/// 菜单管理器 (功能18)
public final class MenuManager {
    public static let shared = MenuManager()
    
    private var moduleMenus: [String: NSMenuItem] = [:]
    private let mainMenu: NSMenu
    private let lock = NSLock()
    
    private init() {
        self.mainMenu = NSApp.mainMenu ?? NSMenu()
    }
    
    // MARK: - 注册模块菜单
    public func registerModuleMenu(_ menu: NSMenu, for module: String, title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        menuItem.identifier = NSUserInterfaceItemIdentifier("menu.\(module)")
        
        lock.lock()
        moduleMenus[module] = menuItem
        lock.unlock()
        
        // 添加到主菜单
        mainMenu.addItem(menuItem)
        
        LogSystem.shared.log(level: .info, category: "MenuManager",
                            message: "Registered menu for module: \(module)")
    }
    
    // MARK: - 移除模块菜单
    public func unregisterModuleMenu(for module: String) {
        lock.lock()
        let menuItem = moduleMenus.removeValue(forKey: module)
        lock.unlock()
        
        if let item = menuItem {
            mainMenu.removeItem(item)
        }
    }
    
    // MARK: - 添加菜单项
    public func addMenuItem(_ item: NSMenuItem, to module: String, in menu: String? = nil) {
        // 找到模块的菜单
        lock.lock()
        let moduleItem = moduleMenus[module]
        lock.unlock()
        
        if let submenu = moduleItem?.submenu {
            submenu.addItem(item)
        }
    }
    
    // MARK: - 创建标准菜单项
    public func createMenuItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        return item
    }
}

// MARK: - 菜单扩展协议
public protocol ModuleMenuProvider {
    func provideMenu() -> NSMenu
    func menuTitle() -> String
}