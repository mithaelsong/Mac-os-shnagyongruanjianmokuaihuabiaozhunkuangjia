// 功能17: 视图容器（NSView 空槽设计）
// 对应: 提供标准空槽(center/left/right/top/bottom)，模块按优先级注册视图
// 优先级: P1

import AppKit
import os

// MARK: - 视图槽位
/// 视图槽位枚举
/// 定义主窗口中可供模块挂载视图的标准区域
public enum ViewSlot: String, Hashable, CaseIterable, CustomStringConvertible, Sendable {
    case center   // 主内容区（中央）
    case left     // 左侧边栏
    case right    // 右侧边栏
    case top      // 顶部栏
    case bottom   // 底部栏

    /// 槽位唯一标识符
    public var identifier: String { "slot.\(rawValue)" }

    /// 槽位显示名称
    public var description: String { rawValue }
}

// MARK: - 槽位条目
/// 槽位条目（公共查询接口）
/// 包含模块名、视图实例及优先级信息
public struct SlotEntry {
    public let moduleName: String
    public let view: NSView
    public let priority: Int
}

// MARK: - 内部注册记录
/// 视图注册记录（内部使用）
private struct Registration {
    let token: String
    let view: NSView
    let slot: ViewSlot
    let moduleName: String
    let priority: Int
}

// MARK: - 视图容器
/// 视图容器管理器 (功能17)
/// 单例管理各模块在主窗口中的视图挂载
/// 每个槽位支持多模块注册，按 priority 降序排列
/// 线程安全：所有操作均受 os_unfair_lock 保护
public final class ViewContainer {
    public static let shared = ViewContainer()

    /// token -> Registration
    private var registrations: [String: Registration] = [:]
    /// slot -> [Registration]（已按 priority 降序排列）
    private var slotRegistrations: [ViewSlot: [Registration]] = [:]
    /// moduleName -> Set<token>
    private var moduleTokens: [String: Set<String>] = [:]
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "ViewContainer")

    private init() {}

    // MARK: - 注册视图

    /// 将视图注册到指定槽位
    /// - Parameters:
    ///   - view: 要注册的 NSView
    ///   - slot: 目标槽位
    ///   - moduleName: 模块名称
    ///   - priority: 优先级（越大越靠前，同一槽位按降序排列）
    /// - Returns: 唯一 token，用于后续注销
    @discardableResult
    public func register(view: NSView, slot: ViewSlot, moduleName: String, priority: Int = 0) -> String {
        let token = UUID().uuidString

        os_unfair_lock_lock(&lock)

        let registration = Registration(
            token: token,
            view: view,
            slot: slot,
            moduleName: moduleName,
            priority: priority
        )
        registrations[token] = registration
        moduleTokens[moduleName, default: []].insert(token)

        var slotRegs = slotRegistrations[slot, default: []]
        slotRegs.append(registration)
        slotRegs.sort { $0.priority > $1.priority }
        slotRegistrations[slot] = slotRegs

        os_unfair_lock_unlock(&lock)

        logger.info("已注册视图: 槽位 '\(slot)' 模块'\(moduleName)' 优先级\(priority) token \(token)")

        EventBus.shared.emit(.viewSlotChanged, userInfo: [
            "slot": slot.rawValue,
            "moduleName": moduleName,
            "action": "registered",
            "token": token,
            "priority": priority
        ])

        return token
    }

    // MARK: - 注销视图

    /// 通过 token 注销单个视图
    /// - Parameter token: 注册时返回的 token
    /// - Returns: 是否成功注销
    @discardableResult
    public func unregister(token: String) -> Bool {
        os_unfair_lock_lock(&lock)
        guard let registration = registrations.removeValue(forKey: token) else {
            os_unfair_lock_unlock(&lock)
            return false
        }

        moduleTokens[registration.moduleName]?.remove(token)
        if moduleTokens[registration.moduleName]?.isEmpty == true {
            moduleTokens.removeValue(forKey: registration.moduleName)
        }

        if var slotRegs = slotRegistrations[registration.slot] {
            slotRegs.removeAll { $0.token == token }
            slotRegistrations[registration.slot] = slotRegs.isEmpty ? nil : slotRegs
        }

        os_unfair_lock_unlock(&lock)

        registration.view.removeFromSuperview()

        logger.info("已注销视图 token \(token)")

        EventBus.shared.emit(.viewSlotChanged, userInfo: [
            "slot": registration.slot.rawValue,
            "moduleName": registration.moduleName,
            "action": "unregistered",
            "token": token
        ])

        return true
    }

    /// 注销指定模块的所有视图
    /// - Parameter moduleName: 模块名称
    /// - Returns: 实际注销的视图数量
    @discardableResult
    public func unregisterAll(moduleName: String) -> Int {
        os_unfair_lock_lock(&lock)
        let tokens = moduleTokens.removeValue(forKey: moduleName) ?? []
        var removedRegistrations: [Registration] = []

        for token in tokens {
            if let reg = registrations.removeValue(forKey: token) {
                removedRegistrations.append(reg)
                if var slotRegs = slotRegistrations[reg.slot] {
                    slotRegs.removeAll { $0.token == token }
                    slotRegistrations[reg.slot] = slotRegs.isEmpty ? nil : slotRegs
                }
            }
        }
        os_unfair_lock_unlock(&lock)

        for reg in removedRegistrations {
            reg.view.removeFromSuperview()
        }

        logger.info("已注销模块所有视图 '\(moduleName)' (count: \(removedRegistrations.count))")

        EventBus.shared.emit(.viewSlotChanged, userInfo: [
            "moduleName": moduleName,
            "action": "unregisteredAll",
            "count": removedRegistrations.count
        ])

        return removedRegistrations.count
    }

    // MARK: - 查询

    /// 获取指定槽位优先级最高的视图
    /// - Parameter slot: 目标槽位
    /// - Returns: 优先级最高的视图，若未注册则返回 nil
    public func view(for slot: ViewSlot) -> NSView? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.first?.view
    }

    /// 获取指定槽位的所有视图（按 priority 降序）
    /// - Parameter slot: 目标槽位
    /// - Returns: 视图数组
    public func views(for slot: ViewSlot) -> [NSView] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.map(\.view) ?? []
    }

    /// 获取指定槽位的所有注册信息（按 priority 降序）
    /// - Parameter slot: 目标槽位
    /// - Returns: (token, view, moduleName, priority) 数组
    public func registrations(for slot: ViewSlot) -> [(token: String, view: NSView, moduleName: String, priority: Int)] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.map { ($0.token, $0.view, $0.moduleName, $0.priority) } ?? []
    }

    /// 获取指定槽位的所有条目（按 priority 降序）
    /// - Parameter slot: 目标槽位
    /// - Returns: SlotEntry 数组
    public func entries(for slot: ViewSlot) -> [SlotEntry] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.map { SlotEntry(moduleName: $0.moduleName, view: $0.view, priority: $0.priority) } ?? []
    }

    /// 查询指定槽位是否已注册视图
    /// - Parameter slot: 目标槽位
    /// - Returns: 是否已注册
    public func isRegistered(_ slot: ViewSlot) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return !(slotRegistrations[slot]?.isEmpty ?? true)
    }

    /// 获取所有已注册槽位列表
    /// - Returns: 已注册槽位数组
    public func registeredSlots() -> [ViewSlot] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations.compactMap { $0.value.isEmpty ? nil : $0.key }
    }

    /// 获取指定槽位已注册的所有模块名（按 priority 降序）
    /// - Parameter slot: 目标槽位
    /// - Returns: 模块名数组
    public func modules(for slot: ViewSlot) -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.map(\.moduleName) ?? []
    }

    /// 获取指定模块已注册的所有槽位
    /// - Parameter moduleName: 模块名称
    /// - Returns: 槽位数组
    public func slots(for moduleName: String) -> [ViewSlot] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let tokens = moduleTokens[moduleName] else { return [] }
        var result: [ViewSlot] = []
        for token in tokens {
            if let slot = registrations[token]?.slot, !result.contains(slot) {
                result.append(slot)
            }
        }
        return result
    }

    /// 通过 token 查询注册信息
    /// - Parameter token: 注册 token
    /// - Returns: (slot, view, moduleName, priority)
    public func registration(for token: String) -> (slot: ViewSlot, view: NSView, moduleName: String, priority: Int)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let reg = registrations[token] else { return nil }
        return (reg.slot, reg.view, reg.moduleName, reg.priority)
    }

    /// 查询指定模块在指定槽位是否已注册视图
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - slot: 目标槽位
    /// - Returns: 是否已注册
    public func isModuleRegistered(_ moduleName: String, for slot: ViewSlot) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return slotRegistrations[slot]?.contains(where: { $0.moduleName == moduleName }) ?? false
    }

    // MARK: - 构建容器层级

    /// 为指定槽位构建容器层级
    /// 将同一槽位内所有已注册视图按 priority 降序垂直堆叠
    /// - Parameter slot: 目标槽位
    /// - Returns: 根容器 NSView，若槽位未注册任何视图则返回 nil
    public func buildContainerHierarchy(for slot: ViewSlot) -> NSView? {
        os_unfair_lock_lock(&lock)
        let slotRegs = slotRegistrations[slot] ?? []
        os_unfair_lock_unlock(&lock)

        guard !slotRegs.isEmpty else { return nil }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.identifier = NSUserInterfaceItemIdentifier("ViewContainer.slot.\(slot.rawValue)")

        let views = slotRegs.map(\.view)
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        var constraints: [NSLayoutConstraint] = []

        for (index, v) in views.enumerated() {
            constraints.append(v.leadingAnchor.constraint(equalTo: container.leadingAnchor))
            constraints.append(v.trailingAnchor.constraint(equalTo: container.trailingAnchor))

            if index == 0 {
                constraints.append(v.topAnchor.constraint(equalTo: container.topAnchor))
            } else {
                constraints.append(v.topAnchor.constraint(equalTo: views[index - 1].bottomAnchor))
            }

            if index == views.count - 1 {
                constraints.append(v.bottomAnchor.constraint(equalTo: container.bottomAnchor))
            }
        }

        NSLayoutConstraint.activate(constraints)

        logger.info("已构建槽位'\(slot)'的容器层次，共\(views.count)个视图")

        return container
    }

    /// 为指定模块构建完整的容器层级
    /// 标准布局如下：
    /// ```
    /// +------------------------------------------+
    /// |                   top                     |
    /// +-----------+----------------------+---------+
    /// |   left    |       center         |  right  |
    /// +-----------+----------------------+---------+
    /// |                  bottom                   |
    /// +------------------------------------------+
    /// ```
    /// 若模块未注册某槽位，相邻槽位自动扩展填充其空间
    /// - Parameter moduleName: 模块名称
    /// - Returns: 根容器 NSView，若模块未注册任何视图则返回 nil
    public func buildContainerHierarchy(for moduleName: String) -> NSView? {
        os_unfair_lock_lock(&lock)
        guard let tokens = moduleTokens[moduleName], !tokens.isEmpty else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        var moduleRegs: [ViewSlot: Registration] = [:]
        for token in tokens {
            if let reg = registrations[token] {
                // 同一模块在同一槽位若有多个注册，取优先级最高的
                if let existing = moduleRegs[reg.slot] {
                    if reg.priority > existing.priority {
                        moduleRegs[reg.slot] = reg
                    }
                } else {
                    moduleRegs[reg.slot] = reg
                }
            }
        }
        os_unfair_lock_unlock(&lock)

        guard !moduleRegs.isEmpty else { return nil }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.identifier = NSUserInterfaceItemIdentifier("ViewContainer.\(moduleName)")

        let topView    = moduleRegs[.top]?.view
        let bottomView = moduleRegs[.bottom]?.view
        let leftView   = moduleRegs[.left]?.view
        let rightView  = moduleRegs[.right]?.view
        let centerView = moduleRegs[.center]?.view

        // 添加子视图
        [topView, bottomView, leftView, rightView, centerView].compactMap { $0 }.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        var constraints: [NSLayoutConstraint] = []

        // top
        let topAnchor: NSLayoutYAxisAnchor
        if let top = topView {
            constraints += [
                top.topAnchor.constraint(equalTo: container.topAnchor),
                top.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                top.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ]
            topAnchor = top.bottomAnchor
        } else {
            topAnchor = container.topAnchor
        }

        // bottom
        let bottomAnchor: NSLayoutYAxisAnchor
        if let bottom = bottomView {
            constraints += [
                bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ]
            bottomAnchor = bottom.topAnchor
        } else {
            bottomAnchor = container.bottomAnchor
        }

        // left
        let leadingAnchor: NSLayoutXAxisAnchor
        if let left = leftView {
            constraints += [
                left.topAnchor.constraint(equalTo: topAnchor),
                left.bottomAnchor.constraint(equalTo: bottomAnchor),
                left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ]
            leadingAnchor = left.trailingAnchor
        } else {
            leadingAnchor = container.leadingAnchor
        }

        // right
        let trailingAnchor: NSLayoutXAxisAnchor
        if let right = rightView {
            constraints += [
                right.topAnchor.constraint(equalTo: topAnchor),
                right.bottomAnchor.constraint(equalTo: bottomAnchor),
                right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ]
            trailingAnchor = right.leadingAnchor
        } else {
            trailingAnchor = container.trailingAnchor
        }

        // center
        if let center = centerView {
            constraints += [
                center.topAnchor.constraint(equalTo: topAnchor),
                center.bottomAnchor.constraint(equalTo: bottomAnchor),
                center.leadingAnchor.constraint(equalTo: leadingAnchor),
                center.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        logger.info("已构建模块容器层次 '\(moduleName)' 共\(moduleRegs.count)个槽位")

        return container
    }
}

// MARK: - 模块导航控制器
/// 模块导航控制器
/// 保留与视图容器的导航集成能力
public final class ModuleNavigationController {
    public static let shared = ModuleNavigationController()

    private var currentModule: String?

    private init() {}

    /// 导航到指定模块，激活其在视图容器中的视图层级
    /// - Parameter moduleName: 目标模块名称
    public func navigate(to moduleName: String) {
        currentModule = moduleName
        _ = ViewContainer.shared.buildContainerHierarchy(for: moduleName)
        EventBus.shared.emit(.moduleNavigationChanged, userInfo: [
            "moduleName": moduleName,
            "action": "navigate"
        ])
    }

    /// 当前导航到的模块名
    public var currentModuleName: String? {
        return currentModule
    }

    /// 重置导航状态
    public func reset() {
        currentModule = nil
        EventBus.shared.emit(.moduleNavigationChanged, userInfo: [
            "action": "reset"
        ])
    }
}

// MARK: - 通知扩展
public extension Notification.Name {
    /// 视图槽位变更通知
    static let viewSlotChanged = Notification.Name("com.xianrenzhilu.viewContainer.slotChanged")
    /// 模块导航变更通知
    static let moduleNavigationChanged = Notification.Name("com.xianrenzhilu.moduleNavigation.changed")
}

// MARK: - 测试代码
/// 视图容器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ViewContainerTests.run()`
public enum ViewContainerTests {

    /// 运行所有测试
    public static func run() {
        print("=== 视图容器测试 ===")
        testRegisterReturnsToken()
        testRegisterAndUnregisterToken()
        testPriorityOrdering()
        testViewForSlotReturnsHighestPriority()
        testUnregisterAllModuleName()
        testQueryMethods()
        testBuildContainerHierarchy()
        testBuildContainerHierarchyReturnsNil()
        testBuildContainerHierarchyForSlot()
        testMultiModuleSameSlot()
        testSlotEntries()
        testThreadSafety()
        testModuleNavigationController()
        print("\n=== 全部视图容器测试通过 ✅ ===")
    }

    // MARK: - 测试1: 注册返回 token
    static func testRegisterReturnsToken() {
        print("\n🧪 Test 1: Register returns token")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "TestModule1")

        let view = NSView()
        let token = vc.register(view: view, slot: .center, moduleName: "TestModule1", priority: 10)
        guard !token.isEmpty else {
            fatalError("❌ 测试1失败: register应返回非空token")
        }

        vc.unregisterAll(moduleName: "TestModule1")
        print("✅ 测试1通过: 注册返回有效token")
    }

    // MARK: - 测试2: 注册与注销 token
    static func testRegisterAndUnregisterToken() {
        print("\n🧪 Test 2: Register & Unregister by token")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "TestModule2")

        let view = NSView()
        let token = vc.register(view: view, slot: .center, moduleName: "TestModule2")
        guard vc.registration(for: token) != nil else {
            fatalError("❌ 测试2失败: registration(for:)应为非nil")
        }

        let result = vc.unregister(token: token)
        guard result == true else {
            fatalError("❌ 测试2失败: unregister(token:)应返回true")
        }
        guard vc.registration(for: token) == nil else {
            fatalError("❌ 测试2失败: 注销后registration应为nil")
        }

        // 重复注销应返回 false
        guard vc.unregister(token: token) == false else {
            fatalError("❌ 测试2失败: 重复注销同一token应返回false")
        }

        print("✅ 测试2通过: 注册/注销token正确")
    }

    // MARK: - 测试3: 同一槽位多模块 priority 降序
    static func testPriorityOrdering() {
        print("\n🧪 Test 3: Priority ordering")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "ModuleA")
        vc.unregisterAll(moduleName: "ModuleB")
        vc.unregisterAll(moduleName: "ModuleC")

        let viewA = NSView()
        let viewB = NSView()
        let viewC = NSView()

        _ = vc.register(view: viewA, slot: .center, moduleName: "ModuleA", priority: 5)
        _ = vc.register(view: viewB, slot: .center, moduleName: "ModuleB", priority: 10)
        _ = vc.register(view: viewC, slot: .center, moduleName: "ModuleC", priority: 3)

        let regs = vc.registrations(for: .center)
        let modules = regs.map(\.moduleName)
        guard modules == ["ModuleB", "ModuleA", "ModuleC"] else {
            fatalError("❌ 期望优先级顺序[ModuleB, ModuleA, ModuleC]，实际\(modules)")
        }

        vc.unregisterAll(moduleName: "ModuleA")
        vc.unregisterAll(moduleName: "ModuleB")
        vc.unregisterAll(moduleName: "ModuleC")
        print("✅ 测试3通过: 优先级降序正确")
    }

    // MARK: - 测试4: view(for:) 返回最高优先级视图
    static func testViewForSlotReturnsHighestPriority() {
        print("\n🧪 Test 4: view(for:) returns highest priority view")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "HighModule")
        vc.unregisterAll(moduleName: "LowModule")

        let lowView = NSView()
        let highView = NSView()

        _ = vc.register(view: lowView, slot: .top, moduleName: "LowModule", priority: 1)
        _ = vc.register(view: highView, slot: .top, moduleName: "HighModule", priority: 99)

        guard vc.view(for: .top) === highView else {
            fatalError("❌ 测试4失败: view(for:)应返回最高优先级视图")
        }

        vc.unregisterAll(moduleName: "HighModule")
        guard vc.view(for: .top) === lowView else {
            fatalError("❌ view(for:)失败: 移除高优先级后应返回低优先级视图")
        }

        vc.unregisterAll(moduleName: "LowModule")
        print("✅ 测试4通过: view(for:)返回最高优先级")
    }

    // MARK: - 测试5: 按模块名注销全部并返回数量
    static func testUnregisterAllModuleName() {
        print("\n🧪 Test 5: Unregister all by module name returns count")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "MultiSlotModule")

        _ = vc.register(view: NSView(), slot: .top, moduleName: "MultiSlotModule")
        _ = vc.register(view: NSView(), slot: .left, moduleName: "MultiSlotModule")
        _ = vc.register(view: NSView(), slot: .center, moduleName: "MultiSlotModule")

        guard vc.slots(for: "MultiSlotModule").count == 3 else {
            fatalError("❌ 期望3个已注册槽位")
        }

        let count = vc.unregisterAll(moduleName: "MultiSlotModule")
        guard count == 3 else {
            fatalError("❌ 批量注销失败: 期望返回3，实际\(count)")
        }

        guard vc.slots(for: "MultiSlotModule").isEmpty else {
            fatalError("❌ unregisterAll后槽位应为空")
        }
        guard !vc.isRegistered(.top) else {
            fatalError("❌ unregisterAll后top不应被注册")
        }

        // 重复注销应返回 0
        let secondCount = vc.unregisterAll(moduleName: "MultiSlotModule")
        guard secondCount == 0 else {
            fatalError("❌ 测试失败: 第二次unregisterAll应返回0，实际\(secondCount)")
        }

        print("✅ 测试5通过: unregisterAll返回正确数量")
    }

    // MARK: - 测试6: 查询方法
    static func testQueryMethods() {
        print("\n🧪 Test 6: Query methods")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "QueryModule")

        let view1 = NSView()
        let view2 = NSView()
        let token1 = vc.register(view: view1, slot: .center, moduleName: "QueryModule", priority: 2)
        let token2 = vc.register(view: view2, slot: .bottom, moduleName: "QueryModule", priority: 1)

        guard vc.isRegistered(.center) else {
            fatalError("❌ 查询失败: isRegistered(.center)应为true")
        }
        guard vc.isModuleRegistered("QueryModule", for: .center) else {
            fatalError("❌ isModuleRegistered应为true")
        }
        guard vc.registeredSlots().contains(.center) else {
            fatalError("❌ registeredSlots应包含.center")
        }
        guard vc.modules(for: .center).contains("QueryModule") else {
            fatalError("❌ 查询失败: modules(for:)应包含QueryModule")
        }
        guard vc.slots(for: "QueryModule").contains(.center) else {
            fatalError("❌ 查询失败: slots(for:)应包含.center")
        }
        guard vc.views(for: .center).count == 1 else {
            fatalError("❌ 查询失败: views(for:)应返回1个视图")
        }

        if let reg = vc.registration(for: token1) {
            guard reg.slot == .center && reg.priority == 2 && reg.moduleName == "QueryModule" else {
                fatalError("❌ 查询失败: registration(for:)信息不匹配")
            }
        } else {
            fatalError("❌ 测试2失败: registration(for:)应为非nil")
        }

        vc.unregister(token: token2)
        guard !vc.isRegistered(.bottom) else {
            fatalError("❌ 注销后bottom不应被注册")
        }

        vc.unregister(token: token1)
        print("✅ 测试6通过: 所有查询方法正确")
    }

    // MARK: - 测试7: 构建模块容器层级
    static func testBuildContainerHierarchy() {
        print("\n🧪 Test 7: Build container hierarchy for module")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "LayoutModule")

        let topView    = NSView()
        let leftView   = NSView()
        let centerView = NSView()
        let rightView  = NSView()
        let bottomView = NSView()

        _ = vc.register(view: topView,    slot: .top,    moduleName: "LayoutModule")
        _ = vc.register(view: leftView,   slot: .left,   moduleName: "LayoutModule")
        _ = vc.register(view: centerView, slot: .center, moduleName: "LayoutModule")
        _ = vc.register(view: rightView,  slot: .right,  moduleName: "LayoutModule")
        _ = vc.register(view: bottomView, slot: .bottom, moduleName: "LayoutModule")

        guard let container = vc.buildContainerHierarchy(for: "LayoutModule") else {
            fatalError("❌ buildContainerHierarchy应返回非nil")
        }

        let subviews = container.subviews
        guard subviews.contains(topView) else {
            fatalError("❌ topView应在容器中")
        }
        guard subviews.contains(leftView) else {
            fatalError("❌ leftView应在容器中")
        }
        guard subviews.contains(centerView) else {
            fatalError("❌ centerView应在容器中")
        }
        guard subviews.contains(rightView) else {
            fatalError("❌ rightView应在容器中")
        }
        guard subviews.contains(bottomView) else {
            fatalError("❌ bottomView应在容器中")
        }
        guard !container.constraints.isEmpty else {
            fatalError("❌ 容器应有约束")
        }

        // 测试部分布局（缺少 center）
        vc.unregisterAll(moduleName: "LayoutModule")
        _ = vc.register(view: topView,    slot: .top,    moduleName: "LayoutModule")
        _ = vc.register(view: leftView,   slot: .left,   moduleName: "LayoutModule")

        guard let partialContainer = vc.buildContainerHierarchy(for: "LayoutModule") else {
            fatalError("❌ 部分构建buildContainerHierarchy应返回非nil")
        }
        guard partialContainer.subviews.count == 2 else {
            fatalError("❌ 部分容器应有2个子视图")
        }

        vc.unregisterAll(moduleName: "LayoutModule")
        print("✅ 测试7通过: buildContainerHierarchy正确")
    }

    // MARK: - 测试8: 构建模块容器层级返回 nil
    static func testBuildContainerHierarchyReturnsNil() {
        print("\n🧪 Test 8: Build container hierarchy returns nil for unknown module")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "NonExistentModule")

        guard vc.buildContainerHierarchy(for: "NonExistentModule") == nil else {
            fatalError("❌ 未知模块buildContainerHierarchy应返回nil")
        }

        print("✅ 测试8通过: buildContainerHierarchy正确返回nil")
    }

    // MARK: - 测试9: 构建单槽位容器层级
    static func testBuildContainerHierarchyForSlot() {
        print("\n🧪 Test 9: Build container hierarchy for single slot")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "SlotModuleA")
        vc.unregisterAll(moduleName: "SlotModuleB")

        let viewA = NSView()
        let viewB = NSView()

        _ = vc.register(view: viewA, slot: .center, moduleName: "SlotModuleA", priority: 5)
        _ = vc.register(view: viewB, slot: .center, moduleName: "SlotModuleB", priority: 10)

        guard let container = vc.buildContainerHierarchy(for: .center) else {
            fatalError("❌ 构建失败: buildContainerHierarchy(for:.center)应返回非nil")
        }

        guard container.subviews.contains(viewA) && container.subviews.contains(viewB) else {
            fatalError("❌ 容器应包含两个视图")
        }

        // viewB has higher priority, should be first subview (top)
        guard container.subviews.first === viewB else {
            fatalError("❌ 高优先级视图应为第一个子视图")
        }
        guard container.subviews.last === viewA else {
            fatalError("❌ 低优先级视图应为最后一个子视图")
        }

        guard !container.constraints.isEmpty else {
            fatalError("❌ 容器应有约束")
        }

        // 空槽位应返回 nil
        guard vc.buildContainerHierarchy(for: .right) == nil else {
            fatalError("❌ 空槽位buildContainerHierarchy应返回nil")
        }

        vc.unregisterAll(moduleName: "SlotModuleA")
        vc.unregisterAll(moduleName: "SlotModuleB")
        print("✅ 测试9通过: 单槽位构建容器正确")
    }

    // MARK: - 测试10: 多模块同槽位
    static func testMultiModuleSameSlot() {
        print("\n🧪 Test 10: Multiple modules in same slot")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "SameSlotA")
        vc.unregisterAll(moduleName: "SameSlotB")
        vc.unregisterAll(moduleName: "SameSlotC")

        let viewA = NSView()
        let viewB = NSView()
        let viewC = NSView()

        let tokenA = vc.register(view: viewA, slot: .left, moduleName: "SameSlotA", priority: 7)
        let tokenB = vc.register(view: viewB, slot: .left, moduleName: "SameSlotB", priority: 12)
        let tokenC = vc.register(view: viewC, slot: .left, moduleName: "SameSlotC", priority: 3)

        let entries = vc.entries(for: .left)
        guard entries.count == 3 else {
            fatalError("❌ 测试失败: 条目数应为3，实际\(entries.count)")
        }

        // 验证 priority 降序
        guard entries[0].priority == 12 && entries[0].moduleName == "SameSlotB" else {
            fatalError("❌ 第一个条目应为SameSlotB优先级12")
        }
        guard entries[1].priority == 7 && entries[1].moduleName == "SameSlotA" else {
            fatalError("❌ 第二个条目应为SameSlotA优先级7")
        }
        guard entries[2].priority == 3 && entries[2].moduleName == "SameSlotC" else {
            fatalError("❌ 第三个条目应为SameSlotC优先级3")
        }

        // views(for:) 也应按 priority 降序
        let views = vc.views(for: .left)
        guard views[0] === viewB && views[1] === viewA && views[2] === viewC else {
            fatalError("❌ 视图顺序不匹配")
        }

        // 注销其中一个，其余保留
        vc.unregister(token: tokenB)
        let remaining = vc.entries(for: .left)
        guard remaining.count == 2 else {
            fatalError("❌ 测试失败: 剩余条目应为2，实际\(remaining.count)")
        }
        guard remaining.map(\.moduleName) == ["SameSlotA", "SameSlotC"] else {
            fatalError("❌ 剩余模块顺序不正确")
        }

        vc.unregister(token: tokenA)
        vc.unregister(token: tokenC)
        print("✅ 测试10通过: 多模块同槽位正确")
    }

    // MARK: - 测试11: SlotEntry 查询
    static func testSlotEntries() {
        print("\n🧪 Test 11: SlotEntry query")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "EntryModule")

        let view = NSView()
        _ = vc.register(view: view, slot: .right, moduleName: "EntryModule", priority: 7)

        let entries = vc.entries(for: .right)
        guard entries.count == 1 else {
            fatalError("❌ 条目数应为1")
        }
        guard entries[0].moduleName == "EntryModule" else {
            fatalError("❌ SlotEntry模块名不匹配")
        }
        guard entries[0].priority == 7 else {
            fatalError("❌ SlotEntry优先级不匹配")
        }
        guard entries[0].view === view else {
            fatalError("❌ SlotEntry视图标识不匹配")
        }

        // 空槽位返回空数组
        let emptyEntries = vc.entries(for: .bottom)
        guard emptyEntries.isEmpty else {
            fatalError("❌ 空槽位条目应为空")
        }

        vc.unregisterAll(moduleName: "EntryModule")
        print("✅ 测试11通过: SlotEntry查询正确")
    }

    // MARK: - 测试12: 线程安全
    static func testThreadSafety() {
        print("\n🧪 Test 12: Thread Safety")

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "ThreadModule")

        let group = DispatchGroup()
        let count = 100
        var tokens: [String] = []
        let tokenLock = NSLock()

        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                let token = vc.register(
                    view: NSView(),
                    slot: i % 2 == 0 ? .center : .top,
                    moduleName: "ThreadModule",
                    priority: i
                )
                tokenLock.lock()
                tokens.append(token)
                tokenLock.unlock()
                group.leave()
            }
        }
        group.wait()

        let slots = vc.registeredSlots()
        let centerCount = vc.registrations(for: .center).count
        let topCount = vc.registrations(for: .top).count
        guard centerCount + topCount == count else {
            fatalError("❌ 线程安全失败: 期望\(count)个注册，实际center:\(centerCount) top:\(topCount)")
        }

        // 并发注销一半
        let group2 = DispatchGroup()
        for i in stride(from: 0, to: count, by: 2) {
            group2.enter()
            DispatchQueue.global().async {
                vc.unregister(token: tokens[i])
                group2.leave()
            }
        }
        group2.wait()

        let remaining = vc.registrations(for: .center).count + vc.registrations(for: .top).count
        guard remaining == count / 2 else {
            fatalError("❌ 线程安全失败: 期望\(count / 2)个剩余，实际\(remaining)")
        }

        let removedCount = vc.unregisterAll(moduleName: "ThreadModule")
        guard removedCount == count / 2 else {
            fatalError("❌ 线程安全失败: 期望unregisterAll返回\(count / 2)，实际\(removedCount)")
        }
        guard vc.slots(for: "ThreadModule").isEmpty else {
            fatalError("❌ unregisterAll后期望0个槽位")
        }

        print("✅ 测试12通过: 线程安全正确")
    }

    // MARK: - 测试13: ModuleNavigationController
    static func testModuleNavigationController() {
        print("\n🧪 Test 13: ModuleNavigationController")

        let nav = ModuleNavigationController.shared
        nav.reset()

        guard nav.currentModuleName == nil else {
            fatalError("❌ currentModuleName初始应为nil")
        }

        let vc = ViewContainer.shared
        vc.unregisterAll(moduleName: "NavModule")
        _ = vc.register(view: NSView(), slot: .center, moduleName: "NavModule")

        nav.navigate(to: "NavModule")
        guard nav.currentModuleName == "NavModule" else {
            fatalError("❌ 导航后currentModuleName应为NavModule")
        }

        nav.reset()
        guard nav.currentModuleName == nil else {
            fatalError("❌ 重置后currentModuleName应为nil")
        }

        vc.unregisterAll(moduleName: "NavModule")
        print("✅ 测试13通过: 模块导航控制器正确")
    }
}
