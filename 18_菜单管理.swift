// 功能18: 菜单管理
// 对应: 主菜单栏的动态添加/移除（模块可以添加自己的菜单项）
// 优先级: P2

import AppKit
import os

// MARK: - 菜单管理器
/// 菜单管理器 (功能18)
/// 管理主菜单栏中各模块的菜单注册与注销
/// 使用 os_unfair_lock 保证线程安全
public final class MenuManager {
    public static let shared = MenuManager()

    private var moduleMenus: [String: NSMenuItem] = [:]
    private let mainMenu: NSMenu
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "MenuManager")

    /// 私有构造函数，使用应用主菜单
    private init() {
        self.mainMenu = NSApp.mainMenu ?? NSMenu()
    }

    /// 支持注入的构造函数（用于测试）
    /// - Parameter mainMenu: 外部传入的 NSMenu
    public init(mainMenu: NSMenu) {
        self.mainMenu = mainMenu
    }

    // MARK: - 注册模块菜单

    /// 注册模块菜单到主菜单栏
    /// - Parameters:
    ///   - menu: 模块的 NSMenu
    ///   - module: 模块名称（不能为空）
    ///   - title: 菜单标题
    public func registerModuleMenu(_ menu: NSMenu, for module: String, title: String) {
        guard !module.isEmpty else {
            logger.warning("registerModuleMenu失败: 模块名为空")
            return
        }

        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        menuItem.identifier = NSUserInterfaceItemIdentifier("menu.\(module)")

        os_unfair_lock_lock(&lock)
        // 如果已存在，先移除旧菜单
        if let oldItem = moduleMenus[module] {
            mainMenu.removeItem(oldItem)
        }
        moduleMenus[module] = menuItem
        os_unfair_lock_unlock(&lock)

        mainMenu.addItem(menuItem)

        logger.info("已注册菜单 '\(title)' 模块: \(module)")
    }

    // MARK: - 移除模块菜单

    /// 移除指定模块的菜单
    /// - Parameter module: 模块名称
    public func unregisterModuleMenu(for module: String) {
        os_unfair_lock_lock(&lock)
        let menuItem = moduleMenus.removeValue(forKey: module)
        os_unfair_lock_unlock(&lock)

        if let item = menuItem {
            mainMenu.removeItem(item)
            logger.info("已注销模块菜单: \(module)")
        }
    }

    /// 移除所有模块注册的菜单
    public func unregisterAllModuleMenus() {
        os_unfair_lock_lock(&lock)
        let items = Array(moduleMenus.values)
        moduleMenus.removeAll()
        os_unfair_lock_unlock(&lock)

        for item in items {
            mainMenu.removeItem(item)
        }

        logger.info("已注销所有模块菜单 (数量: \(items.count))")
    }

    // MARK: - 菜单项操作

    /// 向指定模块的菜单添加菜单项
    /// - Parameters:
    ///   - item: 菜单项
    ///   - module: 模块名称
    public func addMenuItem(_ item: NSMenuItem, to module: String) {
        os_unfair_lock_lock(&lock)
        let moduleItem = moduleMenus[module]
        os_unfair_lock_unlock(&lock)

        guard let submenu = moduleItem?.submenu else {
            logger.warning("addMenuItem失败: 模块未注册菜单 '\(module)'")
            return
        }

        submenu.addItem(item)
    }

    /// 从指定模块的菜单移除菜单项
    /// - Parameters:
    ///   - item: 菜单项
    ///   - module: 模块名称
    public func removeMenuItem(_ item: NSMenuItem, from module: String) {
        os_unfair_lock_lock(&lock)
        let moduleItem = moduleMenus[module]
        os_unfair_lock_unlock(&lock)

        guard let submenu = moduleItem?.submenu else {
            logger.warning("removeMenuItem失败: 模块未注册菜单 '\(module)'")
            return
        }

        submenu.removeItem(item)
    }

    /// 获取指定模块的所有菜单项
    /// - Parameter module: 模块名称
    /// - Returns: 菜单项数组，若模块未注册菜单则返回空数组
    public func menuItems(for module: String) -> [NSMenuItem] {
        os_unfair_lock_lock(&lock)
        let moduleItem = moduleMenus[module]
        os_unfair_lock_unlock(&lock)

        return moduleItem?.submenu?.items ?? []
    }

    // MARK: - 创建标准菜单项

    /// 创建标准菜单项
    /// - Parameters:
    ///   - title: 标题
    ///   - action: 动作选择器
    ///   - key: 快捷键（如 "q" for Cmd+Q）
    ///   - target: 目标对象
    /// - Returns: 配置好的 NSMenuItem
    public func createMenuItem(title: String, action: Selector?, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    // MARK: - 查询

    /// 检查指定模块是否已注册菜单
    /// - Parameter module: 模块名称
    /// - Returns: 是否已注册
    public func hasMenu(for module: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return moduleMenus[module] != nil
    }

    /// 获取所有已注册菜单的模块名称
    /// - Returns: 模块名称数组
    public func registeredModules() -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(moduleMenus.keys)
    }
}

// MARK: - 菜单扩展协议
/// 模块菜单提供协议
/// 模块实现此协议以向主菜单栏提供菜单
public protocol ModuleMenuProvider {
    /// 提供菜单对象
    func provideMenu() -> NSMenu
    /// 提供菜单标题
    func menuTitle() -> String
}

// MARK: - 测试代码
/// 菜单管理器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `MenuManagerTests.run()`
public enum MenuManagerTests {

    /// 运行所有测试
    public static func run() {
        print("=== 菜单管理器测试 ===")
        testRegisterAndUnregister()
        testUnregisterAll()
        testAddAndRemoveMenuItem()
        testMenuItemsQuery()
        testCreateMenuItem()
        testEmptyModuleName()
        print("\n=== 全部菜单管理器测试通过 ✅ ===")
    }

    // MARK: - 测试1: 注册/注销
    static func testRegisterAndUnregister() {
        print("\n🧪 测试1: 注册与注销")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let menu = NSMenu(title: "TestMenu")
        mm.registerModuleMenu(menu, for: "TestModule", title: "Test")

        guard mm.hasMenu(for: "TestModule") else {
            fatalError("❌ 注册失败: hasMenu注册后应为true")
        }
        guard mm.registeredModules().contains("TestModule") else {
            fatalError("❌ 注册失败: registeredModules应包含TestModule")
        }
        guard mainMenu.items.count == 1 else {
            fatalError("❌ 注册失败: mainMenu应有1个菜单项，实际\(mainMenu.items.count)")
        }

        mm.unregisterModuleMenu(for: "TestModule")
        guard !mm.hasMenu(for: "TestModule") else {
            fatalError("❌ 注销失败: hasMenu注销后应为false")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ 注销失败: mainMenu注销后应为空")
        }

        // 重复注销不应崩溃
        mm.unregisterModuleMenu(for: "TestModule")

        print("✅ Test 1 passed: register/unregister correct")
    }

    // MARK: - 测试2: 注销全部
    static func testUnregisterAll() {
        print("\n🧪 测试2: 注销所有")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        mm.registerModuleMenu(NSMenu(title: "A"), for: "ModuleA", title: "A")
        mm.registerModuleMenu(NSMenu(title: "B"), for: "ModuleB", title: "B")

        guard mainMenu.items.count == 2 else {
            fatalError("❌ 注册失败: mainMenu应有2个菜单项")
        }

        mm.unregisterAllModuleMenus()

        guard mm.registeredModules().isEmpty else {
            fatalError("❌ 注销失败: unregisterAll后registeredModules应为空")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ 注销失败: mainMenu注销后应为空All")
        }

        print("✅ Test 2 passed: unregisterAll correct")
    }

    // MARK: - 测试3: 添加/移除菜单项
    static func testAddAndRemoveMenuItem() {
        print("\n🧪 测试3: 添加与移除菜单项")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let menu = NSMenu(title: "Test")
        mm.registerModuleMenu(menu, for: "TestModule", title: "Test")

        let item = mm.createMenuItem(title: "Action", action: nil, key: "")
        mm.addMenuItem(item, to: "TestModule")

        let items = mm.menuItems(for: "TestModule")
        guard items.count == 1 else {
            fatalError("❌ 查询失败: 期望1个菜单项，实际\(items.count)")
        }
        guard items.first?.title == "Action" else {
            fatalError("❌ 测试失败: 菜单项标题不匹配")
        }

        mm.removeMenuItem(item, from: "TestModule")
        guard mm.menuItems(for: "TestModule").isEmpty else {
            fatalError("❌ 移除失败: 移除后菜单项应为空")
        }

        // 向未注册模块添加项不应崩溃
        mm.addMenuItem(item, to: "NonExistent")

        print("✅ Test 3 passed: add/remove menu item correct")
    }

    // MARK: - 测试4: 菜单项查询
    static func testMenuItemsQuery() {
        print("\n🧪 测试4: 菜单项查询")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        guard mm.menuItems(for: "Ghost").isEmpty else {
            fatalError("❌ 查询失败: 未注册模块的菜单项应为空")
        }
        guard !mm.hasMenu(for: "Ghost") else {
            fatalError("❌ 查询失败: 未注册模块的hasMenu应为false")
        }

        let menu = NSMenu(title: "QueryTest")
        let item1 = mm.createMenuItem(title: "Item1", action: nil)
        let item2 = mm.createMenuItem(title: "Item2", action: nil)
        menu.addItem(item1)
        menu.addItem(item2)

        mm.registerModuleMenu(menu, for: "QueryModule", title: "Query")

        let items = mm.menuItems(for: "QueryModule")
        guard items.count == 2 else {
            fatalError("❌ 查询失败: 期望2个菜单项，实际\(items.count)")
        }

        print("✅ Test 4 passed: menu items query correct")
    }

    // MARK: - 测试5: 创建菜单项
    static func testCreateMenuItem() {
        print("\n🧪 测试5: 创建菜单项")

        let mm = MenuManager(mainMenu: NSMenu())

        let item = mm.createMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        guard item.title == "Quit" else {
            fatalError("❌ 测试失败: 标题不匹配")
        }
        guard item.keyEquivalent == "q" else {
            fatalError("❌ 测试失败: 快捷键不匹配")
        }
        guard item.target === NSApp else {
            fatalError("❌ 测试失败: 目标不匹配")
        }

        print("✅ Test 5 passed: create menu item correct")
    }

    // MARK: - 测试6: 空模块名
    static func testEmptyModuleName() {
        print("\n🧪 测试6: 空模块名")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let countBefore = mm.registeredModules().count
        mm.registerModuleMenu(NSMenu(), for: "", title: "Empty")
        let countAfter = mm.registeredModules().count

        guard countBefore == countAfter else {
            fatalError("❌ 边界失败: 空模块名不应添加菜单")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ 边界失败: mainMenu应保持为空")
        }

        print("✅ Test 6 passed: empty module name handled correctly")
    }
}
