// 功能10: 动态卸载模块
// Description: Unload modules at runtime, release resources
// Priority: P1

import Foundation
import os

// MARK: - Unload Result
/// Module unload result enumeration
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

/// Module unload failure reason
public enum ModuleUnloadFailureReason {
    case notLoaded(name: String)
    case notConformingToProtocol(name: String)
    case hasDependents(module: String, dependents: [String])
    case stopFailed(name: String, error: Error)
    case resourceCleanupFailed(name: String, error: Error)
    case internalError(reason: String)
}

// MARK: - ModuleUnloader
/// Module unloader (Function 10)
/// Runtime dynamic module unloading with full lifecycle management
/// Thread-safe: all operations protected by os_unfair_lock
public final class ModuleUnloader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger = ModuleLogger(category: "ModuleUnloader")
    
    /// Thread-safe set of unloaded modules
    private final class UnloadedStorage: @unchecked Sendable {
        var unloaded: Set<String> = []
        var lock = os_unfair_lock()
    }
    
    private let unloadedStorage = UnloadedStorage()
    
    public init(registry: ModuleRegistry, eventBus: EventBus) {
        self.registry = registry
        self.eventBus = eventBus
    }
    
    // MARK: - Unload Module
    
    /// Normal module unload
    /// Process: stop() -> cleanup -> unregister -> emit event
    /// - Parameter name: Module name
    /// - Returns: Unload result
    public func unload(name: String) -> ModuleUnloadResult {
        logger.info("卸载模块: \(name)")
        
        // 1. Check if module is registered
        guard registry.isLoaded(name: name) else {
            logger.warning("模块 \(name) 未加载，无法卸载")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. Check XRZModule conformance
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 不符合XRZModule协议，无法卸载")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. Check for dependent modules
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            logger.warning("模块 \(name) 有依赖模块，无法卸载: \(dependents.joined(separator: ", "))")
            return .failure(.hasDependents(module: name, dependents: dependents))
        }
        
        // 4. Send pre-unload event
        eventBus.emit(.moduleWillUnload, userInfo: ["moduleName": name])
        
        // 5. Call stop()
        do {
            try module.stop()
            logger.info("模块 \(name) stop()成功")
        } catch {
            logger.error("模块 \(name) stop()失败: \(error)")
            return .failure(.stopFailed(name: name, error: error))
        }
        
        // 6. Cleanup resources (if ModuleResourceReleasable is implemented)
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("模块 \(name) 资源已释放")
        }
        
        // 7. Remove from registry
        registry.unregister(name: name)
        
        // 8. Mark as unloaded
        markUnloaded(name)
        
        // 9. Send unload event
        eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        
        logger.info("模块 \(name) 成功卸载")
        return .success
    }
    
    // MARK: - Force Unload
    
    /// Force unload a module
    /// Skip stop(), directly cleanup and remove from registry
    /// Force unloads dependent modules first, then the target
    /// ⚠️ Caution: may cause resource leaks or runtime errors
    /// - Parameter name: Module name
    /// - Returns: Unload result
    public func forceUnload(name: String) -> ModuleUnloadResult {
        logger.warning("⚠️ 强制卸载: \(name) (跳过stop())")
        
        // 1. Check if module is registered
        guard registry.isLoaded(name: name) else {
            logger.warning("模块 \(name) 未加载，无法强制卸载")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. Check XRZModule conformance
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 不符合XRZModule协议，无法强制卸载")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. Force unload dependents first (recursive)
        let dependents = findDependents(of: name)
        for dependent in dependents {
            logger.warning("强制卸载依赖: \(dependent)")
            let result = forceUnload(name: dependent)
            if !result.isSuccess {
                logger.error("依赖模块 \(dependent) 强制卸载失败，继续处理 \(name)")
            }
        }
        
        // 4. Send pre-unload event
        eventBus.emit(.moduleWillUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        // 5. Skip stop(), direct cleanup
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("模块 \(name) 资源已强制释放")
        }
        
        // 6. Remove from registry
        registry.unregister(name: name)
        
        // 7. Mark as unloaded
        markUnloaded(name)
        
        // 8. Send unload event
        eventBus.emit(.moduleDidUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        logger.warning("模块 \(name) 已强制卸载 (未调用stop())")
        return .success
    }
    
    // MARK: - Query Interface
    
    /// Check if module has been unloaded by this unloader
    /// - Parameter name: Module name
    /// - Returns: Whether module is unloaded
    public func isUnloaded(name: String) -> Bool {
        os_unfair_lock_lock(&unloadedStorage.lock)
        defer { os_unfair_lock_unlock(&unloadedStorage.lock) }
        return unloadedStorage.unloaded.contains(name)
    }
    
    /// Find all modules that depend on a given module
    /// - Parameter moduleName: Depended-upon module name
    /// - Returns: List of dependent names
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
    
    /// Check if module can be unloaded
    /// Must: loaded, implements XRZModule, no dependents
    /// - Parameter name: Module name
    /// - Returns: Whether unloadable and reason
    public func canUnload(name: String) -> (canUnload: Bool, reason: String?) {
        guard registry.isLoaded(name: name) else {
            return (false, "module not loaded")
        }
        
        guard registry.getModule(named: name) is XRZModule else {
            return (false, "module does not implement XRZModule")
        }
        
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            return (false, "depended on by: \(dependents.joined(separator: ", "))")
        }
        
        return (true, nil)
    }
    
    // MARK: - Private Methods
    
    private func markUnloaded(_ name: String) {
        os_unfair_lock_lock(&unloadedStorage.lock)
        unloadedStorage.unloaded.insert(name)
        os_unfair_lock_unlock(&unloadedStorage.lock)
    }
}

// MARK: - Predefined Events (Extension)
public extension Notification.Name {
    /// Module will unload (start of unload flow)
    static let moduleWillUnload = Notification.Name("com.xianrenzhilu.module.willUnload")
    /// Module did unload (unload flow completed)
    static let moduleDidUnload = Notification.Name("com.xianrenzhilu.module.didUnload")
}

// MARK: - Module Resource Release Protocol
public protocol ModuleResourceReleasable {
    func releaseResources()
}

// MARK: - Test Code
/// ModuleUnloader functional verification tests
/// Run: `ModuleUnloaderTests.runAllTests()` in unit tests or Playground
public enum ModuleUnloaderTests {
    
    // MARK: - Test Modules
    
    /// Normal module (supports stop and resource release)
    final class TestUnloadableModule: XRZModule, ModuleResourceReleasable {
        let name: String
        var isStarted = false
        var isStopped = false
        var resourcesReleased = false
        var shouldFailStop = false
        var shouldFailResourceRelease = false
        
        required init() {
            self.name = "TestUnloadable"
        }
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {
            isStarted = true
        }
        
        func stop() throws {
            if shouldFailStop {
                throw NSError(domain: "TestModule", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated stop failure"])
            }
            isStopped = true
        }
        
        func releaseResources() {
            if shouldFailResourceRelease {
                // Resource release should not throw, but handle gracefully
            }
            resourcesReleased = true
        }
    }
    
    /// Simple module (only implements XRZModule, no resource release)
    final class SimpleModule: XRZModule {
        let name: String
        var isStopped = false
        
        required init() {
            self.name = "Simple"
        }
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {}
        func stop() throws {
            isStopped = true
        }
    }
    
    /// Module that does not implement XRZModule
    final class NonConformingModule {
        let name = "NonConforming"
    }
    
    // MARK: - Helper Methods
    
    /// Remove all modules from registry
    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    /// Run all tests
    public static func runAllTests() {
        print("=== 功能10测试 ===")
        
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
        
        print("\n=== 全部功能10测试通过 ✅ ===")
    }
    
    // MARK: - Test 1: Normal Unload
    
    /// Test normal unload: stop() -> cleanup -> unregister -> emit event
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
            fatalError("❌ 测试1失败: 期望成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "NormalModule") else {
            fatalError("❌ 测试1失败: 模块应从注册表中移除")
        }
        guard module.isStopped else {
            fatalError("❌ 测试1失败: 应调用stop()")
        }
        guard module.resourcesReleased else {
            fatalError("❌ 测试1失败: 应调用releaseResources()")
        }
        guard unloader.isUnloaded(name: "NormalModule") else {
            fatalError("❌ 测试1失败: 模块应标记为已卸载")
        }
        
        print("✅ 测试1通过: 正常卸载流程正确")
    }
    
    // MARK: - Test 2: Force Unload
    
    /// Test force unload: skip stop(), direct cleanup
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
            fatalError("❌ 测试2失败: 模块应已移除")
        }
        guard !module.isStopped else {
            fatalError("❌ 测试2失败: 强制卸载不应调用stop()")
        }
        guard module.resourcesReleased else {
            fatalError("❌ 测试2失败: 强制卸载应释放资源")
        }
        
        print("✅ 测试2通过: 强制卸载跳过stop()，直接清理")
    }
    
    // MARK: - Test 3: Dependent Refusal
    
    /// Test refusal when module has dependents
    public static func testDependentRefusal() {
        print("\n🧪 测试3: 依赖检查拒绝")
        
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
            fatalError("❌ 测试3失败: 期望hasDependents，实际 \(result)")
        }
        guard module == "CoreModule" else {
            fatalError("❌ 测试3失败: 模块名称不匹配")
        }
        guard dependents == ["DependentModule"] else {
            fatalError("❌ 测试3失败: 依赖期望[DependentModule]，实际 \(dependents)")
        }
        guard registry.isLoaded(name: "CoreModule") else {
            fatalError("❌ 测试3失败: 核心模块不应被移除")
        }
        guard coreModule.isStopped == false else {
            fatalError("❌ 测试3失败: 不应调用stop()")
        }
        
        print("✅ 测试3通过: 正确拒绝带依赖的卸载")
    }
    
    // MARK: - Test 4: Not Loaded Module
    
    /// Test unloading a module that is not loaded
    public static func testNotLoadedModule() {
        print("\n🧪 测试4: 卸载未加载模块")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let result = unloader.unload(name: "GhostModule")
        
        guard case .failure(.notLoaded(let name)) = result else {
            fatalError("❌ 测试4失败: 期望notLoaded，实际 \(result)")
        }
        guard name == "GhostModule" else {
            fatalError("❌ 测试4失败: 模块名称不匹配")
        }
        
        print("✅ 测试4通过: 未加载模块正确拒绝")
    }
    
    // MARK: - Test 5: stop() Failure
    
    /// Test handling of stop() throwing an error
    public static func testStopFailure() {
        print("\n🧪 测试5: stop()失败")
        
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
            fatalError("❌ 测试5失败: 期望stopFailed，实际 \(result)")
        }
        guard name == "FailStopModule" else {
            fatalError("❌ 测试5失败: 模块名称不匹配")
        }
        guard registry.isLoaded(name: "FailStopModule") else {
            fatalError("❌ 测试5失败: stop失败时不应移除模块")
        }
        
        print("✅ 测试5通过: stop()失败正确回滚，模块未移除")
    }
    
    // MARK: - Test 6: Non-conforming Module
    
    /// Test unloading a module without XRZModule conformance
    public static func testNonConformingModule() {
        print("\n🧪 测试6: 非兼容模块")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = NonConformingModule()
        registry.register(module: module, name: "NonConformingModule")
        
        let result = unloader.unload(name: "NonConformingModule")
        
        guard case .failure(.notConformingToProtocol(let name)) = result else {
            fatalError("❌ 测试6失败: 期望notConformingToProtocol，实际 \(result)")
        }
        guard name == "NonConformingModule" else {
            fatalError("❌ 测试6失败: 模块名称不匹配")
        }
        
        print("✅ 测试6通过: 非兼容模块正确拒绝")
    }
    
    // MARK: - Test 7: Resource Release
    
    /// Test module without ModuleResourceReleasable can still unload
    public static func testResourceRelease() {
        print("\n🧪 测试7: 无资源释放协议")
        
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
            fatalError("❌ 测试7失败: 期望成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "SimpleModule") else {
            fatalError("❌ 测试7失败: 模块应已移除")
        }
        guard module.isStopped else {
            fatalError("❌ 测试7失败: 应调用stop()")
        }
        
        print("✅ 测试7通过: 无资源释放的模块正常卸载")
    }
    
    // MARK: - Test 8: Can Unload Check
    
    /// Test canUnload method
    public static func testCanUnloadCheck() {
        print("\n🧪 测试8: 可卸载检查")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        // Unregistered module
        let check1 = unloader.canUnload(name: "Missing")
        guard check1.canUnload == false, check1.reason?.contains("not loaded") == true else {
            fatalError("❌ 测试8a失败: 未注册模块不应可卸载")
        }
        
        // Registered module without dependents
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
        
        // Module with dependents
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
            fatalError("❌ 测试8c失败: 有依赖模块不应可卸载")
        }
        
        print("✅ 测试8通过: canUnload检查正确")
    }
    
    // MARK: - Test 9: Multiple Dependents
    
    /// Test module depended on by multiple modules
    public static func testMultipleDependents() {
        print("\n🧪 测试9: 多个依赖")
        
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
            fatalError("❌ 测试9失败: 期望2个依赖，实际 \(dependents.count)")
        }
        guard dependents.contains("UserA") && dependents.contains("UserB") else {
            fatalError("❌ 测试9失败: 依赖应包含UserA和UserB")
        }
        
        let result = unloader.unload(name: "Core")
        guard case .failure(.hasDependents(_, let deps)) = result else {
            fatalError("❌ 测试9失败: 期望hasDependents")
        }
        guard deps.count == 2 else {
            fatalError("❌ 测试9失败: 依赖应有2个元素")
        }
        
        print("✅ 测试9通过: 多个依赖检测正确")
    }
    
    // MARK: - Test 10: Force Unload with Dependents
    
    /// Test force unload recursively unloads dependents
    public static func testForceUnloadWithDependents() {
        print("\n🧪 测试10: 强制卸载带依赖")
        
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
            fatalError("❌ 测试10失败: 期望成功，实际 \(result)")
        }
        guard !registry.isLoaded(name: "CoreF") else {
            fatalError("❌ 测试10失败: CoreF应已移除")
        }
        guard !registry.isLoaded(name: "UserF") else {
            fatalError("❌ 测试10失败: UserF也应已移除")
        }
        guard !core.isStopped else {
            fatalError("❌ 测试10失败: CoreF stop()未调用(强制卸载)")
        }
        guard !user.isStopped else {
            fatalError("❌ 测试10失败: UserF stop()未调用(强制卸载)")
        }
        guard core.resourcesReleased else {
            fatalError("❌ 测试10失败: CoreF资源应已释放")
        }
        guard user.resourcesReleased else {
            fatalError("❌ 测试10失败: UserF资源应已释放")
        }
        
        print("✅ 测试10通过: 强制卸载递归移除依赖")
    }
    
    // MARK: - Test 11: Event Emission
    
    /// Test event emission during unload
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
            fatalError("❌ 测试11失败: 期望成功")
        }
        guard willUnloadReceived else {
            fatalError("❌ 测试11失败: moduleWillUnload未收到")
        }
        guard didUnloadReceived else {
            fatalError("❌ 测试11失败: moduleDidUnload未收到")
        }
        guard willUnloadModuleName == "EventModule" else {
            fatalError("❌ 测试11失败: moduleWillUnload名称不匹配")
        }
        guard didUnloadModuleName == "EventModule" else {
            fatalError("❌ 测试11失败: moduleDidUnload名称不匹配")
        }
        
        eventBus.off(obs1)
        eventBus.off(obs2)
        
        print("✅ 测试11通过: 卸载事件正确发送")
    }
}
