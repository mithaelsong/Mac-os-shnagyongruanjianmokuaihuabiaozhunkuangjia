// Function 8: Module Registry
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
        
        logger.info("Registered module: \(name)")
    }
    
    // MARK: - Unregister
    /// Unregister a module from the registry
    /// - Parameter name: Module name
    public func unregister(name: String) {
        os_unfair_lock_lock(&storage.lock)
        storage.modules.removeValue(forKey: name)
        storage.metadataMap.removeValue(forKey: name)
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("Unregistered module: \(name)")
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
        print("=== ModuleRegistry Tests ===")
        testRegister()
        testIsLoaded()
        testGetModule()
        testGetMetadata()
        testAllModuleNames()
        testGetModulesConformingTo()
        testUnregister()
        testStats()
        testThreadSafety()
        print("\n=== All ModuleRegistry Tests Passed ✅ ===")
        
        cleanup()
    }
    
    private static func cleanup() {
        for name in ModuleRegistry.shared.allModuleNames {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    /// Test 1: Register modules
    public static func testRegister() {
        print("\n🧪 Test 1: Register Modules")
        
        let metaA = ModuleMetadata(name: "RegA", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "RegA", metadata: metaA)
        
        let metaB = ModuleMetadata(name: "RegB", version: "2.0", description: "", entryClass: "", priority: 20)
        ModuleRegistry.shared.register(module: TestModuleB(), name: "RegB", metadata: metaB)
        
        ModuleRegistry.shared.register(module: TestModuleC(), name: "RegC")
        
        guard ModuleRegistry.shared.isLoaded(name: "RegA") else {
            fatalError("❌ Test 1 failed: RegA not loaded")
        }
        guard ModuleRegistry.shared.isLoaded(name: "RegB") else {
            fatalError("❌ Test 1 failed: RegB not loaded")
        }
        guard ModuleRegistry.shared.isLoaded(name: "RegC") else {
            fatalError("❌ Test 1 failed: RegC not loaded")
        }
        
        // Cleanup
        ModuleRegistry.shared.unregister(name: "RegA")
        ModuleRegistry.shared.unregister(name: "RegB")
        ModuleRegistry.shared.unregister(name: "RegC")
        
        print("✅ Test 1 passed: 3 modules registered successfully")
    }
    
    /// Test 2: isLoaded checks
    public static func testIsLoaded() {
        print("\n🧪 Test 2: isLoaded Checks")
        
        let meta = ModuleMetadata(name: "LoadCheck", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "LoadCheck", metadata: meta)
        
        guard ModuleRegistry.shared.isLoaded(name: "LoadCheck") else {
            fatalError("❌ Test 2 failed: LoadCheck should be loaded")
        }
        guard !ModuleRegistry.shared.isLoaded(name: "NonExistent") else {
            fatalError("❌ Test 2 failed: NonExistent should not be loaded")
        }
        
        ModuleRegistry.shared.unregister(name: "LoadCheck")
        
        print("✅ Test 2 passed: isLoaded works for existing and missing modules")
    }
    
    /// Test 3: getModule retrieval
    public static func testGetModule() {
        print("\n🧪 Test 3: getModule Retrieval")
        
        let meta = ModuleMetadata(name: "GetMod", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "GetMod", metadata: meta)
        
        guard let mod = ModuleRegistry.shared.getModule(named: "GetMod") as? TestModuleA else {
            fatalError("❌ Test 3 failed: GetMod not found or wrong type")
        }
        guard mod.greet() == "Hello from ModuleA" else {
            fatalError("❌ Test 3 failed: GetMod greet mismatch")
        }
        
        guard ModuleRegistry.shared.getModule(named: "NonExistent") == nil else {
            fatalError("❌ Test 3 failed: NonExistent should be nil")
        }
        
        ModuleRegistry.shared.unregister(name: "GetMod")
        
        print("✅ Test 3 passed: getModule retrieves correct module")
    }
    
    /// Test 4: getMetadata retrieval
    public static func testGetMetadata() {
        print("\n🧪 Test 4: getMetadata Retrieval")
        
        let meta = ModuleMetadata(name: "MetaMod", version: "2.5.0", description: "Test", entryClass: "", priority: 50)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "MetaMod", metadata: meta)
        
        guard let retrieved = ModuleRegistry.shared.getMetadata(named: "MetaMod") else {
            fatalError("❌ Test 4 failed: metadata not found")
        }
        guard retrieved.name == "MetaMod" else {
            fatalError("❌ Test 4 failed: name mismatch")
        }
        guard retrieved.version == "2.5.0" else {
            fatalError("❌ Test 4 failed: version mismatch, got \(retrieved.version)")
        }
        guard retrieved.priority == 50 else {
            fatalError("❌ Test 4 failed: priority mismatch, got \(retrieved.priority)")
        }
        
        // Modules without metadata should return nil
        ModuleRegistry.shared.register(module: TestModuleC(), name: "NoMeta")
        guard ModuleRegistry.shared.getMetadata(named: "NoMeta") == nil else {
            fatalError("❌ Test 4 failed: NoMeta should have no metadata")
        }
        
        ModuleRegistry.shared.unregister(name: "MetaMod")
        ModuleRegistry.shared.unregister(name: "NoMeta")
        
        print("✅ Test 4 passed: getMetadata retrieves correct metadata")
    }
    
    /// Test 5: allModuleNames
    public static func testAllModuleNames() {
        print("\n🧪 Test 5: allModuleNames")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "Alpha")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "Beta")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "Gamma")
        
        let names = ModuleRegistry.shared.allModuleNames.sorted()
        guard names == ["Alpha", "Beta", "Gamma"] else {
            fatalError("❌ Test 5 failed: expected [Alpha, Beta, Gamma], got \(names)")
        }
        
        ModuleRegistry.shared.unregister(name: "Alpha")
        ModuleRegistry.shared.unregister(name: "Beta")
        ModuleRegistry.shared.unregister(name: "Gamma")
        
        print("✅ Test 5 passed: allModuleNames returns correct list")
    }
    
    /// Test 6: getModules conforming to protocol
    public static func testGetModulesConformingTo() {
        print("\n🧪 Test 6: getModules(conformingTo:)")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "ProtoA")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "ProtoB")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "NonProto")
        
        let conforming = ModuleRegistry.shared.getModules(conformingTo: ModuleRegistryTestProtocol.self)
        guard conforming.count == 2 else {
            fatalError("❌ Test 6 failed: expected 2 protocol modules, got \(conforming.count)")
        }
        
        let protoNames = conforming.map(\.name).sorted()
        guard protoNames == ["ProtoA", "ProtoB"] else {
            fatalError("❌ Test 6 failed: expected [ProtoA, ProtoB], got \(protoNames)")
        }
        
        ModuleRegistry.shared.unregister(name: "ProtoA")
        ModuleRegistry.shared.unregister(name: "ProtoB")
        ModuleRegistry.shared.unregister(name: "NonProto")
        
        print("✅ Test 6 passed: getModules filters by protocol correctly")
    }
    
    /// Test 7: Unregister module
    public static func testUnregister() {
        print("\n🧪 Test 7: Unregister Module")
        
        let meta = ModuleMetadata(name: "UnregMod", version: "1.0", description: "", entryClass: "", priority: 10)
        ModuleRegistry.shared.register(module: TestModuleA(), name: "UnregMod", metadata: meta)
        
        ModuleRegistry.shared.unregister(name: "UnregMod")
        
        guard !ModuleRegistry.shared.isLoaded(name: "UnregMod") else {
            fatalError("❌ Test 7 failed: module still loaded after unregister")
        }
        guard ModuleRegistry.shared.getMetadata(named: "UnregMod") == nil else {
            fatalError("❌ Test 7 failed: metadata not removed after unregister")
        }
        
        print("✅ Test 7 passed: module and metadata removed on unregister")
    }
    
    /// Test 8: Stats
    public static func testStats() {
        print("\n🧪 Test 8: ModuleRegistry Stats")
        
        ModuleRegistry.shared.register(module: TestModuleA(), name: "StatA")
        ModuleRegistry.shared.register(module: TestModuleB(), name: "StatB")
        ModuleRegistry.shared.register(module: TestModuleC(), name: "StatC")
        
        let stats = ModuleRegistry.shared.stats
        guard stats.totalModules == 3 else {
            fatalError("❌ Test 8 failed: expected 3 total modules, got \(stats.totalModules)")
        }
        let statsNames = stats.moduleNames.sorted()
        guard statsNames == ["StatA", "StatB", "StatC"] else {
            fatalError("❌ Test 8 failed: expected [StatA, StatB, StatC], got \(statsNames)")
        }
        
        ModuleRegistry.shared.unregister(name: "StatA")
        ModuleRegistry.shared.unregister(name: "StatB")
        ModuleRegistry.shared.unregister(name: "StatC")
        
        print("✅ Test 8 passed: stats correct")
    }
    
    /// Test 9: Thread safety (100 concurrent registrations)
    public static func testThreadSafety() {
        print("\n🧪 Test 9: Thread Safety (100 concurrent registrations)")
        
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
            fatalError("❌ Test 9 failed: expected 100 modules after concurrent writes, got \(concurrentRegistry.allModuleNames.count)")
        }
        
        print("✅ Test 9 passed: \(concurrentRegistry.allModuleNames.count) concurrent registrations successful")
    }
}
