// 功能19: 工具栏管理
// 对应: 模块可以添加工具栏按钮
// 优先级: P2

import AppKit
import os.lock

// MARK: - 工具栏项定义
/// 工具栏项定义结构体
public struct ToolbarItemDefinition {
    public let identifier: String
    public let label: String
    public let icon: NSImage?
    public let tooltip: String?
    public let action: () -> Void

    public init(identifier: String, label: String, icon: NSImage? = nil,
                tooltip: String? = nil, action: @escaping () -> Void) {
        self.identifier = identifier
        self.label = label
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
    }
}

// MARK: - 工具栏管理器
/// 工具栏管理器 (功能19)
/// 管理窗口工具栏的注册、注销与展示
/// 实现 NSToolbarDelegate 以动态提供工具栏项
public final class ToolbarManager: NSObject, NSToolbarDelegate {
    public static let shared = ToolbarManager()

    private var items: [String: ToolbarItemDefinition] = [:]
    private var moduleItems: [String: [String]] = [:]
    private weak var toolbar: NSToolbar?
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "ToolbarManager")

    public override init() {}

    // MARK: - 设置工具栏

    /// 为指定窗口设置并配置工具栏
    /// - Parameter window: 目标窗口
    public func setupToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        window.toolbar = toolbar
        self.toolbar = toolbar

        logger.info("Setup toolbar for window: \(window.title)")
    }

    // MARK: - 注册工具栏项

    /// 注册工具栏项
    /// - Parameters:
    ///   - definition: 工具栏项定义
    ///   - module: 所属模块名称（不能为空）
    public func registerItem(_ definition: ToolbarItemDefinition, for module: String) {
        guard !module.isEmpty, !definition.identifier.isEmpty else {
            logger.warning("registerItem failed: empty module or identifier")
            return
        }

        os_unfair_lock_lock(&lock)
        items[definition.identifier] = definition
        moduleItems[module, default: []].append(definition.identifier)
        os_unfair_lock_unlock(&lock)

        // 若工具栏已绑定窗口，插入新项
        if let toolbar = toolbar {
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(definition.identifier), at: items.count - 1)
        }

        logger.info("Registered toolbar item '\(definition.identifier)' for module: \(module)")
    }

    // MARK: - 移除工具栏项

    /// 移除指定模块的所有工具栏项
    /// - Parameter module: 模块名称
    public func unregisterItems(for module: String) {
        os_unfair_lock_lock(&lock)
        let ids = moduleItems.removeValue(forKey: module) ?? []
        for id in ids {
            items.removeValue(forKey: id)
        }
        os_unfair_lock_unlock(&lock)

        // 从工具栏移除
        if let toolbar = toolbar {
            for id in ids {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == id }) {
                    toolbar.removeItem(at: index)
                }
            }
        }

        if !ids.isEmpty {
            logger.info("Unregistered \(ids.count) toolbar item(s) for module: \(module)")
        }
    }

    /// 移除所有工具栏项
    public func unregisterAllItems() {
        os_unfair_lock_lock(&lock)
        let ids = Array(items.keys)
        items.removeAll()
        moduleItems.removeAll()
        os_unfair_lock_unlock(&lock)

        // 清空工具栏
        if let toolbar = toolbar {
            while toolbar.items.count > 0 {
                toolbar.removeItem(at: 0)
            }
        }

        logger.info("Unregistered all toolbar items (count: \(ids.count))")
    }

    // MARK: - 查询

    /// 获取指定模块的工具栏项标识符列表
    /// - Parameter module: 模块名称
    /// - Returns: 标识符数组
    public func toolbarItems(for module: String) -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return moduleItems[module] ?? []
    }

    /// 获取所有已注册的工具栏项标识符
    /// - Returns: 标识符数组
    public func allItemIdentifiers() -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(items.keys)
    }

    /// 获取工具栏项定义
    /// - Parameter identifier: 标识符
    /// - Returns: 定义对象，不存在时返回 nil
    public func definition(for identifier: String) -> ToolbarItemDefinition? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return items[identifier]
    }

    // MARK: - NSToolbarDelegate

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        os_unfair_lock_lock(&lock)
        let definition = items[itemIdentifier.rawValue]
        os_unfair_lock_unlock(&lock)

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
        os_unfair_lock_lock(&lock)
        let ids = items.keys.map { NSToolbarItem.Identifier($0) }
        os_unfair_lock_unlock(&lock)
        return ids
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }

    // MARK: - 动作处理

    @objc private func handleToolbarAction(_ sender: NSToolbarItem) {
        let id = sender.itemIdentifier.rawValue

        os_unfair_lock_lock(&lock)
        let definition = items[id]
        os_unfair_lock_unlock(&lock)

        definition?.action()

        logger.debug("Toolbar action triggered for item: \(id)")
    }
}

// MARK: - 测试代码
/// 工具栏管理器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ToolbarManagerTests.run()`
public enum ToolbarManagerTests {

    /// 运行所有测试
    public static func run() {
        print("=== ToolbarManager Tests ===")
        testRegisterAndUnregister()
        testUnregisterAll()
        testQuery()
        testModuleIsolation()
        testEmptyInput()
        print("\n=== All ToolbarManager Tests Passed ✅ ===")
    }

    // MARK: - 测试1: 注册/注销
    static func testRegisterAndUnregister() {
        print("\n🧪 Test 1: Register & Unregister")

        let tm = ToolbarManager()

        var actionCalled = false
        let def = ToolbarItemDefinition(
            identifier: "test.action",
            label: "Action",
            action: { actionCalled = true }
        )

        tm.registerItem(def, for: "TestModule")
        _ = actionCalled // action 闭包正确捕获

        guard tm.allItemIdentifiers().contains("test.action") else {
            fatalError("❌ allItemIdentifiers should contain 'test.action'")
        }
        guard tm.toolbarItems(for: "TestModule").contains("test.action") else {
            fatalError("❌ toolbarItems should contain 'test.action'")
        }
        guard tm.definition(for: "test.action") != nil else {
            fatalError("❌ definition should not be nil")
        }

        tm.unregisterItems(for: "TestModule")

        guard !tm.allItemIdentifiers().contains("test.action") else {
            fatalError("❌ allItemIdentifiers should not contain 'test.action' after unregister")
        }
        guard tm.toolbarItems(for: "TestModule").isEmpty else {
            fatalError("❌ toolbarItems should be empty after unregister")
        }

        print("✅ Test 1 passed: register/unregister correct")
    }

    // MARK: - 测试2: 注销全部
    static func testUnregisterAll() {
        print("\n🧪 Test 2: Unregister All")

        let tm = ToolbarManager()

        tm.registerItem(ToolbarItemDefinition(identifier: "a", label: "A", action: {}), for: "M1")
        tm.registerItem(ToolbarItemDefinition(identifier: "b", label: "B", action: {}), for: "M2")

        guard tm.allItemIdentifiers().count == 2 else {
            fatalError("❌ Expected 2 items before unregisterAll")
        }

        tm.unregisterAllItems()

        guard tm.allItemIdentifiers().isEmpty else {
            fatalError("❌ allItemIdentifiers should be empty after unregisterAll")
        }
        guard tm.toolbarItems(for: "M1").isEmpty else {
            fatalError("❌ M1 items should be empty after unregisterAll")
        }
        guard tm.toolbarItems(for: "M2").isEmpty else {
            fatalError("❌ M2 items should be empty after unregisterAll")
        }

        print("✅ Test 2 passed: unregisterAll correct")
    }

    // MARK: - 测试3: 查询
    static func testQuery() {
        print("\n🧪 Test 3: Query")

        let tm = ToolbarManager()

        guard tm.allItemIdentifiers().isEmpty else {
            fatalError("❌ allItemIdentifiers should be empty initially")
        }
        guard tm.toolbarItems(for: "Ghost").isEmpty else {
            fatalError("❌ toolbarItems for non-existent module should be empty")
        }
        guard tm.definition(for: "ghost") == nil else {
            fatalError("❌ definition for non-existent item should be nil")
        }

        let def = ToolbarItemDefinition(identifier: "q1", label: "Q1", tooltip: "Tooltip", action: {})
        tm.registerItem(def, for: "QueryModule")

        guard let fetched = tm.definition(for: "q1") else {
            fatalError("❌ definition should not be nil")
        }
        guard fetched.label == "Q1" else {
            fatalError("❌ label mismatch")
        }
        guard fetched.tooltip == "Tooltip" else {
            fatalError("❌ tooltip mismatch")
        }

        print("✅ Test 3 passed: query correct")
    }

    // MARK: - 测试4: 模块隔离
    static func testModuleIsolation() {
        print("\n🧪 Test 4: Module Isolation")

        let tm = ToolbarManager()

        tm.registerItem(ToolbarItemDefinition(identifier: "m1.a", label: "M1A", action: {}), for: "Module1")
        tm.registerItem(ToolbarItemDefinition(identifier: "m1.b", label: "M1B", action: {}), for: "Module1")
        tm.registerItem(ToolbarItemDefinition(identifier: "m2.a", label: "M2A", action: {}), for: "Module2")

        guard tm.toolbarItems(for: "Module1").count == 2 else {
            fatalError("❌ Module1 should have 2 items")
        }
        guard tm.toolbarItems(for: "Module2").count == 1 else {
            fatalError("❌ Module2 should have 1 item")
        }

        tm.unregisterItems(for: "Module1")

        guard tm.toolbarItems(for: "Module1").isEmpty else {
            fatalError("❌ Module1 should be empty after unregister")
        }
        guard tm.toolbarItems(for: "Module2").count == 1 else {
            fatalError("❌ Module2 should still have 1 item")
        }
        guard tm.allItemIdentifiers().contains("m2.a") else {
            fatalError("❌ m2.a should still exist")
        }

        print("✅ Test 4 passed: module isolation correct")
    }

    // MARK: - 测试5: 空输入
    static func testEmptyInput() {
        print("\n🧪 Test 5: Empty Input")

        let tm = ToolbarManager()
        let countBefore = tm.allItemIdentifiers().count

        tm.registerItem(ToolbarItemDefinition(identifier: "", label: "Empty", action: {}), for: "Mod")
        tm.registerItem(ToolbarItemDefinition(identifier: "x", label: "X", action: {}), for: "")

        let countAfter = tm.allItemIdentifiers().count
        guard countBefore == countAfter else {
            fatalError("❌ Empty module or identifier should not be registered")
        }

        print("✅ Test 5 passed: empty input handled correctly")
    }
}
