// 功能10: 动态卸载模块
// 对应: 运行时卸载模块，释放资源
// 优先级: P1

import Foundation
import os

// MARK: - 卸载结果
/// 模块卸载结果枚举
public enum ModuleUnloadResult {
    case success
    case failure(ModuleUnloadFailureReason)
    
    public var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}

/// 模块卸载失败原因
public enum ModuleUnloadFailureReason {
    case notLoaded(name: String)
    case notConformingToProtocol(name: String)
    case hasDependents(module: String, dependents: [String])
    case stopFailed(name: String, error: Error)
    case resourceCleanupFailed(name: String, error: Error)
    case internalError(reason: String)
}

// MARK: - ModuleUnloader
/// 模块卸载器 (功能10)
/// 支持运行时动态卸载模块，包含完整的卸载生命周期管理
/// 线程安全：所有操作使用 os_unfair_lock 保护
public final class ModuleUnloader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger = ModuleLogger(category: "ModuleUnloader")
    
    /// 线程安全的已卸载模块记录
    private final class UnloadedStorage: @unchecked Sendable {
        var unloaded: Set<String> = []
        var lock = os_unfair_lock()
    }
    
    private let unloadedStorage = UnloadedStorage()
    
    public init(registry: ModuleRegistry, eventBus: EventBus) {
        self.registry = registry
        self.eventBus = eventBus
    }
    
    // MARK: - 卸载模块
    
    /// 正常卸载模块
    /// 流程：调用 stop() → 清理资源 → 从注册表移除 → 发送事件
    /// - Parameter name: 模块名称
    /// - Returns: 卸载结果
    public func unload(name: String) -> ModuleUnloadResult {
        logger.info("开始卸载模块: \(name)")
        
        // 1. 检查模块是否已注册
        guard registry.isLoaded(name: name) else {
            logger.warning("模块 \(name) 未加载，无法卸载")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. 检查模块是否实现 XRZModule 协议
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 未实现 XRZModule 协议，无法卸载")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. 检查是否有其他模块依赖它
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            logger.warning("模块 \(name) 被以下模块依赖，无法卸载: \(dependents.joined(separator: ", "))")
            return .failure(.hasDependents(module: name, dependents: dependents))
        }
        
        // 4. 发送预卸载事件
        eventBus.emit(.moduleWillUnload, userInfo: ["moduleName": name])
        
        // 5. 调用 stop() 方法
        do {
            try module.stop()
            logger.info("模块 \(name) 的 stop() 调用成功")
        } catch {
            logger.error("模块 \(name) 的 stop() 调用失败: \(error)")
            return .failure(.stopFailed(name: name, error: error))
        }
        
        // 6. 清理资源（如果模块实现了 ModuleResourceReleasable 协议）
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("模块 \(name) 的资源已释放")
        }
        
        // 7. 从注册表移除
        registry.unregister(name: name)
        
        // 8. 标记为已卸载
        markUnloaded(name)
        
        // 9. 发送已卸载事件
        eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        
        logger.info("模块 \(name) 卸载成功")
        return .success
    }
    
    // MARK: - 强制卸载
    
    /// 强制卸载模块
    /// 不调用 stop()，直接清理资源并从注册表移除
    /// 即使有依赖的模块也会强制卸载（但会先卸载依赖它的模块）
    /// ⚠️ 慎用：可能导致资源泄漏或运行时异常
    /// - Parameter name: 模块名称
    /// - Returns: 卸载结果
    public func forceUnload(name: String) -> ModuleUnloadResult {
        logger.warning("⚠️ 强制卸载模块: \(name)（将跳过 stop() 调用）")
        
        // 1. 检查模块是否已注册
        guard registry.isLoaded(name: name) else {
            logger.warning("模块 \(name) 未加载，无法强制卸载")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. 检查模块是否实现 XRZModule 协议
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 未实现 XRZModule 协议，无法强制卸载")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. 先强制卸载依赖它的模块（递归）
        let dependents = findDependents(of: name)
        for dependent in dependents {
            logger.warning("先强制卸载依赖模块: \(dependent)")
            let result = forceUnload(name: dependent)
            if !result.isSuccess {
                logger.error("依赖模块 \(dependent) 强制卸载失败，继续卸载 \(name)")
            }
        }
        
        // 4. 发送预卸载事件
        eventBus.emit(.moduleWillUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        // 5. 跳过 stop()，直接清理资源
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("模块 \(name) 的资源已强制释放")
        }
        
        // 6. 从注册表移除
        registry.unregister(name: name)
        
        // 7. 标记为已卸载
        markUnloaded(name)
        
        // 8. 发送已卸载事件
        eventBus.emit(.moduleDidUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        logger.warning("模块 \(name) 已强制卸载（stop() 未调用）")
        return .success
    }
    
    // MARK: - 查询接口
    
    /// 检查模块是否已被卸载（通过本卸载器卸载）
    /// - Parameter name: 模块名称
    /// - Returns: 是否已卸载
    public func isUnloaded(name: String) -> Bool {
        os_unfair_lock_lock(&unloadedStorage.lock)
        defer { os_unfair_lock_unlock(&unloadedStorage.lock) }
        return unloadedStorage.unloaded.contains(name)
    }
    
    /// 查找依赖指定模块的所有模块
    /// - Parameter moduleName: 被依赖的模块名称
    /// - Returns: 依赖它的模块名称列表
    public func findDependents(of moduleName: String) -> [String] {
        var dependents: [String] = []
        
        for name in registry.allModuleNames {
            if let metadata = registry.getMetadata(named: name) {
                if metadata.dependencies.contains(moduleName) {
                    dependents.append(name)
                }
            }
        }
        
        return dependents.sorted()
    }
    
    /// 检查模块是否可以卸载
    /// 即：已加载、实现 XRZModule 协议、无其他模块依赖它
    /// - Parameter name: 模块名称
    /// - Returns: 可卸载原因（如果不可卸载）
    public func canUnload(name: String) -> (canUnload: Bool, reason: String?) {
        guard registry.isLoaded(name: name) else {
            return (false, "模块未加载")
        }
        
        guard registry.getModule(named: name) is XRZModule else {
            return (false, "模块未实现 XRZModule 协议")
        }
        
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            return (false, "被以下模块依赖: \(dependents.joined(separator: ", "))")
        }
        
        return (true, nil)
    }
    
    // MARK: - 私有方法
    
    private func markUnloaded(_ name: String) {
        os_unfair_lock_lock(&unloadedStorage.lock)
        unloadedStorage.unloaded.insert(name)
        os_unfair_lock_unlock(&unloadedStorage.lock)
    }
}

// MARK: - 预定义事件（扩展）
public extension Notification.Name {
    /// 模块即将卸载（卸载流程开始）
    static let moduleWillUnload = Notification.Name("com.xianrenzhilu.module.willUnload")
    /// 模块已卸载（卸载流程完成）
    static let moduleDidUnload = Notification.Name("com.xianrenzhilu.module.didUnload")
}

// MARK: - 模块资源释放协议
public protocol ModuleResourceReleasable {
    func releaseResources()
}

// MARK: - 测试代码
/// ModuleUnloader 功能验证测试
/// 运行方式：在单元测试或 Playground 中调用 `ModuleUnloaderTests.runAllTests()`
public enum ModuleUnloaderTests {
    
    // MARK: - 测试用模块
    
    /// 正常模块（支持 stop 和资源释放）
    final class TestUnloadableModule: XRZModule, ModuleResourceReleasable {
        let name: String
        var isStarted = false
        var isStopped = false
        var resourcesReleased = false
        var shouldFailStop = false
        var shouldFailResourceRelease = false
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {
            isStarted = true
        }
        
        func stop() throws {
            if shouldFailStop {
                throw NSError(domain: "TestModule", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟 stop 失败"])
            }
            isStopped = true
        }
        
        func releaseResources() {
            if shouldFailResourceRelease {
                // 理论上不会抛异常，但模拟异常情况
            }
            resourcesReleased = true
        }
    }
    
    /// 不释放资源的模块（仅实现 XRZModule）
    final class SimpleModule: XRZModule {
        let name: String
        var isStopped = false
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {}
        func stop() throws {
            isStopped = true
        }
    }
    
    /// 不实现 XRZModule 的模块
    final class NonConformingModule {
        let name = "NonConforming"
    }
    
    // MARK: - 辅助方法
    
    /// 清理注册表中的所有模块
    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    /// 运行所有测试
    public static func runAllTests() {
        print("=== ModuleUnloader Tests ===")
        
        cleanupRegistry()
        testNormalUnload()
        cleanupRegistry()
        
        testForceUnload()
        cleanupRegistry()
        
        testDependentRefusal()
        cleanupRegistry()
        
        testNotLoadedModule()
        cleanupRegistry()
        
        testStopFailure()
        cleanupRegistry()
        
        testNonConformingModule()
        cleanupRegistry()
        
        testResourceRelease()
        cleanupRegistry()
        
        testCanUnloadCheck()
        cleanupRegistry()
        
        testMultipleDependents()
        cleanupRegistry()
        
        testForceUnloadWithDependents()
        cleanupRegistry()
        
        testEventEmission()
        cleanupRegistry()
        
        print("\n=== All ModuleUnloader Tests Passed ✅ ===")
    }
    
    // MARK: - 测试1: 正常卸载
    
    /// 测试正常卸载流程：stop() → 清理资源 → 从注册表移除 → 发送事件
    public static func testNormalUnload() {
        print("\n🧪 测试1: 正常卸载")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "NormalModule")
        registry.register(
            module: module,
            name: "NormalModule",
            metadata: ModuleMetadata(
                name: "NormalModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "NormalModule")
        
        guard case .success = result else {
            fatalError("❌ 测试1失败: 期望卸载成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "NormalModule") else {
            fatalError("❌ 测试1失败: 模块应在注册表中被移除")
        }
        guard module.isStopped else {
            fatalError("❌ 测试1失败: stop() 应被调用")
        }
        guard module.resourcesReleased else {
            fatalError("❌ 测试1失败: releaseResources() 应被调用")
        }
        guard unloader.isUnloaded(name: "NormalModule") else {
            fatalError("❌ 测试1失败: 模块应被标记为已卸载")
        }
        
        print("✅ 测试1通过: 正常卸载流程正确")
    }
    
    // MARK: - 测试2: 强制卸载
    
    /// 测试强制卸载：不调用 stop()，直接清理
    public static func testForceUnload() {
        print("\n🧪 测试2: 强制卸载")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "ForceModule")
        registry.register(
            module: module,
            name: "ForceModule",
            metadata: ModuleMetadata(
                name: "ForceModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.forceUnload(name: "ForceModule")
        
        guard case .success = result else {
            fatalError("❌ 测试2失败: 期望强制卸载成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "ForceModule") else {
            fatalError("❌ 测试2失败: 模块应在注册表中被移除")
        }
        guard !module.isStopped else {
            fatalError("❌ 测试2失败: 强制卸载不应调用 stop()")
        }
        guard module.resourcesReleased else {
            fatalError("❌ 测试2失败: 强制卸载也应释放资源")
        }
        
        print("✅ 测试2通过: 强制卸载不调用 stop()，直接清理")
    }
    
    // MARK: - 测试3: 依赖检查拒绝
    
    /// 测试有依赖时拒绝卸载
    public static func testDependentRefusal() {
        print("\n🧪 测试3: 有依赖时拒绝卸载")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let coreModule = SimpleModule(name: "CoreModule")
        let dependentModule = SimpleModule(name: "DependentModule")
        
        registry.register(
            module: coreModule,
            name: "CoreModule",
            metadata: ModuleMetadata(
                name: "CoreModule",
                version: "1.0",
                description: "Core",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        registry.register(
            module: dependentModule,
            name: "DependentModule",
            metadata: ModuleMetadata(
                name: "DependentModule",
                version: "1.0",
                description: "Depends on Core",
                entryClass: "SimpleModule",
                dependencies: ["CoreModule"]
            )
        )
        
        let result = unloader.unload(name: "CoreModule")
        
        guard case .failure(.hasDependents(let module, let dependents)) = result else {
            fatalError("❌ 测试3失败: 期望 hasDependents 错误，实际 \(result)")
        }
        guard module == "CoreModule" else {
            fatalError("❌ 测试3失败: 模块名不匹配")
        }
        guard dependents == ["DependentModule"] else {
            fatalError("❌ 测试3失败: 依赖列表不匹配，期望 [DependentModule]，实际 \(dependents)")
        }
        guard registry.isLoaded(name: "CoreModule") else {
            fatalError("❌ 测试3失败: 核心模块不应被移除")
        }
        guard coreModule.isStopped == false else {
            fatalError("❌ 测试3失败: stop() 不应被调用")
        }
        
        print("✅ 测试3通过: 有依赖时正确拒绝卸载")
    }
    
    // MARK: - 测试4: 未加载模块
    
    /// 测试卸载未加载的模块
    public static func testNotLoadedModule() {
        print("\n🧪 测试4: 卸载未加载的模块")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let result = unloader.unload(name: "GhostModule")
        
        guard case .failure(.notLoaded(let name)) = result else {
            fatalError("❌ 测试4失败: 期望 notLoaded 错误，实际 \(result)")
        }
        guard name == "GhostModule" else {
            fatalError("❌ 测试4失败: 模块名不匹配")
        }
        
        print("✅ 测试4通过: 未加载模块正确拒绝")
    }
    
    // MARK: - 测试5: stop() 失败
    
    /// 测试 stop() 抛出异常时的处理
    public static func testStopFailure() {
        print("\n🧪 测试5: stop() 失败")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "FailStopModule")
        module.shouldFailStop = true
        registry.register(
            module: module,
            name: "FailStopModule",
            metadata: ModuleMetadata(
                name: "FailStopModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "FailStopModule")
        
        guard case .failure(.stopFailed(let name, _)) = result else {
            fatalError("❌ 测试5失败: 期望 stopFailed 错误，实际 \(result)")
        }
        guard name == "FailStopModule" else {
            fatalError("❌ 测试5失败: 模块名不匹配")
        }
        guard registry.isLoaded(name: "FailStopModule") else {
            fatalError("❌ 测试5失败: stop 失败时模块不应被移除")
        }
        
        print("✅ 测试5通过: stop() 失败时正确回滚，不移除模块")
    }
    
    // MARK: - 测试6: 未实现 XRZModule
    
    /// 测试卸载未实现 XRZModule 协议的模块
    public static func testNonConformingModule() {
        print("\n🧪 测试6: 未实现 XRZModule 协议")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = NonConformingModule()
        registry.register(module: module, name: "NonConformingModule")
        
        let result = unloader.unload(name: "NonConformingModule")
        
        guard case .failure(.notConformingToProtocol(let name)) = result else {
            fatalError("❌ 测试6失败: 期望 notConformingToProtocol 错误，实际 \(result)")
        }
        guard name == "NonConformingModule" else {
            fatalError("❌ 测试6失败: 模块名不匹配")
        }
        
        print("✅ 测试6通过: 未实现协议的模块正确拒绝")
    }
    
    // MARK: - 测试7: 资源释放
    
    /// 测试没有实现 ModuleResourceReleasable 的模块也能正常卸载
    public static func testResourceRelease() {
        print("\n🧪 测试7: 无资源释放协议的模块卸载")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = SimpleModule(name: "SimpleModule")
        registry.register(
            module: module,
            name: "SimpleModule",
            metadata: ModuleMetadata(
                name: "SimpleModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "SimpleModule")
        
        guard case .success = result else {
            fatalError("❌ 测试7失败: 期望卸载成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "SimpleModule") else {
            fatalError("❌ 测试7失败: 模块应在注册表中被移除")
        }
        guard module.isStopped else {
            fatalError("❌ 测试7失败: stop() 应被调用")
        }
        
        print("✅ 测试7通过: 无资源释放协议的模块也能正常卸载")
    }
    
    // MARK: - 测试8: 可卸载检查
    
    /// 测试 canUnload 检查方法
    public static func testCanUnloadCheck() {
        print("\n🧪 测试8: 可卸载检查")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        // 未注册模块
        let check1 = unloader.canUnload(name: "Missing")
        guard check1.canUnload == false, check1.reason?.contains("未加载") == true else {
            fatalError("❌ 测试8a失败: 未注册模块应不可卸载")
        }
        
        // 已注册且无依赖的模块
        let module = SimpleModule(name: "FreeModule")
        registry.register(
            module: module,
            name: "FreeModule",
            metadata: ModuleMetadata(
                name: "FreeModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        let check2 = unloader.canUnload(name: "FreeModule")
        guard check2.canUnload == true, check2.reason == nil else {
            fatalError("❌ 测试8b失败: 无依赖模块应可卸载")
        }
        
        // 有依赖的模块
        let dependent = SimpleModule(name: "UserModule")
        registry.register(
            module: dependent,
            name: "UserModule",
            metadata: ModuleMetadata(
                name: "UserModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: ["FreeModule"]
            )
        )
        let check3 = unloader.canUnload(name: "FreeModule")
        guard check3.canUnload == false, check3.reason?.contains("UserModule") == true else {
            fatalError("❌ 测试8c失败: 有依赖的模块应不可卸载")
        }
        
        print("✅ 测试8通过: canUnload 检查正确")
    }
    
    // MARK: - 测试9: 多依赖模块
    
    /// 测试一个模块被多个模块依赖的情况
    public static func testMultipleDependents() {
        print("\n🧪 测试9: 多依赖模块")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let core = SimpleModule(name: "Core")
        let userA = SimpleModule(name: "UserA")
        let userB = SimpleModule(name: "UserB")
        
        registry.register(
            module: core,
            name: "Core",
            metadata: ModuleMetadata(
                name: "Core",
                version: "1.0",
                description: "Core",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        registry.register(
            module: userA,
            name: "UserA",
            metadata: ModuleMetadata(
                name: "UserA",
                version: "1.0",
                description: "UserA",
                entryClass: "SimpleModule",
                dependencies: ["Core"]
            )
        )
        registry.register(
            module: userB,
            name: "UserB",
            metadata: ModuleMetadata(
                name: "UserB",
                version: "1.0",
                description: "UserB",
                entryClass: "SimpleModule",
                dependencies: ["Core"]
            )
        )
        
        let dependents = unloader.findDependents(of: "Core")
        guard dependents.count == 2 else {
            fatalError("❌ 测试9失败: 期望 2 个依赖，实际 \(dependents.count)")
        }
        guard dependents.contains("UserA") && dependents.contains("UserB") else {
            fatalError("❌ 测试9失败: 依赖列表应包含 UserA 和 UserB")
        }
        
        let result = unloader.unload(name: "Core")
        guard case .failure(.hasDependents(_, let deps)) = result else {
            fatalError("❌ 测试9失败: 期望 hasDependents 错误")
        }
        guard deps.count == 2 else {
            fatalError("❌ 测试9失败: 依赖列表应有 2 个元素")
        }
        
        print("✅ 测试9通过: 多依赖检测正确")
    }
    
    // MARK: - 测试10: 强制卸载带依赖的模块
    
    /// 测试强制卸载会递归卸载依赖它的模块
    public static func testForceUnloadWithDependents() {
        print("\n🧪 测试10: 强制卸载带依赖的模块")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let core = TestUnloadableModule(name: "CoreF")
        let user = TestUnloadableModule(name: "UserF")
        
        registry.register(
            module: core,
            name: "CoreF",
            metadata: ModuleMetadata(
                name: "CoreF",
                version: "1.0",
                description: "Core",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        registry.register(
            module: user,
            name: "UserF",
            metadata: ModuleMetadata(
                name: "UserF",
                version: "1.0",
                description: "UserF",
                entryClass: "TestUnloadableModule",
                dependencies: ["CoreF"]
            )
        )
        
        let result = unloader.forceUnload(name: "CoreF")
        
        guard case .success = result else {
            fatalError("❌ 测试10失败: 期望强制卸载成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "CoreF") else {
            fatalError("❌ 测试10失败: CoreF 应被移除")
        }
        guard !registry.isLoaded(name: "UserF") else {
            fatalError("❌ 测试10失败: UserF 也应被强制移除")
        }
        guard !core.isStopped else {
            fatalError("❌ 测试10失败: CoreF 的 stop() 不应被调用（强制卸载）")
        }
        guard !user.isStopped else {
            fatalError("❌ 测试10失败: UserF 的 stop() 不应被调用（强制卸载）")
        }
        guard core.resourcesReleased else {
            fatalError("❌ 测试10失败: CoreF 的资源应被释放")
        }
        guard user.resourcesReleased else {
            fatalError("❌ 测试10失败: UserF 的资源应被释放")
        }
        
        print("✅ 测试10通过: 强制卸载递归卸载依赖模块")
    }
    
    // MARK: - 测试11: 事件发送
    
    /// 测试卸载时事件是否正确发送
    public static func testEventEmission() {
        print("\n🧪 测试11: 事件发送")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        var willUnloadReceived = false
        var didUnloadReceived = false
        var willUnloadModuleName: String?
        var didUnloadModuleName: String?
        
        let obs1 = eventBus.on(.moduleWillUnload) { notification in
            willUnloadReceived = true
            willUnloadModuleName = notification.userInfo?["moduleName"] as? String
        }
        
        let obs2 = eventBus.on(.moduleDidUnload) { notification in
            didUnloadReceived = true
            didUnloadModuleName = notification.userInfo?["moduleName"] as? String
        }
        
        let module = SimpleModule(name: "EventModule")
        registry.register(
            module: module,
            name: "EventModule",
            metadata: ModuleMetadata(
                name: "EventModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "EventModule")
        
        guard case .success = result else {
            fatalError("❌ 测试11失败: 期望卸载成功")
        }
        guard willUnloadReceived else {
            fatalError("❌ 测试11失败: moduleWillUnload 事件未收到")
        }
        guard didUnloadReceived else {
            fatalError("❌ 测试11失败: moduleDidUnload 事件未收到")
        }
        guard willUnloadModuleName == "EventModule" else {
            fatalError("❌ 测试11失败: moduleWillUnload 模块名不匹配")
        }
        guard didUnloadModuleName == "EventModule" else {
            fatalError("❌ 测试11失败: moduleDidUnload 模块名不匹配")
        }
        
        eventBus.off(obs1)
        eventBus.off(obs2)
        
        print("✅ 测试11通过: 卸载事件正确发送")
    }
}
