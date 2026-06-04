// 功能8: 模块注册表
// 对应: 记录已加载的模块（模块名 → 模块实例）
// 优先级: P0

import Foundation
import os.lock

// MARK: - 模块元数据
/// 模块元数据结构体，用于描述模块的基本信息
public struct ModuleMetadata: Codable, Sendable {
    public let name: String
    public let version: String
    public let description: String
    public let entryClass: String
    public let priority: Int
    public let author: String?
    public let dependencies: [String]
    
    public init(
        name: String,
        version: String,
        description: String,
        entryClass: String,
        priority: Int = 100,
        author: String? = nil,
        dependencies: [String] = []
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.entryClass = entryClass
        self.priority = priority
        self.author = author
        self.dependencies = dependencies
    }
}

// MARK: - 模块注册表
/// 模块注册表 (功能8)
/// 全局单例，所有模块通过它发现其他模块
/// 使用 os_unfair_lock 保证线程安全和高性能
public final class ModuleRegistry: Sendable {
    public static let shared = ModuleRegistry()
    
    /// 线程安全的模块存储包装
    private final class ModuleStorage: @unchecked Sendable {
        var modules: [String: Any] = [:]
        var metadataMap: [String: ModuleMetadata] = [:]
        var lock = os_unfair_lock()
    }
    
    private let storage = ModuleStorage()
    private let logger = ModuleLogger(category: "ModuleRegistry")
    
    private init() {}
    
    // MARK: - 注册模块
    /// 注册一个模块到注册表
    /// - Parameters:
    ///   - module: 模块实例
    ///   - name: 模块名称
    ///   - metadata: 模块元数据（可选）
    public func register(module: Any, name: String, metadata: ModuleMetadata? = nil) {
        os_unfair_lock_lock(&storage.lock)
        storage.modules[name] = module
        if let meta = metadata {
            storage.metadataMap[name] = meta
        }
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("Registered module: \(name)")
    }
    
    // MARK: - 注销模块
    /// 从注册表注销一个模块
    /// - Parameter name: 模块名称
    public func unregister(name: String) {
        os_unfair_lock_lock(&storage.lock)
        storage.modules.removeValue(forKey: name)
        storage.metadataMap.removeValue(forKey: name)
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("Unregistered module: \(name)")
    }
    
    // MARK: - 获取模块
    /// 获取指定名称的模块实例
    /// - Parameter name: 模块名称
    /// - Returns: 模块实例，如果不存在返回 nil
    public func getModule(named name: String) -> Any? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]
    }
    
    // MARK: - 获取模块元数据
    /// 获取指定名称的模块元数据
    /// - Parameter name: 模块名称
    /// - Returns: 模块元数据，如果不存在返回 nil
    public func getMetadata(named name: String) -> ModuleMetadata? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.metadataMap[name]
    }
    
    // MARK: - 检查模块是否已加载
    /// 检查指定名称的模块是否已加载到注册表
    /// - Parameter name: 模块名称
    /// - Returns: 是否已加载
    public func isLoaded(name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name] != nil
    }
    
    // MARK: - 获取所有模块名
    /// 获取当前注册表中所有模块的名称列表
    public var allModuleNames: [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return Array(storage.modules.keys)
    }
    
    // MARK: - 按类型获取模块
    /// 获取所有符合指定类型的模块
    /// - Parameter type: 目标类型
    /// - Returns: 符合类型的模块名称和实例的数组
    public func getModules<T>(conformingTo type: T.Type) -> [(name: String, module: T)] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return storage.modules.compactMap { (name, module) in
            guard let typed = module as? T else { return nil }
            return (name: name, module: typed)
        }
    }
    
    // MARK: - 获取模块统计
    /// 获取注册表的统计信息
    public var stats: ModuleRegistryStats {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return ModuleRegistryStats(
            totalModules: storage.modules.count,
            loadedModules: storage.modules.count,
            moduleNames: Array(storage.modules.keys)
        )
    }
}

// MARK: - 注册表统计信息
/// 模块注册表统计信息
public struct ModuleRegistryStats: Sendable {
    public let totalModules: Int
    public let loadedModules: Int
    public let moduleNames: [String]
}

// MARK: - 测试代码
/// 简单的模块注册表功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ModuleRegistryTests.run()`
public enum ModuleRegistryTests {
    
    /// 示例模块协议
    public protocol TestModuleProtocol {
        func greet() -> String
    }
    
    /// 示例模块 A
    public final class TestModuleA: TestModuleProtocol {
        public func greet() -> String { "Hello from ModuleA" }
    }
    
    /// 示例模块 B
    public final class TestModuleB: TestModuleProtocol {
        public func greet() -> String { "Hello from ModuleB" }
    }
    
    /// 非协议模块
    public final class TestModuleC {
        public let value = 42
    }
    
    /// 运行所有测试
    public static func run() {
        print("=== ModuleRegistry Tests ===")
        
        let registry = ModuleRegistry.shared
        
        // 1. 测试注册
        let metaA = ModuleMetadata(
            name: "ModuleA",
            version: "1.0.0",
            description: "Test module A",
            entryClass: "TestModuleA",
            priority: 10
        )
        registry.register(module: TestModuleA(), name: "ModuleA", metadata: metaA)
        print("✅ Register: ModuleA registered")
        
        let metaB = ModuleMetadata(
            name: "ModuleB",
            version: "2.0.0",
            description: "Test module B",
            entryClass: "TestModuleB",
            priority: 20
        )
        registry.register(module: TestModuleB(), name: "ModuleB", metadata: metaB)
        print("✅ Register: ModuleB registered")
        
        registry.register(module: TestModuleC(), name: "ModuleC")
        print("✅ Register: ModuleC registered (no metadata)")
        
        // 2. 测试获取模块
        guard registry.isLoaded(name: "ModuleA") == true else {
            fatalError("❌ isLoaded: ModuleA should be loaded")
        }
        guard registry.isLoaded(name: "ModuleB") == true else {
            fatalError("❌ isLoaded: ModuleB should be loaded")
        }
        guard registry.isLoaded(name: "ModuleC") == true else {
            fatalError("❌ isLoaded: ModuleC should be loaded")
        }
        guard registry.isLoaded(name: "NonExistent") == false else {
            fatalError("❌ isLoaded: NonExistent should not be loaded")
        }
        print("✅ isLoaded: All checks passed")
        
        // 3. 测试获取实例
        guard let moduleA = registry.getModule(named: "ModuleA") as? TestModuleA else {
            fatalError("❌ getModule: ModuleA not found or wrong type")
        }
        print("✅ getModule: ModuleA retrieved")
        
        // 4. 测试获取元数据
        guard let retrievedMetaA = registry.getMetadata(named: "ModuleA") else {
            fatalError("❌ getMetadata: ModuleA metadata not found")
        }
        guard retrievedMetaA.name == "ModuleA" else {
            fatalError("❌ getMetadata: ModuleA name mismatch")
        }
        guard retrievedMetaA.version == "1.0.0" else {
            fatalError("❌ getMetadata: ModuleA version mismatch")
        }
        guard retrievedMetaA.priority == 10 else {
            fatalError("❌ getMetadata: ModuleA priority mismatch")
        }
        print("✅ getMetadata: ModuleA metadata correct")
        
        guard registry.getMetadata(named: "ModuleC") == nil else {
            fatalError("❌ getMetadata: ModuleC should have no metadata")
        }
        print("✅ getMetadata: ModuleC has no metadata (as expected)")
        
        // 5. 测试获取所有模块名
        let allNames = registry.allModuleNames.sorted()
        guard allNames == ["ModuleA", "ModuleB", "ModuleC"] else {
            fatalError("❌ allModuleNames: expected [ModuleA, ModuleB, ModuleC], got \(allNames)")
        }
        print("✅ allModuleNames: \(allNames)")
        
        // 6. 测试按类型获取
        let protocolModules = registry.getModules(conformingTo: TestModuleProtocol.self)
        guard protocolModules.count == 2 else {
            fatalError("❌ getModules: expected 2 protocol modules, got \(protocolModules.count)")
        }
        let protocolNames = protocolModules.map(\.name).sorted()
        guard protocolNames == ["ModuleA", "ModuleB"] else {
            fatalError("❌ getModules: expected [ModuleA, ModuleB], got \(protocolNames)")
        }
        print("✅ getModules(conformingTo:): Found \(protocolModules.count) protocol modules")
        
        for (name, mod) in protocolModules {
            print("   - \(name): \(mod.greet())")
        }
        
        // 7. 测试注销
        registry.unregister(name: "ModuleB")
        guard registry.isLoaded(name: "ModuleB") == false else {
            fatalError("❌ unregister: ModuleB should not be loaded")
        }
        guard registry.getMetadata(named: "ModuleB") == nil else {
            fatalError("❌ unregister: ModuleB metadata should be removed")
        }
        print("✅ unregister: ModuleB removed")
        
        // 8. 测试统计
        let stats = registry.stats
        guard stats.totalModules == 2 else {
            fatalError("❌ stats: expected 2 modules, got \(stats.totalModules)")
        }
        let statsNames = stats.moduleNames.sorted()
        guard statsNames == ["ModuleA", "ModuleC"] else {
            fatalError("❌ stats: expected [ModuleA, ModuleC], got \(statsNames)")
        }
        print("✅ stats: \(stats.totalModules) modules remaining")
        
        // 9. 线程安全测试
        let concurrentRegistry = ModuleRegistry()
        let group = DispatchGroup()
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                concurrentRegistry.register(module: TestModuleA(), name: "Concurrent\(i)")
                group.leave()
            }
        }
        group.wait()
        guard concurrentRegistry.allModuleNames.count == 100 else {
            fatalError("❌ Thread safety: expected 100 modules, got \(concurrentRegistry.allModuleNames.count)")
        }
        print("✅ Thread safety: 100 concurrent registrations successful")
        
        print("\n=== All ModuleRegistry Tests Passed ✅ ===")
    }
}
