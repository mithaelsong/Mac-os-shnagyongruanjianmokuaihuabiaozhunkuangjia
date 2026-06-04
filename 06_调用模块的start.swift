// 功能6: 调用模块的start
// 对应: 按依赖顺序调用已注册模块的 start() 方法
// 优先级: P0

import Foundation
import os

// MARK: - XRZModule 协议
/// 模块生命周期协议，所有模块必须实现此协议
public protocol XRZModule {
    /// 启动模块，模块初始化完成后调用
    func start() throws
    
    /// 停止模块，模块卸载前调用
    func stop() throws
}

// MARK: - 模块启动错误
/// 模块启动过程中可能遇到的错误
public enum ModuleStartError: Error, CustomStringConvertible {
    case moduleNotFound(name: String)
    case moduleNotConformingToProtocol(name: String)
    case dependencyMissing(name: String, dependency: String)
    case dependencyCycle(cycle: [String])
    case simulatedFailure(name: String)
    
    public var description: String {
        switch self {
        case .moduleNotFound(let name):
            return "模块未找到: \(name)"
        case .moduleNotConformingToProtocol(let name):
            return "模块 \(name) 未实现 XRZModule 协议"
        case .dependencyMissing(let name, let dep):
            return "模块 \(name) 缺少依赖: \(dep)"
        case .dependencyCycle(let cycle):
            return "依赖循环: \(cycle.joined(separator: " -> "))"
        case .simulatedFailure(let name):
            return "模块启动模拟失败: \(name)"
        }
    }
}

// MARK: - 启动结果

/// 单个模块启动结果
public enum ModuleStartResult {
    case success(alreadyStarted: Bool)
    case failure(reason: ModuleStartFailureReason)
    
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// 单个模块启动失败原因
public enum ModuleStartFailureReason {
    case notRegistered
    case dependencyFailed(name: String)
    case startFailed(error: Error)
    case dependencyCycle(cycle: [String])
}

/// 批量启动所有模块的结果
public enum StartAllResult {
    case success(started: [String], failed: [(String, Error)])
    case failure(reason: StartAllFailureReason)
}

/// 批量启动失败原因
public enum StartAllFailureReason {
    case dependencyCycle(cycle: [String])
}

// MARK: - 拓扑排序结果
private enum TopologySortResult {
    case success(order: [String])
    case failure(cycle: [String])
}

// MARK: - ModuleStarter
/// 模块启动器 (功能6)
/// 负责按依赖顺序调用已注册模块的 start() 方法
/// 使用拓扑排序确保启动顺序正确
/// 单个模块启动失败不影响其他模块
public final class ModuleStarter {
    private let registry: ModuleRegistry
    private let logger: ModuleLogger
    
    /// 线程安全的已启动模块记录
    private final class StartedStorage: @unchecked Sendable {
        var started: Set<String> = []
        var lock = os_unfair_lock()
    }
    
    private let startedStorage = StartedStorage()
    
    /// 初始化启动器
    /// - Parameters:
    ///   - registry: 模块注册表（功能8）
    ///   - logger: 模块日志记录器（功能2）
    public init(registry: ModuleRegistry, logger: ModuleLogger) {
        self.registry = registry
        self.logger = logger
    }
    
    // MARK: - 启动所有模块
    
    /// 启动所有已注册模块
    /// 按拓扑排序顺序，先启动依赖模块，再启动当前模块
    /// 单个模块失败不影响其他模块继续启动
    /// - Returns: 启动结果，包含成功启动和失败的模块列表
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
            logger.error("检测到依赖循环: \(cycle.joined(separator: " -> "))")
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
                logger.info("所有 \(started.count) 个模块启动成功")
            } else {
                logger.warning("\(started.count) 个模块启动成功，\(failed.count) 个失败")
            }
            
            return .success(started: started, failed: failed)
        }
    }
    
    // MARK: - 启动单个模块
    
    /// 启动单个模块
    /// 先递归启动该模块的所有依赖，再启动当前模块
    /// - Parameter name: 模块名称
    /// - Returns: 启动结果
    public func startModule(_ name: String) -> ModuleStartResult {
        // 检查是否已注册
        guard registry.isLoaded(name: name) else {
            logger.error("无法启动模块 \(name)：未在注册表中注册")
            return .failure(reason: .notRegistered)
        }
        
        // 检查是否已启动
        if isStarted(name) {
            logger.info("模块 \(name) 已启动，跳过")
            return .success(alreadyStarted: true)
        }
        
        logger.info("准备启动模块: \(name)")
        
        // 获取并启动依赖
        let dependencies = getDependencies(for: name)
        if !dependencies.isEmpty {
            logger.info("模块 \(name) 有 \(dependencies.count) 个依赖: \(dependencies)")
        }
        
        for dep in dependencies {
            // 检查依赖是否已注册
            guard registry.isLoaded(name: dep) else {
                logger.error("模块 \(name) 的依赖 \(dep) 未注册")
                return .failure(reason: .dependencyFailed(name: dep))
            }
            
            // 递归启动依赖
            if !isStarted(dep) {
                let depResult = startModule(dep)
                guard depResult.isSuccess else {
                    logger.error("依赖 \(dep) 启动失败，中止 \(name) 的启动")
                    return .failure(reason: .dependencyFailed(name: dep))
                }
            }
        }
        
        // 启动当前模块
        do {
            try startModuleInternal(name)
            return .success(alreadyStarted: false)
        } catch {
            logger.error("启动模块 \(name) 失败: \(error)")
            return .failure(reason: .startFailed(error: error))
        }
    }
    
    // MARK: - 停止模块
    
    /// 停止单个模块
    /// - Parameter name: 模块名称
    public func stopModule(_ name: String) {
        guard isStarted(name) else {
            logger.warning("模块 \(name) 未启动，无法停止")
            return
        }
        
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("模块 \(name) 未实现 XRZModule 协议")
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
    
    // MARK: - 查询状态
    
    /// 检查模块是否已启动
    public func isStarted(_ name: String) -> Bool {
        os_unfair_lock_lock(&startedStorage.lock)
        defer { os_unfair_lock_unlock(&startedStorage.lock) }
        return startedStorage.started.contains(name)
    }
    
    /// 获取已启动的模块列表
    public var startedModules: [String] {
        os_unfair_lock_lock(&startedStorage.lock)
        defer { os_unfair_lock_unlock(&startedStorage.lock) }
        return Array(startedStorage.started)
    }
    
    // MARK: - 私有方法
    
    /// 内部启动方法（不检查依赖，仅执行 start()）
    private func startModuleInternal(_ name: String) throws {
        guard let module = registry.getModule(named: name) as? XRZModule else {
            throw ModuleStartError.moduleNotConformingToProtocol(name: name)
        }
        
        logger.info("正在启动模块: \(name)")
        try module.start()
        markStarted(name)
        logger.info("模块 \(name) 启动成功")
    }
    
    /// 获取模块的依赖列表
    /// 优先从 ModuleMetadata 获取，回退到 ConfigSystem
    private func getDependencies(for name: String) -> [String] {
        if let metadata = registry.getMetadata(named: name) {
            return metadata.dependencies
        }
        return ConfigSystem.shared.getModuleDependencies(name)
    }
    
    /// 标记模块已启动
    private func markStarted(_ name: String) {
        os_unfair_lock_lock(&startedStorage.lock)
        startedStorage.started.insert(name)
        os_unfair_lock_unlock(&startedStorage.lock)
    }
    
    /// 标记模块已停止
    private func markStopped(_ name: String) {
        os_unfair_lock_lock(&startedStorage.lock)
        startedStorage.started.remove(name)
        os_unfair_lock_unlock(&startedStorage.lock)
    }
    
    /// 拓扑排序（Kahn 算法）
    /// 将模块按依赖关系排序，确保依赖模块先于被依赖模块启动
    private func topologicalSort(_ names: [String]) -> TopologySortResult {
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]
        
        // 初始化
        for name in names {
            inDegree[name] = 0
            adjacency[name] = []
        }
        
        // 构建有向图：依赖 -> 被依赖
        // 如果 B 依赖 A，则 A 必须先启动，图中 A -> B（A 指向 B）
        for name in names {
            let deps = getDependencies(for: name)
            for dep in deps {
                if names.contains(dep) {
                    adjacency[dep, default: []].append(name)
                    inDegree[name, default: 0] += 1
                }
            }
        }
        
        // Kahn 算法：从入度为 0 的节点开始
        var queue = names.filter { inDegree[$0] == 0 }
        queue.sort() // 稳定排序，保证可预测性
        
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
            // 找出循环中的节点
            let remaining = names.filter { !result.contains($0) }
            return .failure(cycle: remaining)
        }
    }
}

// MARK: - 测试代码

/// ModuleStarter 功能验证测试
/// 运行方式：在单元测试或 Playground 中调用 `ModuleStarterTests.runAllTests()`
public enum ModuleStarterTests {
    
    /// 测试用模拟模块
    final class TestModule: XRZModule {
        let name: String
        var shouldFail: Bool = false
        var startOrder: Int = 0
        static var globalCounter = 0
        static var lock = os_unfair_lock()
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {
            if shouldFail {
                throw ModuleStartError.simulatedFailure(name: name)
            }
            Self.lock.lock()
            Self.globalCounter += 1
            startOrder = Self.globalCounter
            Self.lock.unlock()
        }
        
        func stop() throws {}
    }
    
    /// 运行所有测试
    public static func runAllTests() {
        // 重置计数器
        TestModule.globalCounter = 0
        
        // 清理全局注册表
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
        
        print("\n🎉 所有 ModuleStarter 测试通过!")
    }
    
    // MARK: - 辅助方法
    
    /// 清理注册表中的所有模块
    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    // MARK: - 测试1: 按依赖顺序启动所有模块
    
    /// 测试拓扑排序启动顺序
    /// 模块结构：A 依赖 B，B 依赖 C
    /// 启动顺序应该是 C -> B -> A
    public static func testStartAllWithDependencies() {
        print("\n🧪 测试1: 按依赖顺序启动所有模块")
        
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
            fatalError("❌ 测试1失败: 不应有失败模块: \(failed)")
        }
        guard started == ["C", "B", "A"] else {
            fatalError("❌ 测试1失败: 期望顺序 [C, B, A]，实际 \(started)")
        }
        
        guard moduleC.startOrder < moduleB.startOrder else {
            fatalError("❌ 测试1失败: C 应在 B 之前启动")
        }
        guard moduleB.startOrder < moduleA.startOrder else {
            fatalError("❌ 测试1失败: B 应在 A 之前启动")
        }
        
        print("✅ 测试1通过: 依赖顺序 C -> B -> A 正确")
    }
    
    // MARK: - 测试2: 启动单个模块（自动启动依赖）
    
    /// 测试 startModule 自动启动依赖
    public static func testSingleModuleStart() {
        print("\n🧪 测试2: 启动单个模块（自动启动依赖）")
        
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
            fatalError("❌ 测试2失败: 启动 X 失败")
        }
        guard starter.isStarted("Y") else {
            fatalError("❌ 测试2失败: 依赖 Y 应已启动")
        }
        guard starter.isStarted("X") else {
            fatalError("❌ 测试2失败: X 应已启动")
        }
        
        print("✅ 测试2通过: 单个模块启动自动处理依赖")
    }
    
    // MARK: - 测试3: 失败处理（单个模块失败不影响其他）
    
    /// 测试失败隔离：一个模块失败不应阻止其他模块启动
    public static func testFailureHandling() {
        print("\n🧪 测试3: 失败处理（失败隔离）")
        
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
            fatalError("❌ 测试3失败: 不应返回整体失败")
        }
        guard started.count == 2 else {
            fatalError("❌ 测试3失败: 期望 2 个启动成功，实际 \(started.count)")
        }
        guard failed.count == 1 else {
            fatalError("❌ 测试3失败: 期望 1 个失败，实际 \(failed.count)")
        }
        guard failed.first?.0 == "Fail" else {
            fatalError("❌ 测试3失败: 期望 Fail 模块失败，实际 \(failed)")
        }
        guard starter.isStarted("OK1") || starter.isStarted("OK2") else {
            fatalError("❌ 测试3失败: 至少一个 OK 模块应已启动")
        }
        
        print("✅ 测试3通过: 失败隔离正常工作")
    }
    
    // MARK: - 测试4: 循环依赖检测
    
    /// 测试循环依赖检测
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
        
        print("✅ 测试4通过: 循环依赖检测正确")
    }
    
    // MARK: - 测试5: 长依赖链
    
    /// 测试 5 个模块的依赖链
    /// 链结构: E -> D -> C -> B -> A（E 依赖 D，D 依赖 C，...）
    /// 启动顺序: A -> B -> C -> D -> E
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
            fatalError("❌ 测试5失败: 不应返回失败")
        }
        guard started == ["A", "B", "C", "D", "E"] else {
            fatalError("❌ 测试5失败: 期望 [A, B, C, D, E]，实际 \(started)")
        }
        
        for i in 1..<5 {
            guard modules[i].startOrder > modules[i-1].startOrder else {
                fatalError("❌ 测试5失败: 模块 \(i) 应在 \(i-1) 之后启动")
            }
        }
        
        print("✅ 测试5通过: 5模块依赖链启动顺序正确")
    }
    
    // MARK: - 测试6: 重复启动（幂等性）
    
    /// 测试重复启动同一个模块是幂等的
    public static func testAlreadyStarted() {
        print("\n🧪 测试6: 重复启动（幂等性）")
        
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
            fatalError("❌ 测试6失败: 首次启动应返回 not already started")
        }
        
        let result2 = starter.startModule("M")
        guard case .success(let alreadyStarted2) = result2, alreadyStarted2 else {
            fatalError("❌ 测试6失败: 重复启动应返回 already started")
        }
        
        guard starter.isStarted("M") else {
            fatalError("❌ 测试6失败: M 应已启动")
        }
        
        print("✅ 测试6通过: 幂等启动")
    }
    
    // MARK: - 测试7: 缺失依赖
    
    /// 测试模块依赖未注册时的处理
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
            fatalError("❌ 测试7失败: 应因缺失依赖而失败")
        }
        if case .dependencyFailed(let name) = reason {
            guard name == "Missing" else {
                fatalError("❌ 测试7失败: 期望缺失依赖为 Missing，实际 \(name)")
            }
        } else {
            fatalError("❌ 测试7失败: 期望 dependencyFailed，实际 \(reason)")
        }
        
        print("✅ 测试7通过: 缺失依赖处理正确")
    }
    
    // MARK: - 测试8: 多个独立模块（无依赖关系）
    
    /// 测试多个无依赖模块的批量启动
    public static func testMultipleIndependentModules() {
        print("\n🧪 测试8: 多个独立模块")
        
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
            fatalError("❌ 测试8失败: 不应返回失败")
        }
        guard started.count == 3 else {
            fatalError("❌ 测试8失败: 期望 3 个启动成功，实际 \(started.count)")
        }
        guard failed.isEmpty else {
            fatalError("❌ 测试8失败: 期望 0 个失败，实际 \(failed.count)")
        }
        
        for name in names {
            guard starter.isStarted(name) else {
                fatalError("❌ 测试8失败: \(name) 应已启动")
            }
        }
        
        print("✅ 测试8通过: 所有独立模块启动成功")
    }
}
