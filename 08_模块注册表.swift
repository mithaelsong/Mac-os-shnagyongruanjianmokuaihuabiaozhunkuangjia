// 功能8: 模块注册表
// Description: Track loaded modules (name → instance)
// Priority: P0

import Foundation
import os

// MARK: - Module Metadata
/// Metadata struct describing basic module information
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

// MARK: - Module Registry
/// Module Registry (Function 8)
/// Global singleton, all modules use it to discover each other
/// Uses os_unfair_lock for thread safety and performance
public final class ModuleRegistry: Sendable {
    public static let shared = ModuleRegistry()
    
    /// Thread-safe module storage wrapper
    private final class ModuleStorage: @unchecked Sendable {
        var modules: [String: Any] = [:]
        var metadataMap: [String: ModuleMetadata] = [:]
        var lock = os_unfair_lock()
    }
    
    private let storage = ModuleStorage()
    private let logger = ModuleLogger(category: "ModuleRegistry")
    
    private init() {}
    
    // MARK: - Register
    /// Register a module in the registry
    /// - Parameters:
    ///   - module: Module instance
    ///   - name: Module name
    ///   - metadata: Module metadata (optional)
    public func register(module: Any, name: String, metadata: ModuleMetadata? = nil) {
        os_unfair_lock_lock(&storage.lock)
        storage.modules[name] = module
        if let meta = metadata {
            storage.metadataMap[name] = meta
        }
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("已注册模块: \(name)")
    }
    
    // MARK: - Unregister
    /// Unregister a module from the registry
    /// - Parameter name: Module name
    public func unregister(name: String) {
        os_unfair_lock_lock(&storage.lock)
        storage.modules.removeValue(forKey: name)
        storage.metadataMap.removeValue(forKey: name)
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("已注销模块: \(name)")
    }
    
    // MARK: - Get Module
    /// Get a module instance by name
    /// - Parameter name: Module name
    /// - Returns: Module instance, or nil if not found
    public func getModule(named name: String) -> Any? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]
    }
    
    // MARK: - Get Module Metadata
    /// Get module metadata by name
    /// - Parameter name: Module name
    /// - Returns: Module metadata, or nil if not found
    public func getMetadata(named name: String) -> ModuleMetadata? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.metadataMap[name]
    }
    
    // MARK: - Check Loaded
    /// Check if a module is loaded in the registry
    /// - Parameter name: Module name
    /// - Returns: Whether the module is loaded
    public func isLoaded(name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name] != nil
    }
    
    // MARK: - All Module Names
    /// Get names of all registered modules
    public var allModuleNames: [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return Array(storage.modules.keys)
    }
    
    // MARK: - Get by Type
    /// Get all modules conforming to a given type
    /// - Parameter type: Target type
    /// - Returns: Array of (name, module) pairs matching the type
    public func getModules<T>(conformingTo type: T.Type) -> [(name: String, module: T)] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return storage.modules.compactMap { (name, module) in
            guard let typed = module as? T else { return nil }
            return (name: name, module: typed)
        }
    }
    
    // MARK: - Get Module Stats
    /// Get registry statistics
    public var stats: ModuleRegistryStats {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return ModuleRegistryStats(
            totalModules: storage.modules.count,
            moduleNames: Array(storage.modules.keys)
        )
    }
}

// MARK: - Registry Stats
/// Module registry statistics
public struct ModuleRegistryStats: Sendable {
    public let totalModules: Int
    public let moduleNames: [String]
}

// MARK: - Tests
public protocol ModuleRegistryTestProtocol {
    func greet() -> String
}

public final class TestModuleA: ModuleRegistryTestProtocol {
    public func greet() -> String { "Hello from ModuleA" }
}

public final class TestModuleB: ModuleRegistryTestProtocol {
    public func greet() -> String { "Hello from ModuleB" }
}

public final class TestModuleC {
    public let value = 42
}

public enum ModuleRegistryTests {
    
    /// Run all tests
    public static func run() {
        print("=== 功能8测试 ===")
        testRegister()
        testIsLoaded()
        testGetModule()
        testGetMetadata()
        testAllModuleNames()
        testGetModulesConformingTo()
        testUnregister()
        testStats()
        testThreadSafety()
        print("\n=== 全部功能8测试通过 ✅ ===")
        
        cleanup()
    }
    
    private static func cleanup() {
        for name in ModuleRegistry.shared.allModuleNames {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    /// Test 1: Register modules
    public static func testRegister() {
        print("\n🧪 测试1: 注册模块")
        
        let metaA = ModuleMetadata(name: "RegA", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "RegA", metadata: metaA)
        
        let metaB = ModuleMetadata(name: "RegB", version: "2.0", description: "", entryClass: "", priority: 20)
        ModuleRegistry.shared.register(module: TestModuleB(), name: "RegB", metadata: metaB)
        
        ModuleRegistry.shared.register(module: TestModuleC(), name: "RegC")
        
        guard ModuleRegistry.shared.isLoaded(name: "RegA") else {
            fatalError("❌ 测试1失败: RegA未加载")
        }
        guard ModuleRegistry.shared.isLoaded(name: "RegB") else {
            fatalError("❌ 测试1失败: RegB未加载")
        }
        guard ModuleRegistry.shared.isLoaded(name: "RegC") else {
            fatalError("❌ 测试1失败: RegC未加载")
        }
        
        // Cleanup
        ModuleRegistry.shared.unregister(name: "RegA")
        ModuleRegistry.shared.unregister(name: "RegB")
        ModuleRegistry.shared.unregister(name: "RegC")
        
        print("✅ 测试1通过: 3个模块注册成功")
    }
    
    /// Test 2: isLoaded checks
    public static func testIsLoaded() {
        print("\n🧪 测试2: isLoaded检查")
        
        let meta = ModuleMetadata(name: "LoadCheck", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "LoadCheck", metadata: meta)
        
        guard ModuleRegistry.shared.isLoaded(name: "LoadCheck") else {
            fatalError("❌ 测试2失败: LoadCheck应已加载")
        }
        guard !ModuleRegistry.shared.isLoaded(name: "NonExistent") else {
            fatalError("❌ 测试2失败: NonExistent不应已加载")
        }
        
        ModuleRegistry.shared.unregister(name: "LoadCheck")
        
        print("✅ 测试2通过: isLoaded对存在和缺失的模块均有效")
    }
    
    /// Test 3: getModule retrieval
    public static func testGetModule() {
        print("\n🧪 测试3: getModule获取")
        
        let meta = ModuleMetadata(name: "GetMod", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "GetMod", metadata: meta)
        
        guard let mod = ModuleRegistry.shared.getModule(named: "GetMod") as? TestModuleA else {
            fatalError("❌ 测试3失败: GetMod未找到或类型错误")
        }
        guard mod.greet() == "Hello from ModuleA" else {
            fatalError("❌ 测试3失败: GetMod greet不匹配")
        }
        
        guard ModuleRegistry.shared.getModule(named: "NonExistent") == nil else {
            fatalError("❌ 测试3失败: NonExistent应为nil")
        }
        
        ModuleRegistry.shared.unregister(name: "GetMod")
        
        print("✅ 测试3通过: getModule获取正确模块")
    }
    
    /// Test 4: getMetadata retrieval
    public static func testGetMetadata() {
        print("\n🧪 测试4: getMetadata获取")
        
        let meta = ModuleMetadata(name: "MetaMod", version: "2.5.0", description: "Test", entryClass: "", priority: 50)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "MetaMod", metadata: meta)
        
        guard let retrieved = ModuleRegistry.shared.getMetadata(named: "MetaMod") else {
            fatalError("❌ 测试4失败: metadata未找到")
        }
        guard retrieved.name == "MetaMod" else {
            fatalError("❌ 测试4失败: 名称不匹配")
        }
        guard retrieved.version == "2.5.0" else {
            fatalError("❌ 测试4失败: 版本不匹配，实际 \(retrieved.version)")
        }
        guard retrieved.priority == 50 else {
            fatalError("❌ 测试4失败: priority不匹配，实际 \(retrieved.priority)")
        }
        
        // Modules without metadata should return nil
        ModuleRegistry.shared.register(module: TestModuleC(), name: "NoMeta")
        guard ModuleRegistry.shared.getMetadata(named: "NoMeta") == nil else {
            fatalError("❌ 测试4失败: NoMeta应无metadata")
        }
        
        ModuleRegistry.shared.unregister(name: "MetaMod")
        ModuleRegistry.shared.unregister(name: "NoMeta")
        
        print("✅ 测试4通过: getMetadata获取正确的metadata")
    }
    
    /// Test 5: allModuleNames
    public static func testAllModuleNames() {
        print("\n🧪 测试5: allModuleNames")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "Alpha")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "Beta")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "Gamma")
        
        let names = ModuleRegistry.shared.allModuleNames.sorted()
        guard names == ["Alpha", "Beta", "Gamma"] else {
            fatalError("❌ 测试5失败: 期望[Alpha, Beta, Gamma]，实际 \(names)")
        }
        
        ModuleRegistry.shared.unregister(name: "Alpha")
        ModuleRegistry.shared.unregister(name: "Beta")
        ModuleRegistry.shared.unregister(name: "Gamma")
        
        print("✅ 测试5通过: allModuleNames返回正确列表")
    }
    
    /// Test 6: getModules conforming to protocol
    public static func testGetModulesConformingTo() {
        print("\n🧪 测试6: getModules(conformingTo:)")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "ProtoA")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "ProtoB")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "NonProto")
        
        let conforming = ModuleRegistry.shared.getModules(conformingTo: ModuleRegistryTestProtocol.self)
        guard conforming.count == 2 else {
            fatalError("❌ 测试6失败: 期望2个协议模块，实际 \(conforming.count)")
        }
        
        let protoNames = conforming.map(\.name).sorted()
        guard protoNames == ["ProtoA", "ProtoB"] else {
            fatalError("❌ 测试6失败: 期望[ProtoA, ProtoB]，实际 \(protoNames)")
        }
        
        ModuleRegistry.shared.unregister(name: "ProtoA")
        ModuleRegistry.shared.unregister(name: "ProtoB")
        ModuleRegistry.shared.unregister(name: "NonProto")
        
        print("✅ 测试6通过: getModules按协议正确过滤")
    }
    
    /// Test 7: Unregister module
    public static func testUnregister() {
        print("\n🧪 测试7: 注销模块")
        
        let meta = ModuleMetadata(name: "UnregMod", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "UnregMod", metadata: meta)
        
        ModuleRegistry.shared.unregister(name: "UnregMod")
        
        guard !ModuleRegistry.shared.isLoaded(name: "UnregMod") else {
            fatalError("❌ 测试7失败: 注销后模块仍加载")
        }
        guard ModuleRegistry.shared.getMetadata(named: "UnregMod") == nil else {
            fatalError("❌ 测试7失败: 注销后metadata未移除")
        }
        
        print("✅ 测试7通过: 注销时模块和metadata已移除")
    }
    
    /// Test 8: Stats
    public static func testStats() {
        print("\n🧪 测试8: ModuleRegistry统计")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "StatA")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "StatB")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "StatC")
        
        let stats = ModuleRegistry.shared.stats
        guard stats.totalModules == 3 else {
            fatalError("❌ 测试8失败: 期望3个总模块，实际 \(stats.totalModules)")
        }
        let statsNames = stats.moduleNames.sorted()
        guard statsNames == ["StatA", "StatB", "StatC"] else {
            fatalError("❌ 测试8失败: 期望[StatA, StatB, StatC]，实际 \(statsNames)")
        }
        
        ModuleRegistry.shared.unregister(name: "StatA")
        ModuleRegistry.shared.unregister(name: "StatB")
        ModuleRegistry.shared.unregister(name: "StatC")
        
        print("✅ 测试8通过: 统计正确")
    }
    
    /// Test 9: Thread safety (100 concurrent registrations)
    public static func testThreadSafety() {
        print("\n🧪 测试9: 线程安全(100并发注册)")
        
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
            fatalError("❌ 测试9失败: 期望并发写入后100个模块，实际 \(concurrentRegistry.allModuleNames.count)")
        }
        
        print("✅ 测试9通过: \(concurrentRegistry.allModuleNames.count) concurrent registrations successful")
    }
}
