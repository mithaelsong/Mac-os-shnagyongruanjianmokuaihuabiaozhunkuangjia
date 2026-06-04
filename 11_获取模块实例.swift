// 功能11: 获取模块实例
// 对应: 安全的模块实例访问
// 优先级: P0

import Foundation
import os.lock

// MARK: - ModuleAccessor 错误
/// 模块访问器操作中可能发生的错误
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
/// 模块访问器 (功能11)
/// 提供安全的模块实例访问，是其他模块获取模块实例和服务的统一入口
/// 特性:
/// - 通过 ModuleRegistry 获取模块实例
/// - 通过 ModuleStarter 检查启动状态
/// - 通过 ServiceRegistry 获取模块提供的服务（框架推荐方式）
/// - 类型安全的泛型获取方法
/// - 线程安全（os_unfair_lock 保护）
/// - 使用 ModuleLogger 记录所有访问操作
public final class ModuleAccessor: Sendable {
    public static let shared = ModuleAccessor()

    private let registry: ModuleRegistry
    private let starter: ModuleStarter
    private let logger: ModuleLogger

    /// 线程安全锁
    private final class LockStorage: @unchecked Sendable {
        var lock = os_unfair_lock()
    }

    private let lockStorage = LockStorage()

    /// 私有初始化，使用共享实例
    private init() {
        self.registry = ModuleRegistry.shared
        self.starter = ModuleStarter(
            registry: ModuleRegistry.shared,
            logger: ModuleLogger(category: "ModuleAccessor")
        )
        self.logger = ModuleLogger(category: "ModuleAccessor")
    }

    /// 支持注入的初始化（用于测试或自定义场景）
    /// - Parameters:
    ///   - registry: 模块注册表
    ///   - starter: 模块启动器
    public init(registry: ModuleRegistry, starter: ModuleStarter) {
        self.registry = registry
        self.starter = starter
        self.logger = ModuleLogger(category: "ModuleAccessor")
    }

    // MARK: - 获取模块实例

    /// 获取指定名称的模块实例
    /// - Parameter name: 模块名称
    /// - Returns: 模块实例，如果不存在返回 nil
    public func getModule(_ name: String) -> Any? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("获取模块实例: \(name)")
        return registry.getModule(named: name)
    }

    // MARK: - 类型安全获取模块

    /// 类型安全地获取指定名称的模块实例
    /// - Parameter name: 模块名称
    /// - Returns: 类型匹配后的模块实例，如果不存在或类型不匹配返回 nil
    public func getModuleAs<T>(_ name: String) -> T? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("类型安全获取模块: \(name) as \(String(describing: T.self))")

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

    // MARK: - 获取服务

    /// 获取指定模块提供的指定服务
    /// 通过 ServiceRegistry 查找服务实例（模块在 start() 中通过 registerService 注册）
    /// - Parameters:
    ///   - module: 模块名称
    ///   - service: 服务名称
    /// - Returns: 服务实例，如果不存在或模块未加载返回 nil
    public func getService(_ module: String, _ service: String) -> Any? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("获取服务: \(module).\(service)")

        // 检查模块是否已加载
        guard registry.isLoaded(name: module) else {
            logger.warning("无法获取服务 \(module).\(service): 模块未加载")
            return nil
        }

        // 通过 ServiceRegistry 获取（Any.self 用于获取任意类型实例）
        let result = ServiceRegistry.shared.resolve(
            moduleName: module,
            serviceName: service,
            type: Any.self
        )

        if result == nil {
            logger.warning("服务 \(module).\(service) 未找到")
        } else {
            logger.debug("获取到服务 \(module).\(service)")
        }

        return result
    }

    // MARK: - 类型安全获取服务

    /// 类型安全地获取指定模块提供的指定服务
    /// - Parameters:
    ///   - module: 模块名称
    ///   - service: 服务名称
    /// - Returns: 类型匹配后的服务实例，如果不存在、类型不匹配或模块未加载返回 nil
    public func getModuleService<T>(_ module: String, _ service: String) -> T? {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        logger.debug("类型安全获取服务: \(module).\(service) as \(String(describing: T.self))")

        // 检查模块是否已加载
        guard registry.isLoaded(name: module) else {
            logger.warning("无法获取服务 \(module).\(service): 模块未加载")
            return nil
        }

        // 通过 ServiceRegistry 类型安全获取
        let result: T? = ServiceRegistry.shared.resolve(
            moduleName: module,
            serviceName: service,
            type: T.self
        )

        if result == nil {
            logger.warning("类型安全服务 \(module).\(service) as \(String(describing: T.self)) 未找到")
        } else {
            logger.debug("获取到类型安全服务 \(module).\(service)")
        }

        return result
    }

    // MARK: - 检查加载状态

    /// 检查指定模块是否已加载到注册表
    /// - Parameter name: 模块名称
    /// - Returns: 是否已加载
    public func isModuleLoaded(_ name: String) -> Bool {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        let loaded = registry.isLoaded(name: name)
        logger.debug("检查模块加载状态: \(name) = \(loaded)")
        return loaded
    }

    // MARK: - 检查启动状态

    /// 检查指定模块是否已启动
    /// - Parameter name: 模块名称
    /// - Returns: 是否已启动
    public func isModuleStarted(_ name: String) -> Bool {
        os_unfair_lock_lock(&lockStorage.lock)
        defer { os_unfair_lock_unlock(&lockStorage.lock) }

        let started = starter.isStarted(name)
        logger.debug("检查模块启动状态: \(name) = \(started)")
        return started
    }
}

// MARK: - 测试代码

/// ModuleAccessor 功能验证测试
/// 运行方式：在单元测试或 Playground 中调用 `ModuleAccessorTests.runAllTests()`
public enum ModuleAccessorTests {

    // MARK: - 测试协议

    /// 模拟服务协议
    public protocol DataService {
        func fetch() -> String
    }

    // MARK: - 测试模块

    /// 实现生命周期协议和服务协议的测试模块
    public final class MockDataModule: XRZModule, DataService {
        public func start() throws {}
        public func stop() throws {}
        public func fetch() -> String { "MockData" }
    }

    /// 仅作为普通实例的测试模块（不实现 XRZModule）
    public final class MockPlainModule {
        public let value = 42
    }

    // MARK: - 辅助方法

    /// 清理全局注册表和服务注册表中的所有测试数据
    private static func cleanup() {
        let registry = ModuleRegistry.shared
        let serviceRegistry = ServiceRegistry.shared
        let names = registry.allModuleNames
        for name in names {
            serviceRegistry.unregisterAll(moduleName: name)
            registry.unregister(name: name)
        }
    }

    /// 运行所有测试
    public static func runAllTests() {
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

        print("\n🎉 所有 ModuleAccessor 测试通过!")
    }

    // MARK: - 测试1: 获取模块实例

    /// 验证 getModule 能正确获取已加载模块，对未加载模块返回 nil
    public static func testGetModule() {
        print("\n🧪 测试1: 获取模块实例")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "DataModule")

        // 获取已加载模块
        guard let retrieved = accessor.getModule("DataModule") else {
            fatalError("❌ 测试1失败: 无法获取已加载模块 DataModule")
        }
        guard retrieved is MockDataModule else {
            fatalError("❌ 测试1失败: 获取的模块类型不匹配")
        }

        // 获取未加载模块应返回 nil
        guard accessor.getModule("NonExistent") == nil else {
            fatalError("❌ 测试1失败: 未加载模块应返回 nil")
        }

        print("✅ 测试1通过: 获取模块实例正确")
    }

    // MARK: - 测试2: 类型安全获取模块

    /// 验证 getModuleAs 能正确按类型匹配，类型不匹配时返回 nil
    public static func testGetModuleAs() {
        print("\n🧪 测试2: 类型安全获取模块")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "TypedModule")

        // 正确类型获取
        let typed: MockDataModule? = accessor.getModuleAs("TypedModule")
        guard typed != nil else {
            fatalError("❌ 测试2失败: 类型安全获取失败")
        }
        guard typed?.fetch() == "MockData" else {
            fatalError("❌ 测试2失败: 获取的模块数据不正确")
        }

        // 错误类型应返回 nil
        let wrongType: String? = accessor.getModuleAs("TypedModule")
        guard wrongType == nil else {
            fatalError("❌ 测试2失败: 错误类型应返回 nil")
        }

        // 未加载模块应返回 nil
        let nonExistent: MockDataModule? = accessor.getModuleAs("NonExistent")
        guard nonExistent == nil else {
            fatalError("❌ 测试2失败: 未加载模块类型安全获取应返回 nil")
        }

        print("✅ 测试2通过: 类型安全获取模块正确")
    }

    // MARK: - 测试3: 获取服务

    /// 验证 getService 通过 ServiceRegistry 获取服务，对不存在/未加载模块返回 nil
    public static func testGetService() {
        print("\n🧪 测试3: 获取服务")

        let registry = ModuleRegistry.shared
        let serviceRegistry = ServiceRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "ServiceModule")

        // 注册服务到 ServiceRegistry
        serviceRegistry.register(
            module,
            serviceName: "DataService",
            moduleName: "ServiceModule",
            version: "1.0.0",
            protocolType: DataService.self
        )

        // 获取已注册服务
        guard let service = accessor.getService("ServiceModule", "DataService") else {
            fatalError("❌ 测试3失败: 无法获取服务")
        }
        guard service is DataService else {
            fatalError("❌ 测试3失败: 服务类型不匹配")
        }

        // 获取不存在的服务应返回 nil
        guard accessor.getService("ServiceModule", "NonExistent") == nil else {
            fatalError("❌ 测试3失败: 不存在服务应返回 nil")
        }

        // 未加载模块的服务应返回 nil
        guard accessor.getService("NonExistent", "DataService") == nil else {
            fatalError("❌ 测试3失败: 未加载模块的服务应返回 nil")
        }

        print("✅ 测试3通过: 获取服务正确")
    }

    // MARK: - 测试4: 类型安全获取服务

    /// 验证 getModuleService 能正确按类型获取服务，类型不匹配时返回 nil
    public static func testGetModuleServiceTyped() {
        print("\n🧪 测试4: 类型安全获取服务")

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

        // 正确类型获取
        let typed: DataService? = accessor.getModuleService("TypedServiceModule", "DataService")
        guard typed != nil else {
            fatalError("❌ 测试4失败: 类型安全获取服务失败")
        }
        guard typed?.fetch() == "MockData" else {
            fatalError("❌ 测试4失败: 服务数据不正确")
        }

        // 错误类型应返回 nil
        let wrongType: String? = accessor.getModuleService("TypedServiceModule", "DataService")
        guard wrongType == nil else {
            fatalError("❌ 测试4失败: 错误类型服务应返回 nil")
        }

        // 不存在服务应返回 nil
        let nonExistent: DataService? = accessor.getModuleService("TypedServiceModule", "NonExistent")
        guard nonExistent == nil else {
            fatalError("❌ 测试4失败: 不存在服务应返回 nil")
        }

        print("✅ 测试4通过: 类型安全获取服务正确")
    }

    // MARK: - 测试5: 检查加载状态

    /// 验证 isModuleLoaded 能正确反映注册表中的加载状态
    public static func testIsModuleLoaded() {
        print("\n🧪 测试5: 检查加载状态")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        let module = MockDataModule()
        registry.register(module: module, name: "LoadCheckModule")

        guard accessor.isModuleLoaded("LoadCheckModule") == true else {
            fatalError("❌ 测试5失败: 已加载模块应返回 true")
        }
        guard accessor.isModuleLoaded("NonExistent") == false else {
            fatalError("❌ 测试5失败: 未加载模块应返回 false")
        }

        // 注销后检查
        registry.unregister(name: "LoadCheckModule")
        guard accessor.isModuleLoaded("LoadCheckModule") == false else {
            fatalError("❌ 测试5失败: 注销后模块应返回 false")
        }

        print("✅ 测试5通过: 加载状态检查正确")
    }

    // MARK: - 测试6: 检查启动状态

    /// 验证 isModuleStarted 能正确反映模块启动状态
    /// 使用注入的 ModuleStarter 确保状态一致
    public static func testIsModuleStarted() {
        print("\n🧪 测试6: 检查启动状态")

        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestAccessor"))
        let accessor = ModuleAccessor(registry: registry, starter: starter)

        let module = MockDataModule()
        registry.register(module: module, name: "StartCheckModule")

        // 未启动时应返回 false
        guard accessor.isModuleStarted("StartCheckModule") == false else {
            fatalError("❌ 测试6失败: 未启动模块应返回 false")
        }

        // 启动模块
        let result = starter.startModule("StartCheckModule")
        guard result.isSuccess else {
            fatalError("❌ 测试6失败: 模块启动失败: \(result)")
        }

        // 已启动时应返回 true
        guard accessor.isModuleStarted("StartCheckModule") == true else {
            fatalError("❌ 测试6失败: 已启动模块应返回 true")
        }

        print("✅ 测试6通过: 启动状态检查正确")
    }

    // MARK: - 测试7: 线程安全

    /// 验证 100 个并发读取操作下 ModuleAccessor 的线程安全性
    public static func testThreadSafety() {
        print("\n🧪 测试7: 线程安全")

        let registry = ModuleRegistry.shared
        let accessor = ModuleAccessor.shared

        // 注册 100 个模块
        for i in 0..<100 {
            registry.register(module: MockDataModule(), name: "Concurrent\(i)")
        }

        let group = DispatchGroup()
        var successCount = 0
        let countLock = NSLock()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                // 并发读取模块实例
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
            fatalError("❌ 测试7失败: 期望 100 次成功获取，实际 \(successCount)")
        }

        print("✅ 测试7通过: 线程安全 (100 并发读取)")
    }
}

// MARK: - 使用示例
/*
 // 1. 获取模块实例（不指定类型）
 if let module = ModuleAccessor.shared.getModule("MarketModule") {
     print("MarketModule 已加载: \(type(of: module))")
 }

 // 2. 类型安全获取模块
 if let market: MarketModule = ModuleAccessor.shared.getModuleAs("MarketModule") {
     market.refreshData()
 }

 // 3. 获取服务（不指定类型）
 if let service = ModuleAccessor.shared.getService("MarketModule", "DataSource") {
     print("DataSource 服务类型: \(type(of: service))")
 }

 // 4. 类型安全获取服务
 if let ds: DataSourceService = ModuleAccessor.shared.getModuleService("MarketModule", "DataSource") {
     let data = ds.fetchData(symbol: "BTC")
 }

 // 5. 检查状态
 let loaded = ModuleAccessor.shared.isModuleLoaded("MarketModule")
 let started = ModuleAccessor.shared.isModuleStarted("MarketModule")
 print("MarketModule loaded=\(loaded), started=\(started)")

 // 6. 测试运行
 ModuleAccessorTests.runAllTests()
 */
