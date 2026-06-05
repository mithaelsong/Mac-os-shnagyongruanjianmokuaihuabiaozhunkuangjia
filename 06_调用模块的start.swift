// 功能6: 调用模块的start
// 对应: 按依赖顺序调用已注册模块的start()
// 优先级: P0

import Foundation
import os

// XRZModule 协议定义于 05_按顺序加载Module.swift
// Includes init() + start() + stop() + services

// MARK: - Module Start Error
/// Errors that may occur during module startup
public enum ModuleStartError: Error, CustomStringConvertible {
    case moduleNotFound(name: String)
    case moduleNotConformingToProtocol(name: String)
    case dependencyMissing(name: String, dependency: String)
    case dependencyCycle(cycle: [String])
    case simulatedFailure(name: String)
    
    public var description: String {
        switch self {
        case .moduleNotFound(let name):
            return "Module not found: \(name)"
        case .moduleNotConformingToProtocol(let name):
            return "Module \(name) does not conform to XRZModule"
        case .dependencyMissing(let name, let dep):
            return "Module \(name) missing dependency: \(dep)"
        case .dependencyCycle(let cycle):
            return "dependency cycle: \(cycle.joined(separator: " -> "))"
        case .simulatedFailure(let name):
            return "simulated start failure for module: \(name)"
        }
    }
}

// MARK: - Start Results

/// 单个ModuleStart Results
public enum ModuleStartResult {
    case success(alreadyStarted: Bool)
    case failure(reason: ModuleStartFailureReason)
    
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Single module start failure reason
public enum ModuleStartFailureReason {
    case notRegistered
    case dependencyFailed(name: String)
    case startFailed(error: Error)
    case dependencyCycle(cycle: [String])
}

/// Batch start result for all modules
public enum StartAllResult {
    case success(started: [String], failed: [(String, Error)])
    case failure(reason: StartAllFailureReason)
}

/// Batch start failure reason
public enum StartAllFailureReason {
    case dependencyCycle(cycle: [String])
}

// MARK: - Topology Sort Result
private enum TopologySortResult {
    case success(order: [String])
    case failure(cycle: [String])
}

// MARK: - ModuleStarter
/// Module Starter (Function6)
/// Calls start() on registered modules in dependency order
/// Uses topological sort to ensure correct start order
/// A single module failure does not affect other modules
public final class ModuleStarter {
    private let registry: ModuleRegistry
    private let logger: ModuleLogger
    
    /// Thread-safe set of started modules
    private final class StartedStorage: @unchecked Sendable {
        var started: Set<String> = []
        var lock = os_unfair_lock()
    }
    
    private let startedStorage = StartedStorage()
    
    /// Initialize starter
    /// - Parameters:
    ///   - registry: Module registry (Function 8)
    ///   - logger: Module logger (Function 2)
    public init(registry: ModuleRegistry, logger: ModuleLogger) {
        self.registry = registry
        self.logger = logger
    }
    
    // MARK: - Start All Modules
    
    /// Start all registered modules
    /// Topological sort order: dependencies first, then current module
    /// A single module failure does not prevent others from starting
    /// - Returns: Start result with lists of started and failed modules
    public func startAllModules() -> StartAllResult {
        let allNames = registry.allModuleNames
        guard !allNames.isEmpty else {
            logger.info("没有已注册的模块，无需启动")
            return .success(started: [], failed: [])
        }
        
        logger.info("准备启动 \(allNames.count) 个已注册模块...")
        
        // 拓扑排序
        let sortResult = topologicalSort(allNames)
        switch sortResult {
        case .failure(let cycle):
            logger.error("检测到循环依赖: \(cycle.joined(separator: " -> "))")
            return .failure(reason: .dependencyCycle(cycle: cycle))
            
        case .success(let order):
            logger.info("启动顺序: \(order.joined(separator: " -> "))")
            
            var started: [String] = []
            var failed: [(String, Error)] = []
            
            for name in order {
                do {
                    try startModuleInternal(name)
                    started.append(name)
                } catch {
                    logger.error("启动模块 \(name) 失败: \(error)")
                    failed.append((name, error))
                }
            }
            
            if failed.isEmpty {
                logger.info("全部 \(started.count) 个模块启动成功")
            } else {
                logger.warning("\(started.count) 个模块启动成功，\(failed.count) 个失败")
            }
            
            return .success(started: started, failed: failed)
        }
    }
    
    // MARK: - Start Single Module
    
    /// Start Single Module
    /// Recursively start dependencies, then the module itself
    /// - Parameter name: Module name
    /// - Returns: Start Results
    public func startModule(_ name: String) -> ModuleStartResult {
        // Check if module is registered
        guard registry.isLoaded(name: name) else {
            logger.error("无法启动模块 \(name): 未注册")
            return .failure(reason: .notRegistered)
        }
        
        // Check if already started
        if isStarted(name) {
            logger.info("模块 \(name) 已启动，跳过")
            return .success(alreadyStarted: true)
        }
        
        logger.info("准备启动模块: \(name)")
        
        // Start dependencies first
        let dependencies = getDependencies(for: name)
        if !dependencies.isEmpty {
            logger.info("模块 \(name) 有 \(dependencies.count) 个依赖: \(dependencies)")
        }
        
        for dep in dependencies {
            // Check if dependency is registered
            guard registry.isLoaded(name: dep) else {
                logger.error("模块 \(name) 依赖 \(dep) 未注册")
                return .failure(reason: .dependencyFailed(name: dep))
            }
            
            // Recursively start dependency
            if !isStarted(dep) {
                let depResult = startModule(dep)
                guard depResult.isSuccess else {
                    logger.error("依赖 \(dep) 启动失败，中止 \(name) 启动")
                    return .failure(reason: .dependencyFailed(name: dep))
                }
            }
        }
        
        // Start current module
        do {
            try startModuleInternal(name)
            return .success(alreadyStarted: false)
        } catch {
            logger.error("启动模块 \(name) 失败: \(error)")
            return .failure(reason: .startFailed(error: error))
        }
    }
    
    // MARK: - Stop Module
    
    /// Stop a single module
    /// - Parameter name: Module name
    public func stopModule(_ name: String) {
        guard isStarted(name) else {
            logger.warning("模块 \(name) 未启动，无法停止")
            return
        }
        
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 不符合XRZModule协议")
            return
        }
        
        do {
            try module.stop()
            markStopped(name)
            logger.info("模块 \(name) 已停止")
        } catch {
            logger.error("停止模块 \(name) 失败: \(error)")
        }
    }
    
    // MARK: - Query Status
    
    /// Check if a module is started
    public func isStarted(_ name: String) -> Bool {
        os_unfair_lock_lock(&startedStorage.lock)
        defer { os_unfair_lock_unlock(&startedStorage.lock) }
        return startedStorage.started.contains(name)
    }
    
    /// Get the list of started modules
    public var startedModules: [String] {
        os_unfair_lock_lock(&startedStorage.lock)
        defer { os_unfair_lock_unlock(&startedStorage.lock) }
        return Array(startedStorage.started)
    }
    
    // MARK: - Private Methods
    
    /// Internal start method (no dependency check, only calls start())
    /// Skip if module is already started (supports pre-loading from Function 5)
    private func startModuleInternal(_ name: String) throws {
        guard let module = registry.getModule(named: name) as? XRZModule else {
            throw ModuleStartError.moduleNotConformingToProtocol(name: name)
        }
        
        logger.info("正在启动模块: \(name)")
        
        // Skip if already started by Function 5
        if isStarted(name) {
            logger.info("模块 \(name) 已启动，跳过重复start()")
            return
        }
        
        try module.start()
        markStarted(name)
        logger.info("模块 \(name) 启动成功")
    }
    
    /// Get dependency list for a module
    /// Prefer ModuleMetadata, fall back to ConfigSystem
    private func getDependencies(for name: String) -> [String] {
        if let metadata = registry.getMetadata(named: name) {
            return metadata.dependencies
        }
        return ConfigSystem.shared.getModuleDependencies(name)
    }
    
    /// Mark module as started
    private func markStarted(_ name: String) {
        os_unfair_lock_lock(&startedStorage.lock)
        startedStorage.started.insert(name)
        os_unfair_lock_unlock(&startedStorage.lock)
    }
    
    /// Mark module as stopped
    private func markStopped(_ name: String) {
        os_unfair_lock_lock(&startedStorage.lock)
        startedStorage.started.remove(name)
        os_unfair_lock_unlock(&startedStorage.lock)
    }
    
    /// Topological Sort (Kahn Algorithm)
    /// Sort modules by dependencies, ensuring dependencies start first
    private func topologicalSort(_ names: [String]) -> TopologySortResult {
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]
        
        // Initialize
        for name in names {
            inDegree[name] = 0
            adjacency[name] = []
        }
        
        // Build directed graph: Dependency -> Dependent
        // If B depends on A, A starts first: graph edge A -> B
        for name in names {
            let deps = getDependencies(for: name)
            for dep in deps {
                if names.contains(dep) {
                    adjacency[dep, default: []].append(name)
                    inDegree[name, default: 0] += 1
                }
            }
        }
        
        // Kahn: start with nodes that have in-degree 0
        var queue = names.filter { inDegree[$0] == 0 }
        queue.sort() // Stable sort for deterministic output
        
        var result: [String] = []
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)
            
            for neighbor in adjacency[current, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }
        
        if result.count == names.count {
            return .success(order: result)
        } else {
            // Find nodes in the cycle
            let remaining = names.filter { !result.contains($0) }
            return .failure(cycle: remaining)
        }
    }
}

// MARK: - Test Code

/// ModuleStarter Function验证测试
/// 运行方式：在单元测试或 Playground 中调用 `ModuleStarterTests.runAllTests()`
public enum ModuleStarterTests {
    
    /// Mock module for testing
    final class TestModule: XRZModule {
        let name: String
        var shouldFail: Bool = false
        var startOrder: Int = 0
        static var globalCounter = 0
        static var aLock = os_unfair_lock()
        
        required init() {
            self.name = "TestModule"
        }
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {
            if shouldFail {
                throw ModuleStartError.simulatedFailure(name: name)
            }
            os_unfair_lock_lock(&Self.aLock)
            Self.globalCounter += 1
            startOrder = Self.globalCounter
            os_unfair_lock_unlock(&Self.aLock)
        }
        
        func stop() throws {}
    }
    
    /// Run all tests
    public static func runAllTests() {
        // Reset counter
        TestModule.globalCounter = 0
        
        // Clear global registry
        cleanupRegistry()
        
        testStartAllWithDependencies()
        cleanupRegistry()
        
        testSingleModuleStart()
        cleanupRegistry()
        
        testFailureHandling()
        cleanupRegistry()
        
        testCircularDependency()
        cleanupRegistry()
        
        testDependencyChain()
        cleanupRegistry()
        
        testAlreadyStarted()
        cleanupRegistry()
        
        testMissingDependency()
        cleanupRegistry()
        
        testMultipleIndependentModules()
        cleanupRegistry()
        
        print("\n=== 全部功能6测试通过 ✅ ===")
    }
    
    // MARK: - Helper Methods
    
    /// Remove all modules from registry
    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    // MARK: - Test 1: Start All With Dependencies
    
    /// Test topological sort start order
    /// Module structure: A depends on B, B depends on C
    /// Expected start order: C -> B -> A
    public static func testStartAllWithDependencies() {
        print("\n🧪 测试1: 启动所有带依赖的模块")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let moduleA = TestModule(name: "A")
        let moduleB = TestModule(name: "B")
        let moduleC = TestModule(name: "C")
        
        registry.register(
            module: moduleA,
            name: "A",
            metadata: ModuleMetadata(
                name: "A", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["B"]
            )
        )
        registry.register(
            module: moduleB,
            name: "B",
            metadata: ModuleMetadata(
                name: "B", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["C"]
            )
        )
        registry.register(
            module: moduleC,
            name: "C",
            metadata: ModuleMetadata(
                name: "C", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        
        let result = starter.startAllModules()
        
        guard case .success(let started, let failed) = result else {
            fatalError("❌ 测试1失败: 不应返回失败")
        }
        guard failed.isEmpty else {
            fatalError("❌ 测试1失败: 应无失败: \(failed)")
        }
        guard started == ["C", "B", "A"] else {
            fatalError("❌ 测试1失败: 期望顺序[C, B, A]，实际 \(started)")
        }
        
        guard moduleC.startOrder < moduleB.startOrder else {
            fatalError("❌ 测试1失败: C应在B之前启动")
        }
        guard moduleB.startOrder < moduleA.startOrder else {
            fatalError("❌ 测试1失败: B应在A之前启动")
        }
        
        print("✅ 测试1通过: 依赖顺序C -> B -> A正确")
    }
    
    // MARK: - Test 2: Start Single Module (auto starts dependencies)
    
    /// Test startModule automatically starts dependencies
    public static func testSingleModuleStart() {
        print("\n🧪 测试2: 启动单个模块(自动启动依赖)")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let moduleX = TestModule(name: "X")
        let moduleY = TestModule(name: "Y")
        
        registry.register(
            module: moduleX,
            name: "X",
            metadata: ModuleMetadata(
                name: "X", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["Y"]
            )
        )
        registry.register(
            module: moduleY,
            name: "Y",
            metadata: ModuleMetadata(
                name: "Y", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        
        let result = starter.startModule("X")
        
        guard result.isSuccess else {
            fatalError("❌ 测试2失败: X启动失败")
        }
        guard starter.isStarted("Y") else {
            fatalError("❌ 测试2失败: Y应已启动")
        }
        guard starter.isStarted("X") else {
            fatalError("❌ 测试2失败: X应已启动")
        }
        
        print("✅ 测试2通过: 单个模块启动处理依赖")
    }
    
    // MARK: - Test 3: Failure Isolation
    
    /// Test failure isolation: one failure should not block others
    public static func testFailureHandling() {
        print("\n🧪 测试3: 失败隔离")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let moduleOK1 = TestModule(name: "OK1")
        let moduleFail = TestModule(name: "Fail")
        let moduleOK2 = TestModule(name: "OK2")
        
        registry.register(
            module: moduleOK1,
            name: "OK1",
            metadata: ModuleMetadata(
                name: "OK1", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        registry.register(
            module: moduleFail,
            name: "Fail",
            metadata: ModuleMetadata(
                name: "Fail", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        registry.register(
            module: moduleOK2,
            name: "OK2",
            metadata: ModuleMetadata(
                name: "OK2", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        
        moduleFail.shouldFail = true
        
        let result = starter.startAllModules()
        
        guard case .success(let started, let failed) = result else {
            fatalError("❌ 测试3失败: 不应返回总体失败")
        }
        guard started.count == 2 else {
            fatalError("❌ 测试3失败: 期望2个成功，实际 \(started.count)")
        }
        guard failed.count == 1 else {
            fatalError("❌ 测试3失败: 期望1个失败，实际 \(failed.count)")
        }
        guard failed.first?.0 == "Fail" else {
            fatalError("❌ 测试3失败: 期望Fail失败，实际 \(failed)")
        }
        guard starter.isStarted("OK1") || starter.isStarted("OK2") else {
            fatalError("❌ 测试3失败: 至少一个OK模块应已启动")
        }
        
        print("✅ 测试3通过: 失败隔离生效")
    }
    
    // MARK: - Test 4: Circular Dependency Detection
    
    /// Test circular dependency detection
    public static func testCircularDependency() {
        print("\n🧪 测试4: 循环依赖检测")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let moduleP = TestModule(name: "P")
        let moduleQ = TestModule(name: "Q")
        
        registry.register(
            module: moduleP,
            name: "P",
            metadata: ModuleMetadata(
                name: "P", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["Q"]
            )
        )
        registry.register(
            module: moduleQ,
            name: "Q",
            metadata: ModuleMetadata(
                name: "Q", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["P"]
            )
        )
        
        let result = starter.startAllModules()
        
        guard case .failure = result else {
            fatalError("❌ 测试4失败: 应检测到循环依赖")
        }
        
        print("✅ 测试4通过: 循环依赖已检测")
    }
    
    // MARK: - Test 5: Long Dependency Chain
    
    /// Test 5-module dependency chain
    //// Chain: E -> D -> C -> B -> A (E depends on D, D depends on C, ...)
    /// Start order: A -> B -> C -> D -> E
    public static func testDependencyChain() {
        print("\n🧪 测试5: 长依赖链")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        var modules: [TestModule] = []
        for i in 0..<5 {
            let name = String(UnicodeScalar(65 + i)!)
            let mod = TestModule(name: name)
            modules.append(mod)
            let deps = i > 0 ? [String(UnicodeScalar(64 + i)!)] : []
            registry.register(
                module: mod,
                name: name,
                metadata: ModuleMetadata(
                    name: name, version: "1.0", description: "", entryClass: "TestModule",
                    dependencies: deps
                )
            )
        }
        
        let result = starter.startAllModules()
        
        guard case .success(let started, _) = result else {
            fatalError("❌ 测试5失败: 不应失败")
        }
        guard started == ["A", "B", "C", "D", "E"] else {
            fatalError("❌ 测试5失败: 期望[A, B, C, D, E]，实际 \(started)")
        }
        
        for i in 1..<5 {
            guard modules[i].startOrder > modules[i-1].startOrder else {
                fatalError("❌ 测试5失败: 模块顺序错误")
            }
        }
        
        print("✅ 测试5通过: 5模块链正确")
    }
    
    // MARK: - Test 6: Idempotent Start
    
    /// Test repeated start is idempotent
    public static func testAlreadyStarted() {
        print("\n🧪 测试6: 幂等启动")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let module = TestModule(name: "M")
        registry.register(
            module: module,
            name: "M",
            metadata: ModuleMetadata(
                name: "M", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: []
            )
        )
        
        let result1 = starter.startModule("M")
        guard case .success(let alreadyStarted1) = result1, !alreadyStarted1 else {
            fatalError("❌ 测试6失败: 首次启动应不是already started")
        }
        
        let result2 = starter.startModule("M")
        guard case .success(let alreadyStarted2) = result2, alreadyStarted2 else {
            fatalError("❌ 测试6失败: 第二次启动应返回already started")
        }
        
        guard starter.isStarted("M") else {
            fatalError("❌ 测试6失败: M应已启动")
        }
        
        print("✅ 测试6通过: 幂等启动")
    }
    
    // MARK: - Test 7: Missing Dependency
    
    /// Test handling of missing dependency
    public static func testMissingDependency() {
        print("\n🧪 测试7: 缺失依赖")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let module = TestModule(name: "HasDep")
        registry.register(
            module: module,
            name: "HasDep",
            metadata: ModuleMetadata(
                name: "HasDep", version: "1.0", description: "", entryClass: "TestModule",
                dependencies: ["Missing"]
            )
        )
        
        let result = starter.startModule("HasDep")
        
        guard case .failure(let reason) = result else {
            fatalError("❌ 测试7失败: 应因缺失依赖失败")
        }
        if case .dependencyFailed(let name) = reason {
            guard name == "Missing" else {
                fatalError("❌ 测试7失败: 期望Missing依赖，实际 \(name)")
            }
        } else {
            fatalError("❌ 测试7失败: 期望dependencyFailed，实际 \(reason)")
        }
        
        print("✅ 测试7通过: 缺失依赖已处理")
    }
    
    // MARK: - Test 8: Independent Modules
    
    /// Test batch start of independent modules
    public static func testMultipleIndependentModules() {
        print("\n🧪 测试8: 独立模块")
        
        let registry = ModuleRegistry.shared
        let starter = ModuleStarter(registry: registry, logger: ModuleLogger(category: "TestStarter"))
        
        let names = ["X", "Y", "Z"]
        for name in names {
            registry.register(
                module: TestModule(name: name),
                name: name,
                metadata: ModuleMetadata(
                    name: name, version: "1.0", description: "", entryClass: "TestModule",
                    dependencies: []
                )
            )
        }
        
        let result = starter.startAllModules()
        
        guard case .success(let started, let failed) = result else {
            fatalError("❌ 测试8失败: 不应失败")
        }
        guard started.count == 3 else {
            fatalError("❌ 测试8失败: 期望3个成功，实际 \(started.count)")
        }
        guard failed.isEmpty else {
            fatalError("❌ 测试8失败: 期望0个失败，实际 \(failed.count)")
        }
        
        for name in names {
            guard starter.isStarted(name) else {
                fatalError("❌ 测试8失败: 模块应已启动")
            }
        }
        
        print("✅ 测试8通过: 所有独立模块已启动")
    }
}
