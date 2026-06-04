// 功能5: 按顺序加载模块
// 对应: 先加载核心框架模块，再加载业务模块
// 优先级: P0

import Foundation

// MARK: - XRZModule 协议
/// 模块基础协议，所有模块必须实现
public protocol XRZModule: AnyObject {
    init()
    func start() throws
    func stop() throws
    var services: [String: Any] { get }
}

public extension XRZModule {
    var services: [String: Any] { [:] }
}

// MARK: - 模块加载结果
/// 模块加载结果枚举
public enum ModuleLoadResult {
    case success(metadata: ModuleMetadata)
    case failure(ModuleError)

    public var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}

// MARK: - 模块错误
/// 模块加载/运行过程中可能发生的错误
public enum ModuleError: Error {
    case notFound(name: String)
    case loadFailed(name: String, reason: String)
    case dependencyMissing(module: String, dependency: String)
    case versionIncompatible(module: String, required: String, actual: String)
    case alreadyLoaded(name: String)
    case notLoaded(name: String)
    case invalidMetadata(path: String)
    case startFailed(name: String, error: Error)
    case stopFailed(name: String, error: Error)
}

// MARK: - 依赖解析错误
/// 依赖解析过程中可能发生的错误
public enum DependencyResolverError: Error, LocalizedError {
    case circularDependency(path: [String])

    public var errorDescription: String? {
        switch self {
        case .circularDependency(let path):
            return "Circular dependency detected: \(path.joined(separator: " -> "))"
        }
    }
}

// MARK: - 依赖解析器
/// 依赖关系解析器
/// 负责循环依赖检测和拓扑排序，确保模块按正确顺序加载
public struct DependencyResolver {

    /// 对模块进行拓扑排序，确保依赖模块先加载
    /// - Parameter modules: 待排序的模块列表
    /// - Returns: 按依赖顺序排序后的模块列表（依赖在前，被依赖在后）
    /// - Throws: DependencyResolverError.circularDependency 如果发现循环依赖
    public static func resolveLoadOrder(modules: [ScannedModule]) throws -> [ScannedModule] {
        let moduleMap = Dictionary(uniqueKeysWithValues: modules.map { ($0.metadata.name, $0) })

        // 构建依赖图（合并 metadata 和 ConfigSystem 中的依赖配置）
        var graph: [String: [String]] = [:]
        for module in modules {
            let deps = getAllDependencies(for: module)
            graph[module.metadata.name] = deps.compactMap { dep in
                moduleMap[dep] != nil ? dep : nil
            }
        }

        // DFS 检测循环依赖
        if let cycle = detectCycle(in: graph) {
            throw DependencyResolverError.circularDependency(path: cycle)
        }

        // 拓扑排序
        return topologicalSort(modules: modules, graph: graph)
    }

    // MARK: - 获取完整依赖列表
    /// 合并 ConfigSystem 配置和模块元数据中的依赖
    private static func getAllDependencies(for module: ScannedModule) -> [String] {
        let configDeps = ConfigSystem.shared.getModuleDependencies(module.metadata.name)
        let metaDeps = module.metadata.dependencies
        return Array(Set(configDeps + metaDeps)).sorted()
    }

    // MARK: - DFS 循环依赖检测
    /// 使用 DFS 遍历所有节点，检测图中是否存在环
    private static func detectCycle(in graph: [String: [String]]) -> [String]? {
        var visited = Set<String>()
        var recursionStack = Set<String>()

        for node in graph.keys {
            if !visited.contains(node) {
                var path: [String] = []
                if let cycle = dfsDetectCycle(
                    node: node,
                    graph: graph,
                    visited: &visited,
                    recursionStack: &recursionStack,
                    path: &path
                ) {
                    return cycle
                }
            }
        }

        return nil
    }

    /// DFS 递归检测环
    /// - Returns: 如果存在环，返回环上的节点路径；否则返回 nil
    private static func dfsDetectCycle(
        node: String,
        graph: [String: [String]],
        visited: inout Set<String>,
        recursionStack: inout Set<String>,
        path: inout [String]
    ) -> [String]? {
        visited.insert(node)
        recursionStack.insert(node)
        path.append(node)

        for neighbor in graph[node] ?? [] {
            if !visited.contains(neighbor) {
                if let cycle = dfsDetectCycle(
                    node: neighbor,
                    graph: graph,
                    visited: &visited,
                    recursionStack: &recursionStack,
                    path: &path
                ) {
                    return cycle
                }
            } else if recursionStack.contains(neighbor) {
                // 发现环，提取环路径（从 neighbor 首次出现的位置到当前路径末尾，再加上 neighbor 形成闭环）
                if let index = path.firstIndex(of: neighbor) {
                    return Array(path[index...]) + [neighbor]
                }
            }
        }

        path.removeLast()
        recursionStack.remove(node)
        return nil
    }

    // MARK: - 拓扑排序（Kahn 算法）
    /// 基于入度的 Kahn 拓扑排序算法
    /// 同层级模块按优先级升序排列（优先级小的先加载）
    private static func topologicalSort(modules: [ScannedModule], graph: [String: [String]]) -> [ScannedModule] {
        let moduleMap = Dictionary(uniqueKeysWithValues: modules.map { ($0.metadata.name, $0) })
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        // 初始化入度和邻接表
        for module in modules {
            inDegree[module.metadata.name] = 0
            adjacency[module.metadata.name] = []
        }

        // 构建邻接表和计算入度
        // 依赖方向: dep -> module (dep 要先加载，所以 module 的入度 +1)
        for module in modules {
            for dep in graph[module.metadata.name] ?? [] {
                adjacency[dep, default: []].append(module.metadata.name)
                inDegree[module.metadata.name, default: 0] += 1
            }
        }

        // 初始化队列：入度为 0 的节点（无依赖的模块）
        // 使用优先级作为 tie-breaker，优先级小的先加载
        var queue = modules
            .filter { inDegree[$0.metadata.name] == 0 }
            .sorted { $0.metadata.priority < $1.metadata.priority }

        var result: [ScannedModule] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)

            for neighbor in adjacency[current.metadata.name] ?? [] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0, let mod = moduleMap[neighbor] {
                    // 按优先级插入队列，保持有序
                    let insertIndex = queue.firstIndex { $0.metadata.priority > mod.metadata.priority } ?? queue.count
                    queue.insert(mod, at: insertIndex)
                }
            }
        }

        return result
    }
}

// MARK: - 模块加载器
/// 模块加载器 (功能5 + 功能6 + 功能7)
public final class ModuleLoader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger: ModuleLogger
    private let scanner = ModuleScanner.shared

    public init(registry: ModuleRegistry, eventBus: EventBus, logger: ModuleLogger) {
        self.registry = registry
        self.eventBus = eventBus
        self.logger = logger
    }

    // MARK: - 扫描并加载
    public func scanAndLoad(from directory: String) {
        let url = URL(fileURLWithPath: directory)
        let scanned = scanner.scan(directory: url)

        // 扫描结果为有效模块（已由ModuleScanner过滤）
        let valid = scanned

        logger.info("Found \(valid.count) valid modules, resolving dependencies...")

        // 使用拓扑排序确保依赖模块先加载，同时检测循环依赖
        do {
            let sorted = try DependencyResolver.resolveLoadOrder(modules: valid)

            logger.info("Loading \(sorted.count) modules in dependency order...")

            // 加载核心模块（优先级 < 50）
            let coreModules = sorted.filter { $0.metadata.priority < 50 }
            logger.info("Loading \(coreModules.count) core modules...")
            loadModules(coreModules)

            // 加载业务模块（优先级 >= 50）
            let businessModules = sorted.filter { $0.metadata.priority >= 50 }
            logger.info("Loading \(businessModules.count) business modules...")
            loadModules(businessModules)

        } catch let error as DependencyResolverError {
            logger.error("Dependency resolution failed: \(error.localizedDescription)")
            eventBus.emit(.moduleLoadFailed, userInfo: [
                "error": error.localizedDescription,
                "phase": "dependencyResolution"
            ])
        } catch {
            logger.error("Unexpected error during dependency resolution: \(error)")
        }
    }

    // MARK: - 加载单个模块
    @discardableResult
    public func load(module: ScannedModule) -> ModuleLoadResult {
        let name = module.metadata.name

        // 检查是否已加载
        if registry.isLoaded(name: name) {
            return .failure(.alreadyLoaded(name: name))
        }

        // 检查配置是否启用
        guard ConfigSystem.shared.isModuleEnabled(name) else {
            logger.info("Module \(name) is disabled in config, skipping")
            return .failure(.loadFailed(name: name, reason: "Disabled in config"))
        }

        // 检查依赖
        let dependencies = ConfigSystem.shared.getModuleDependencies(name)
        for dep in dependencies {
            if !registry.isLoaded(name: dep) {
                logger.error("Module \(name) depends on \(dep) which is not loaded")
                return .failure(.dependencyMissing(module: name, dependency: dep))
            }
        }

        // 记录开始时间
        let startTime = Date()

        do {
            // 加载 bundle
            guard let bundle = Bundle(url: module.bundleURL) else {
                return .failure(.loadFailed(name: name, reason: "Failed to load bundle"))
            }

            // 获取入口类
            let className = module.metadata.entryClass
            guard let moduleClass = bundle.classNamed(className) as? XRZModule.Type else {
                return .failure(.loadFailed(name: name, reason: "Entry class \(className) not found or doesn't conform to XRZModule"))
            }

            // 实例化
            let instance = moduleClass.init()

            // 调用 start()
            try instance.start()

            // 注册到注册表
            registry.register(module: instance, name: name)

            let loadTime = Date().timeIntervalSince(startTime)
            logger.info("Module \(name) loaded in \(String(format: "%.3f", loadTime))s")

            // 发送事件
            eventBus.emit(.moduleDidLoad, userInfo: [
                "moduleName": name,
                "moduleVersion": module.metadata.version,
                "loadTime": loadTime
            ])

            return .success(metadata: module.metadata)

        } catch {
            logger.error("Failed to load module \(name): \(error)")

            // 发送失败事件
            eventBus.emit(.moduleLoadFailed, userInfo: [
                "moduleName": name,
                "error": error.localizedDescription
            ])

            return .failure(.startFailed(name: name, error: error))
        }
    }

    // MARK: - 卸载模块
    public func unload(name: String) {
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.warning("Module \(name) not found in registry")
            return
        }

        do {
            try module.stop()
            registry.unregister(name: name)

            logger.info("Module \(name) unloaded")
            eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        } catch {
            logger.error("Failed to stop module \(name): \(error)")
        }
    }

    // MARK: - 卸载所有
    public func unloadAllModules() {
        let allModules = registry.allModuleNames
        for name in allModules {
            unload(name: name)
        }
    }

    // MARK: - 私有方法
    private func loadModules(_ modules: [ScannedModule]) {
        for module in modules {
            let result = load(module: module)
            if !result.isSuccess {
                // 功能7: 加载失败不崩溃，继续加载其他
                logger.warning("Continuing to load remaining modules...")
            }
        }
    }
}

// MARK: - 测试代码
/// 模块加载器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ModuleLoaderTests.runAllTests()`
public enum ModuleLoaderTests {

    // MARK: - 模拟模块
    /// 用于测试的模拟模块实现
    public final class MockModule: XRZModule {
        public let name: String
        public private(set) var isStarted = false
        public private(set) var isStopped = false
        private static var counter = 0

        public init() {
            Self.counter += 1
            self.name = "MockModule\(Self.counter)"
        }

        public func start() throws {
            isStarted = true
        }

        public func stop() throws {
            isStopped = true
        }

        public var services: [String: Any] { [:] }
    }

    // MARK: - 运行所有测试
    public static func runAllTests() {
        print("=== ModuleLoader Tests ===")

        // 重置配置系统，确保测试环境干净
        ConfigSystem.shared.resetForTests()

        testTopologicalSort()
        testCircularDependencyDetection()
        testLoadFailureHandling()
        testUnloadFunction()

        print("\n=== All ModuleLoader Tests Passed ✅ ===")
    }

    // MARK: - 测试1: 正常依赖加载顺序（拓扑排序）
    public static func testTopologicalSort() {
        print("\n🧪 Test 1: Topological Sort (Dependency Order)")

        // 构造模块依赖链: C <- B <- A (A 依赖 B, B 依赖 C)
        let moduleC = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/C"),
            name: "ModuleC",
            metadata: ModuleMetadata(
                name: "ModuleC",
                version: "1.0.0",
                description: "Core module C",
                entryClass: "ModuleC",
                priority: 10,
                dependencies: []
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/C/C.bundle"),
        )

        let moduleB = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/B"),
            name: "ModuleB",
            metadata: ModuleMetadata(
                name: "ModuleB",
                version: "1.0.0",
                description: "Core module B",
                entryClass: "ModuleB",
                priority: 20,
                dependencies: ["ModuleC"]
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/B/B.bundle"),
        )

        let moduleA = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/A"),
            name: "ModuleA",
            metadata: ModuleMetadata(
                name: "ModuleA",
                version: "1.0.0",
                description: "Business module A",
                entryClass: "ModuleA",
                priority: 60,
                dependencies: ["ModuleB"]
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/A/A.bundle"),
        )

        let modules = [moduleA, moduleB, moduleC]

        do {
            let sorted = try DependencyResolver.resolveLoadOrder(modules: modules)
            let names = sorted.map { $0.metadata.name }

            // 验证顺序: C 必须在 B 之前, B 必须在 A 之前
            guard let indexA = names.firstIndex(of: "ModuleA"),
                  let indexB = names.firstIndex(of: "ModuleB"),
                  let indexC = names.firstIndex(of: "ModuleC") else {
                fatalError("❌ Test 1 failed: Missing modules in sorted result")
            }

            guard indexC < indexB && indexB < indexA else {
                fatalError("❌ Test 1 failed: Wrong load order. Expected C before B before A, got \(names)")
            }

            print("✅ Test 1 passed: Load order is \(names.joined(separator: " -> "))")
        } catch {
            fatalError("❌ Test 1 failed: Unexpected error: \(error)")
        }
    }

    // MARK: - 测试2: 循环依赖检测
    public static func testCircularDependencyDetection() {
        print("\n🧪 Test 2: Circular Dependency Detection")

        let moduleA = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/A"),
            name: "ModuleA",
            metadata: ModuleMetadata(
                name: "ModuleA",
                version: "1.0.0",
                description: "Module A",
                entryClass: "ModuleA",
                priority: 10,
                dependencies: ["ModuleB"]
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/A/A.bundle"),
        )

        let moduleB = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/B"),
            name: "ModuleB",
            metadata: ModuleMetadata(
                name: "ModuleB",
                version: "1.0.0",
                description: "Module B",
                entryClass: "ModuleB",
                priority: 20,
                dependencies: ["ModuleA"]
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/B/B.bundle"),
        )

        let modules = [moduleA, moduleB]

        do {
            _ = try DependencyResolver.resolveLoadOrder(modules: modules)
            fatalError("❌ Test 2 failed: Should have detected circular dependency")
        } catch DependencyResolverError.circularDependency(let path) {
            let pathStr = path.joined(separator: " -> ")
            guard path.contains("ModuleA") && path.contains("ModuleB") else {
                fatalError("❌ Test 2 failed: Cycle path doesn't contain expected modules: \(pathStr)")
            }
            print("✅ Test 2 passed: Circular dependency detected: \(pathStr)")
        } catch {
            fatalError("❌ Test 2 failed: Unexpected error type: \(error)")
        }
    }

    // MARK: - 测试3: 加载失败处理
    public static func testLoadFailureHandling() {
        print("\n🧪 Test 3: Load Failure Handling")

        let registry = ModuleRegistry()
        let eventBus = EventBus()
        let logger = ModuleLogger(category: "TestLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)

        // ---- 3a: 测试依赖缺失 ----
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "DepTestModule",
            enabled: true,
            priority: 10,
            dependencies: ["MissingDep"]
        ))

        let depTestModule = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/DepTestModule"),
            name: "DepTestModule",
            metadata: ModuleMetadata(
                name: "DepTestModule",
                version: "1.0.0",
                description: "Test",
                entryClass: "DepTestModule",
                priority: 10,
                dependencies: ["MissingDep"]
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/DepTestModule/DepTestModule.bundle"),
        )

        let result1 = loader.load(module: depTestModule)
        switch result1 {
        case .failure(.dependencyMissing(let module, let dependency)):
            guard module == "DepTestModule" && dependency == "MissingDep" else {
                fatalError("❌ Test 3a failed: Wrong dependency error details")
            }
            print("✅ Test 3a passed: Dependency missing detected (\(module) needs \(dependency))")
        default:
            fatalError("❌ Test 3a failed: Expected dependencyMissing, got \(result1)")
        }

        // ---- 3b: 测试模块已加载 ----
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "LoadedTestModule",
            enabled: true,
            priority: 10,
            dependencies: []
        ))

        let mockModule = MockModule()
        registry.register(module: mockModule, name: "LoadedTestModule")

        let loadedTestModule = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/LoadedTestModule"),
            name: "LoadedTestModule",
            metadata: ModuleMetadata(
                name: "LoadedTestModule",
                version: "1.0.0",
                description: "Test",
                entryClass: "LoadedTestModule",
                priority: 10,
                dependencies: []
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/LoadedTestModule/LoadedTestModule.bundle"),
        )

        let result2 = loader.load(module: loadedTestModule)
        switch result2 {
        case .failure(.alreadyLoaded(let name)):
            guard name == "LoadedTestModule" else {
                fatalError("❌ Test 3b failed: Wrong alreadyLoaded name")
            }
            print("✅ Test 3b passed: Already loaded detected (\(name))")
        default:
            fatalError("❌ Test 3b failed: Expected alreadyLoaded, got \(result2)")
        }

        // ---- 3c: 测试配置禁用 ----
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "DisabledTestModule",
            enabled: false,
            priority: 10,
            dependencies: []
        ))

        let disabledTestModule = ScannedModule(
            path: URL(fileURLWithPath: "/tmp/DisabledTestModule"),
            name: "DisabledTestModule",
            metadata: ModuleMetadata(
                name: "DisabledTestModule",
                version: "1.0.0",
                description: "Test",
                entryClass: "DisabledTestModule",
                priority: 10,
                dependencies: []
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/DisabledTestModule/DisabledTestModule.bundle"),
        )

        let result3 = loader.load(module: disabledTestModule)
        switch result3 {
        case .failure(.loadFailed(let name, let reason)):
            guard name == "DisabledTestModule", reason == "Disabled in config" else {
                fatalError("❌ Test 3c failed: Wrong loadFailed details")
            }
            print("✅ Test 3c passed: Disabled module skipped (\(name): \(reason))")
        default:
            fatalError("❌ Test 3c failed: Expected loadFailed, got \(result3)")
        }

        // 清理
        registry.unregister(name: "LoadedTestModule")
        ConfigSystem.shared.setModuleEnabled("DepTestModule", true)
        ConfigSystem.shared.resetForTests()
    }

    // MARK: - 测试4: 卸载功能
    public static func testUnloadFunction() {
        print("\n🧪 Test 4: Unload Function")

        let registry = ModuleRegistry()
        let eventBus = EventBus()
        let logger = ModuleLogger(category: "TestLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)

        // 注册模拟模块
        let mockModule = MockModule()
        registry.register(module: mockModule, name: "UnloadTestModule")
        guard registry.isLoaded(name: "UnloadTestModule") else {
            fatalError("❌ Test 4 setup failed: Module not registered")
        }

        // 卸载
        loader.unload(name: "UnloadTestModule")

        guard !registry.isLoaded(name: "UnloadTestModule") else {
            fatalError("❌ Test 4a failed: Module still loaded after unload")
        }
        print("✅ Test 4a passed: Module unloaded successfully")

        // 验证 stop() 被调用
        guard mockModule.isStopped else {
            fatalError("❌ Test 4b failed: Module stop() was not called")
        }
        print("✅ Test 4b passed: Module stop() called during unload")

        // 测试卸载不存在的模块（不应崩溃）
        loader.unload(name: "NonExistentModule")
        print("✅ Test 4c passed: Unloading non-existent module handled gracefully")
    }
}
