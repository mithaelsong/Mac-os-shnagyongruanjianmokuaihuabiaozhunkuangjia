// 功能18: 菜单管理
// 对应: 主菜单栏的动态添加/移除（模块可以添加自己的菜单项）
// 优先级: P2

import AppKit
import os.lock

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
            logger.warning("registerModuleMenu failed: module name is empty")
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

        logger.info("Registered menu '\(title)' for module: \(module)")
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
            logger.info("Unregistered menu for module: \(module)")
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

        logger.info("Unregistered all module menus (count: \(items.count))")
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
            logger.warning("addMenuItem failed: no menu registered for module '\(module)'")
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
            logger.warning("removeMenuItem failed: no menu registered for module '\(module)'")
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
        print("=== MenuManager Tests ===")
        testRegisterAndUnregister()
        testUnregisterAll()
        testAddAndRemoveMenuItem()
        testMenuItemsQuery()
        testCreateMenuItem()
        testEmptyModuleName()
        print("\n=== All MenuManager Tests Passed ✅ ===")
    }

    // MARK: - 测试1: 注册/注销
    static func testRegisterAndUnregister() {
        print("\n🧪 Test 1: Register & Unregister")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let menu = NSMenu(title: "TestMenu")
        mm.registerModuleMenu(menu, for: "TestModule", title: "Test")

        guard mm.hasMenu(for: "TestModule") else {
            fatalError("❌ hasMenu should be true after register")
        }
        guard mm.registeredModules().contains("TestModule") else {
            fatalError("❌ registeredModules should contain TestModule")
        }
        guard mainMenu.items.count == 1 else {
            fatalError("❌ mainMenu should have 1 item, got \(mainMenu.items.count)")
        }

        mm.unregisterModuleMenu(for: "TestModule")
        guard !mm.hasMenu(for: "TestModule") else {
            fatalError("❌ hasMenu should be false after unregister")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ mainMenu should be empty after unregister")
        }

        // 重复注销不应崩溃
        mm.unregisterModuleMenu(for: "TestModule")

        print("✅ Test 1 passed: register/unregister correct")
    }

    // MARK: - 测试2: 注销全部
    static func testUnregisterAll() {
        print("\n🧪 Test 2: Unregister All")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        mm.registerModuleMenu(NSMenu(title: "A"), for: "ModuleA", title: "A")
        mm.registerModuleMenu(NSMenu(title: "B"), for: "ModuleB", title: "B")

        guard mainMenu.items.count == 2 else {
            fatalError("❌ mainMenu should have 2 items")
        }

        mm.unregisterAllModuleMenus()

        guard mm.registeredModules().isEmpty else {
            fatalError("❌ registeredModules should be empty after unregisterAll")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ mainMenu should be empty after unregisterAll")
        }

        print("✅ Test 2 passed: unregisterAll correct")
    }

    // MARK: - 测试3: 添加/移除菜单项
    static func testAddAndRemoveMenuItem() {
        print("\n🧪 Test 3: Add & Remove Menu Item")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let menu = NSMenu(title: "Test")
        mm.registerModuleMenu(menu, for: "TestModule", title: "Test")

        let item = mm.createMenuItem(title: "Action", action: nil, key: "")
        mm.addMenuItem(item, to: "TestModule")

        let items = mm.menuItems(for: "TestModule")
        guard items.count == 1 else {
            fatalError("❌ Expected 1 menu item, got \(items.count)")
        }
        guard items.first?.title == "Action" else {
            fatalError("❌ Menu item title mismatch")
        }

        mm.removeMenuItem(item, from: "TestModule")
        guard mm.menuItems(for: "TestModule").isEmpty else {
            fatalError("❌ Menu items should be empty after remove")
        }

        // 向未注册模块添加项不应崩溃
        mm.addMenuItem(item, to: "NonExistent")

        print("✅ Test 3 passed: add/remove menu item correct")
    }

    // MARK: - 测试4: 菜单项查询
    static func testMenuItemsQuery() {
        print("\n🧪 Test 4: Menu Items Query")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        guard mm.menuItems(for: "Ghost").isEmpty else {
            fatalError("❌ menuItems for unregistered module should be empty")
        }
        guard !mm.hasMenu(for: "Ghost") else {
            fatalError("❌ hasMenu for unregistered module should be false")
        }

        let menu = NSMenu(title: "QueryTest")
        let item1 = mm.createMenuItem(title: "Item1", action: nil)
        let item2 = mm.createMenuItem(title: "Item2", action: nil)
        menu.addItem(item1)
        menu.addItem(item2)

        mm.registerModuleMenu(menu, for: "QueryModule", title: "Query")

        let items = mm.menuItems(for: "QueryModule")
        guard items.count == 2 else {
            fatalError("❌ Expected 2 items, got \(items.count)")
        }

        print("✅ Test 4 passed: menu items query correct")
    }

    // MARK: - 测试5: 创建菜单项
    static func testCreateMenuItem() {
        print("\n🧪 Test 5: Create Menu Item")

        let mm = MenuManager(mainMenu: NSMenu())

        let item = mm.createMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        guard item.title == "Quit" else {
            fatalError("❌ Title mismatch")
        }
        guard item.keyEquivalent == "q" else {
            fatalError("❌ Key equivalent mismatch")
        }
        guard item.target === NSApp else {
            fatalError("❌ Target mismatch")
        }

        print("✅ Test 5 passed: create menu item correct")
    }

    // MARK: - 测试6: 空模块名
    static func testEmptyModuleName() {
        print("\n🧪 Test 6: Empty Module Name")

        let mainMenu = NSMenu()
        let mm = MenuManager(mainMenu: mainMenu)

        let countBefore = mm.registeredModules().count
        mm.registerModuleMenu(NSMenu(), for: "", title: "Empty")
        let countAfter = mm.registeredModules().count

        guard countBefore == countAfter else {
            fatalError("❌ Registering empty module name should not add menu")
        }
        guard mainMenu.items.isEmpty else {
            fatalError("❌ mainMenu should remain empty")
        }

        print("✅ Test 6 passed: empty module name handled correctly")
    }
}
