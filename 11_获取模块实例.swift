// 功能11: 获取模块实例
// Purpose: Safe module instance access
// Priority: P0

import Foundation
import os

// MARK: - ModuleAccessor Error
/// Errors that can occur during module accessor operations
public enum ModuleAccessorError: Error, CustomStringConvertible {
    case moduleNotLoaded(name: String)
    case serviceNotFound(module: String, service: String)
    case typeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .moduleNotLoaded(let name):
            return "模块未加载: \(name)"
        case .serviceNotFound(let module, let service):
            return "模块 \(module) 未提供服务: \(service)"
        case .typeMismatch(let expected, let actual):
            return "类型不匹配: 期望 \(expected), 实际 \(actual)"
        }
    }
}

// MARK: - ModuleAccessor
/// Module Accessor (Function 11)
/// Provides safe module instance access as the unified entry point
/// Features:
/// - Get module instances via ModuleRegistry
/// - Check start status via ModuleStarter
/// - Get module services via ServiceRegistry (recommended)
/// - Type-safe generic access methods
/// - Thread-safe (protected by os_unfair_lock)
/// - Logs access operations via ModuleLogger
public final class ModuleAccessor: Sendable {
    public static let shared = ModuleAccessor()

    private let registry: ModuleRegistry
    private let starter: ModuleStarter
    private let logger: ModuleLogger

    /// Thread-safety lock
    private final class LockStorage: @unchecked Sendable {
        var lock = os_unfair_lock()
    }

    private let lockStorage = LockStorage()

    /// Private initializer using shared instance
    private init() {
        self.registry = ModuleRegistry.shared
        self.starter = ModuleStarter(
            registry: ModuleRegistry.shared,
            logger: ModuleLogger(category: "ModuleAccessor")
        )
        self.logger = ModuleLogger(category: "ModuleAccessor")
    }

    /// Injectable initializer (for testing or custom scenarios)
    /// - Parameters:
    ///   - registry: Module registry
    ///   - starter: Module starter
    public init(registry: ModuleRegistry, starter: ModuleStarter) {
        self.registry = registry
        self.starter = starter
        self.logger = ModuleLogger(category: "ModuleAccessor")
    }

    // MARK: - Getting Module Instance

    /// Get module instance by name
    /// - Parameter name: Module name
    /// - Returns: Module instance, or nil if not found
    public func getModule(_ name: String) -> Any? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("获取模块: \(name)")
        return registry.getModule(named: name)
    }

    // MARK: - Type-Safe Module Access

    /// Type-safely get module instance by name
    /// - Parameter name: Module name
    /// - Returns: Typed module instance, or nil if not found or type mismatch
    public func getModuleAs<T>(_ name: String) -> T? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("类型安全获取模块: \(name) 为 \(String(describing: T.self))")

        guard let module = registry.getModule(named: name) else {
            logger.warning("模块 \(name) 未加载，无法获取")
            return nil
        }

        guard let typed = module as? T else {
            logger.error("模块 \(name) 类型不匹配: 期望 \(String(describing: T.self)), 实际 \(type(of: module))")
            return nil
        }

        return typed
    }

    // MARK: - Getting Services

    /// Get a service provided by a module
    /// Find service via ServiceRegistry (registered in start() via registerService)
    /// - Parameters:
    ///   - module: Module name
    ///   - service: Service name
    /// - Returns: Service instance, or nil if not found or module not loaded
    public func getService(_ module: String, _ service: String) -> Any? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("获取服务: \(module).\(service)")

        // Check if module is loaded
        guard registry.isLoaded(name: module) else {
            logger.warning("无法获取服务 \(module).\(service): 模块未加载")
            return nil
        }

        // Get via ServiceRegistry (Any.self for untyped access)
        let result = ServiceRegistry.shared.resolve(
            moduleName: module,
            serviceName: service,
            protocolType: Any.self
        )

        if result == nil {
            logger.warning("服务 \(module).\(service) 未找到")
        } else {
            logger.debug("已获取服务 \(module).\(service)")
        }

        return result
    }

    // MARK: - Type-Safe Service Access

    /// Type-safely get a service from a module
    /// - Parameters:
    ///   - module: Module name
    ///   - service: Service name
    /// - Returns: Typed service instance, or nil if not found/type mismatch/module not loaded
    public func getModuleService<T>(_ module: String, _ service: String) -> T? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("类型安全获取服务: \(module).\(service) 为 \(String(describing: T.self))")

        // Check if module is loaded
        guard registry.isLoaded(name: module) else {
            logger.warning("无法获取服务 \(module).\(service): 模块未加载")
            return nil
        }

        // Get via ServiceRegistry type-safe
        let result: T? = ServiceRegistry.shared.resolve(
            moduleName: module,
            serviceName: service,
            protocolType: T.self
        )

        if result == nil {
            logger.warning("类型安全服务 \(module).\(service) 为 \(String(describing: T.self)) 未找到")
        } else {
            logger.debug("已获取类型安全服务 \(module).\(service)")
        }

        return result
    }

    // MARK: - Status Check

    /// Check if module is loaded in registry
    /// - Parameter name: Module name
    /// - Returns: Whether loaded
    public func isModuleLoaded(_ name: String) -> Bool {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        let loaded = registry.isLoaded(name: name)
        logger.debug("检查模块加载状态: \(name) = \(loaded)")
        return loaded
    }

    // MARK: - Start Status Check

    /// Check if module has started
    /// - Parameter name: Module name
    /// - Returns: Whether started
    public func isModuleStarted(_ name: String) -> Bool {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        let started = starter.isStarted(name)
        logger.debug("检查模块启动状态: \(name) = \(started)")
        return started
    }
}

// MARK: - Test Code

/// ModuleAccessor functional verification tests
/// Run: `ModuleAccessorTests.runAllTests()` in unit tests or playground
public enum ModuleAccessorTests {

    // MARK: - Test Protocol

    /// Mock service protocol
    public protocol DataService {
        func fetch() -> String
    }

    // MARK: - Test Modules

    /// Module implementing both lifecycle and service protocols
    public final class MockDataModule: XRZModule, DataService {
        public func start() throws {}
        public func stop() throws {}
        public func fetch() -> String { "MockData" }
    }

    /// Plain module (does not implement XRZModule)
    public final class MockPlainModule {
        public let value = 42
    }

    // MARK: - Helper Methods

    /// Clean all test data from registry and service registry
    private static func cleanup() {
        let registry = ModuleRegistry.shared
        let serviceRegistry = ServiceRegistry.shared
        let names = registry.allModuleNames
        for name in names {
            serviceRegistry.unregisterAll(moduleName: name)
            registry.unregister(name: name)
        }
    }

    /// Run all tests
    public static func runAllTests() {
        print("=== 功能11测试 ===")
        cleanup()
        testGetModule()
        cleanup()

        testGetModuleAs()
        cleanup()

        testGetService()
        cleanup()

        testGetModuleServiceTyped()
        cleanup()

        testIsModuleLoaded()
        cleanup()

        testIsModuleStarted()
        cleanup()

        testThreadSafety()
        cleanup()

        print("\n=== 全部功能11测试通过 ✅ ===")
    }

    // MARK: - Test 1: Get Module Instance

    /// Verify getModule returns module for loaded and nil for unloaded
    public static func testGetModule() {
        print("\n🧪 测试1: 获取模块实例")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "DataModule")

        // Get loaded module
        guard let retrieved = accessor.getModule("DataModule") else {
            fatalError("❌ 测试1失败: 无法获取已加载模块DataModule")
        }
        guard retrieved is MockDataModule else {
            fatalError("❌ 测试1失败: 获取的模块类型不匹配")
        }

        // Get unloaded module should return nil
        guard accessor.getModule("NonExistent") == nil else {
            fatalError("❌ 测试1失败: 未加载模块应返回nil")
        }

        print("✅ 测试1通过: 获取模块实例正确")
    }

    // MARK: - Test 2: Type-Safe Module Access

    /// Verify getModuleAs matches type correctly, nil on mismatch
    public static func testGetModuleAs() {
        print("\n🧪 测试2: 类型安全模块访问")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "TypedModule")

        // Correct type access
        let typed: MockDataModule? = accessor.getModuleAs("TypedModule")
        guard typed != nil else {
            fatalError("❌ 测试2失败: 类型安全访问失败")
        }
        guard typed?.fetch() == "MockData" else {
            fatalError("❌ 测试2失败: 获取的模块数据不正确")
        }

        // Wrong type should return nil
        let wrongType: String? = accessor.getModuleAs("TypedModule")
        guard wrongType == nil else {
            fatalError("❌ 测试2失败: 错误类型应返回nil")
        }

        // Unloaded module should return nil
        let nonExistent: MockDataModule? = accessor.getModuleAs("NonExistent")
        guard nonExistent == nil else {
            fatalError("❌ 测试2失败: 未加载模块类型安全访问应返回nil")
        }

        print("✅ 测试2通过: 类型安全模块访问正确")
    }

    // MARK: - Test 3: Get Service

    /// Verify getService returns nil for missing/unloaded services
    public static func testGetService() {
        print("\n🧪 测试3: 获取服务")

        let registry = ModuleRegistry.shared
        let serviceRegistry = ServiceRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "ServiceModule")

        // Register service to ServiceRegistry
        serviceRegistry.register(
            module,
            serviceName: "DataService",
            moduleName: "ServiceModule",
            version: "1.0.0",
            protocolType: DataService.self
        )

        // Get registered service
        guard let service = accessor.getService("ServiceModule", "DataService") else {
            fatalError("❌ 测试3失败: 无法获取服务")
        }
        guard service is DataService else {
            fatalError("❌ 测试3失败: 服务类型不匹配")
        }

        // Non-existent service should return nil
        guard accessor.getService("ServiceModule", "NonExistent") == nil else {
            fatalError("❌ 测试3失败: 不存在的服务应返回nil")
        }

        // Unloaded module service should return nil
        guard accessor.getService("NonExistent", "DataService") == nil else {
            fatalError("❌ 测试3失败: 未加载模块的服务应返回nil")
        }

        print("✅ 测试3通过: 获取服务正确")
    }

    // MARK: - Test 4: Type-Safe Service Access

    /// Verify getModuleService returns nil on type mismatch
    public static func testGetModuleServiceTyped() {
        print("\n🧪 测试4: 类型安全服务访问")

        let registry = ModuleRegistry.shared
        let serviceRegistry = ServiceRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "TypedServiceModule")

        serviceRegistry.register(
            module,
            serviceName: "DataService",
            moduleName: "TypedServiceModule",
            version: "1.0.0",
            protocolType: DataService.self
        )

        // Correct type access
        let typed: DataService? = accessor.getModuleService("TypedServiceModule", "DataService")
        guard typed != nil else {
            fatalError("❌ 测试4失败: 类型安全服务获取失败")
        }
        guard typed?.fetch() == "MockData" else {
            fatalError("❌ 测试4失败: 服务数据不正确")
        }

        // Wrong type should return nil
        let wrongType: String? = accessor.getModuleService("TypedServiceModule", "DataService")
        guard wrongType == nil else {
            fatalError("❌ 测试4失败: 错误类型服务应返回nil")
        }

        // Non-existent service should return nil
        let nonExistent: DataService? = accessor.getModuleService("TypedServiceModule", "NonExistent")
        guard nonExistent == nil else {
            fatalError("❌ 测试4失败: 不存在的服务应返回nil")
        }

        print("✅ 测试4通过: 类型安全服务访问正确")
    }

    // MARK: - Test 5: Load Status

    /// Verify isModuleLoaded reflects registry state
    public static func testIsModuleLoaded() {
        print("\n🧪 测试5: 加载状态")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "LoadCheckModule")

        guard accessor.isModuleLoaded("LoadCheckModule") == true else {
            fatalError("❌ 测试5失败: 已加载模块应返回true")
        }
        guard accessor.isModuleLoaded("NonExistent") == false else {
            fatalError("❌ 测试5失败: 未加载模块应返回false")
        }

        // Check after unregister
        registry.unregister(name: "LoadCheckModule")
        guard accessor.isModuleLoaded("LoadCheckModule") == false else {
            fatalError("❌ 测试5失败: 未注册模块应返回false")
        }

        print("✅ 测试5通过: 加载状态正确")
    }

    // MARK: - Test 6: Start Status

    /// Verify isModuleStarted reflects start state
    /// Use injected starter for consistent state
    public static func testIsModuleStarted() {
        print("\n🧪 测试6: 启动状态")

        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestAccessor"))
        let accessor = ModuleAccessor(registry: registry, starter: starter)

        let module = MockDataModule()
        registry.register(module: module, name: "StartCheckModule")

        // Not started should return false
        guard accessor.isModuleStarted("StartCheckModule") == false else {
            fatalError("❌ 测试6失败: 未启动模块应返回false")
        }

        // Start module
        let result = starter.startModule("StartCheckModule")
        guard result.isSuccess else {
            fatalError("❌ 测试6失败: 模块启动失败: \(result)")
        }

        // Started should return true
        guard accessor.isModuleStarted("StartCheckModule") == true else {
            fatalError("❌ 测试6失败: 已启动模块应返回true")
        }

        print("✅ 测试6通过: 启动状态正确")
    }

    // MARK: - Test 7: Thread Safety

    /// Verify thread safety with 100 concurrent reads
    public static func testThreadSafety() {
        print("\n🧪 测试7: 线程安全")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        // Register 100 modules
        for i in 0..<100 {
            registry.register(module: MockDataModule(), name: "Concurrent\(i)")
        }

        let group = DispatchGroup()
        var successCount = 0
        let countLock = NSLock()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                // Concurrent reads
                if accessor.getModule("Concurrent\(i)") != nil {
                    countLock.lock()
                    successCount += 1
                    countLock.unlock()
                }
                group.leave()
            }
        }

        group.wait()

        guard successCount == 100 else {
            fatalError("❌ 测试7失败: 期望100次成功获取，实际 \(successCount)")
        }

        print("✅ 测试7通过: 线程安全(100并发读取)")
    }
}

// MARK: - Usage Example
/*
 // 1. Get module instance (untyped)
 if let module = ModuleAccessor.shared.getModule("MarketModule") {
     print("MarketModule loaded: \(type(of: module))")
 }

 // 2. Type-safe module access
 if let market: MarketModule = ModuleAccessor.shared.getModuleAs("MarketModule") {
     market.refreshData()
 }

 // 3. Get service (untyped)
 if let service = ModuleAccessor.shared.getService("MarketModule", "DataSource") {
     print("DataSource service type: \(type(of: service))")
 }

 // 4. Type-safe service access
 if let ds: DataSourceService = ModuleAccessor.shared.getModuleService("MarketModule", "DataSource") {
     let data = ds.fetchData(symbol: "BTC")
 }

 // 5. Check status
 let loaded = ModuleAccessor.shared.isModuleLoaded("MarketModule")
 let started = ModuleAccessor.shared.isModuleStarted("MarketModule")
 print("MarketModule loaded=\(loaded), started=\(started)")

 // 6. Run tests
 ModuleAccessorTests.runAllTests()
 */
