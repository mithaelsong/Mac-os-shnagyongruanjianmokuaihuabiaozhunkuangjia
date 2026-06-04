// 功能14: 服务调用
// 对应: 模块 A 调用模块 B 的服务（通过协议，不直接 import）
// 优先级: P0

import Foundation
import os

// MARK: - ServiceDescriptor
/// 服务描述符，描述一个模块提供的服务
/// 用于服务发现时返回元信息，不包含实际实例
public struct ServiceDescriptor: Sendable {
    public let moduleName: String      // 提供服务的模块名
    public let serviceName: String     // 服务名称
    public let version: String         // 服务版本（如 "1.0.0"）
    public let protocolName: String    // 协议类型名（用于类型检查和调试）
    
    public init(moduleName: String, serviceName: String, version: String, protocolName: String) {
        self.moduleName = moduleName
        self.serviceName = serviceName
        self.version = version
        self.protocolName = protocolName
    }
}

// MARK: - ServiceRegistry
/// 服务注册表 (功能14)
/// 管理模块提供的服务注册和发现，是模块间通过协议调用的核心机制
/// 特性:
/// - 模块通过协议声明自己提供的服务（类型安全）
/// - 按服务名称查找所有提供该服务的模块（服务发现）
/// - 通过模块名称 + 服务名称精确获取服务实例（服务调用）
/// - 支持简单版本号匹配（minimumVersion 过滤）
/// - 线程安全（os_unfair_lock 保护）
/// - 模块卸载时自动注销该模块的所有服务
public final class ServiceRegistry: Sendable {
    public static let shared = ServiceRegistry()
    
    /// 服务条目：存储服务实例和描述信息
    private struct ServiceEntry {
        let descriptor: ServiceDescriptor
        let instance: Any
    }
    
    /// 两层索引结构，支持快速查找：
    /// 1. serviceName -> [ServiceEntry]   按服务名查找所有提供者（服务发现）
    /// 2. moduleName.serviceName -> ServiceEntry   精确查找（服务调用）
    private final class Storage: @unchecked Sendable {
        var byServiceName: [String: [ServiceEntry]] = [:]
        var byModuleAndService: [String: ServiceEntry] = [:]
        var lock = os_unfair_lock()
    }
    
    private let storage = Storage()
    private let logger = ModuleLogger(category: "ServiceRegistry")
    
    private init() {}
    
    // MARK: - 注册服务
    /// 注册一个服务到服务注册表
    /// 模块在 start() 中调用此方法，将自身提供的服务暴露给其他模块
    /// - Parameters:
    ///   - instance: 服务实例（必须实现对应的协议）
    ///   - serviceName: 服务名称（全局唯一标识，如 "DataSource"）
    ///   - moduleName: 提供服务的模块名称（如 "MarketModule"）
    ///   - version: 服务版本号（语义化版本，如 "1.0.0"）
    ///   - protocolType: 服务协议类型（用于类型安全和调试）
    public func register<T>(
        _ instance: T,
        serviceName: String,
        moduleName: String,
        version: String,
        protocolType: T.Type
    ) {
        let descriptor = ServiceDescriptor(
            moduleName: moduleName,
            serviceName: serviceName,
            version: version,
            protocolName: String(describing: protocolType)
        )
        let entry = ServiceEntry(descriptor: descriptor, instance: instance)
        let key = makeKey(moduleName: moduleName, serviceName: serviceName)
        
        os_unfair_lock_lock(&storage.lock)
        storage.byModuleAndService[key] = entry
        storage.byServiceName[serviceName, default: []].append(entry)
        os_unfair_lock_unlock(&storage.lock)
        
        logger.info("Registered service '\(serviceName)' v\(version) from module '\(moduleName)' (protocol: \(descriptor.protocolName))")
    }
    
    // MARK: - 服务发现
    /// 按服务名称查找所有提供该服务的模块
    /// 返回服务描述符列表（不包含实例），用于展示服务提供者列表或选择策略
    /// - Parameter serviceName: 服务名称
    /// - Returns: 该服务所有提供者的描述符列表
    public func discover(serviceName: String) -> [ServiceDescriptor] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return storage.byServiceName[serviceName]?.map { $0.descriptor } ?? []
    }
    
    // MARK: - 服务调用（按模块名+服务名）
    /// 通过模块名称 + 服务名称精确获取服务实例
    /// 这是核心服务调用路径，确保调用方知道要找哪个模块的哪个服务
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - serviceName: 服务名称
    ///   - type: 期望的服务协议类型（编译期类型安全）
    /// - Returns: 类型匹配的服务实例，如果未找到或类型不匹配返回 nil
    public func resolve<T>(
        moduleName: String,
        serviceName: String,
        type: T.Type
    ) -> T? {
        let key = makeKey(moduleName: moduleName, serviceName: serviceName)
        
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let entry = storage.byModuleAndService[key] else {
            logger.warning("Service '\(serviceName)' not found in module '\(moduleName)'")
            return nil
        }
        
        guard let typed = entry.instance as? T else {
            logger.error("Service '\(serviceName)' from '\(moduleName)' type mismatch: expected \(String(describing: T.self)), actual \(entry.descriptor.protocolName)")
            return nil
        }
        
        return typed
    }
    
    // MARK: - 服务调用（按服务名，支持版本要求）
    /// 按服务名称查找，支持最低版本要求
    /// 当调用方不关心具体哪个模块提供，只要求版本足够新时使用
    /// - Parameters:
    ///   - serviceName: 服务名称
    ///   - type: 期望的服务协议类型
    ///   - minimumVersion: 最低版本要求（可选，如 "1.0.0"）。nil 表示不检查版本
    /// - Returns: 第一个匹配版本要求的服务实例
    public func resolve<T>(
        serviceName: String,
        type: T.Type,
        minimumVersion: String? = nil
    ) -> T? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let entries = storage.byServiceName[serviceName] else {
            logger.warning("Service '\(serviceName)' not found in registry")
            return nil
        }
        
        // 版本过滤：只保留版本号 >= minimumVersion 的条目
        let candidates: [ServiceEntry]
        if let minVersion = minimumVersion {
            candidates = entries.filter { entry in
                versionCompare(entry.descriptor.version, minVersion) >= 0
            }
        } else {
            candidates = entries
        }
        
        guard let entry = candidates.first else {
            if minimumVersion != nil {
                logger.warning("Service '\(serviceName)' found but no version >= \(minimumVersion!)")
            } else {
                logger.warning("Service '\(serviceName)' found but no valid instance")
            }
            return nil
        }
        
        guard let typed = entry.instance as? T else {
            logger.error("Service '\(serviceName)' from '\(entry.descriptor.moduleName)' type mismatch: expected \(String(describing: T.self)), actual \(entry.descriptor.protocolName)")
            return nil
        }
        
        if let minVersion = minimumVersion {
            logger.info("Resolved service '\(serviceName)' v\(entry.descriptor.version) from '\(entry.descriptor.moduleName)' (>= \(minVersion))")
        }
        
        return typed
    }
    
    // MARK: - 注销服务
    /// 注销指定模块的指定服务（模块热替换或卸载时使用）
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - serviceName: 服务名称
    public func unregister(moduleName: String, serviceName: String) {
        let key = makeKey(moduleName: moduleName, serviceName: serviceName)
        
        os_unfair_lock_lock(&storage.lock)
        if let entry = storage.byModuleAndService.removeValue(forKey: key) {
            storage.byServiceName[serviceName]?.removeAll { $0.descriptor.moduleName == moduleName }
            if storage.byServiceName[serviceName]?.isEmpty == true {
                storage.byServiceName.removeValue(forKey: serviceName)
            }
            os_unfair_lock_unlock(&storage.lock)
            logger.info("Unregistered service '\(serviceName)' from module '\(moduleName)'")
        } else {
            os_unfair_lock_unlock(&storage.lock)
            logger.warning("Unregister failed: service '\(serviceName)' not found in module '\(moduleName)'")
        }
    }
    
    // MARK: - 注销模块的所有服务
    /// 注销某个模块提供的所有服务（模块卸载时调用）
    /// - Parameter moduleName: 模块名称
    public func unregisterAll(moduleName: String) {
        os_unfair_lock_lock(&storage.lock)
        
        let keysToRemove = storage.byModuleAndService.keys.filter { $0.hasPrefix("\(moduleName).") }
        for key in keysToRemove {
            if let entry = storage.byModuleAndService.removeValue(forKey: key) {
                let serviceName = entry.descriptor.serviceName
                storage.byServiceName[serviceName]?.removeAll { $0.descriptor.moduleName == moduleName }
                if storage.byServiceName[serviceName]?.isEmpty == true {
                    storage.byServiceName.removeValue(forKey: serviceName)
                }
            }
        }
        
        os_unfair_lock_unlock(&storage.lock)
        logger.info("Unregistered all services from module '\(moduleName)' (\(keysToRemove.count) services)")
    }
    
    // MARK: - 统计信息
    /// 获取所有已注册的服务名称列表（去重）
    public var allServiceNames: [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return Array(storage.byServiceName.keys)
    }
    
    /// 获取指定模块提供的所有服务的描述符
    /// - Parameter moduleName: 模块名称
    /// - Returns: 该模块提供的所有服务描述符
    public func services(of moduleName: String) -> [ServiceDescriptor] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return storage.byModuleAndService.values
            .filter { $0.descriptor.moduleName == moduleName }
            .map { $0.descriptor }
    }
    
    /// 获取当前注册的服务总数
    public var totalServiceCount: Int {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.byModuleAndService.count
    }
    
    // MARK: - 私有方法
    /// 构造复合键：moduleName.serviceName
    private func makeKey(moduleName: String, serviceName: String) -> String {
        "\(moduleName).\(serviceName)"
    }
    
    /// 简单版本号比较（支持 x.y.z 格式，不足位补零）
    /// 返回: -1 (a < b), 0 (a == b), 1 (a > b)
    private func versionCompare(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return -1 }
            if av > bv { return 1 }
        }
        return 0
    }
}

// MARK: - XRZModule 服务注册扩展
/// 为 XRZModule 提供便捷的注册服务方法
/// 模块在 start() 中可通过 self.registerService(...) 暴露服务
public extension XRZModule {
    /// 便捷方法：从模块注册服务到 ServiceRegistry
    /// - Parameters:
    ///   - instance: 服务实例
    ///   - serviceName: 服务名称
    ///   - moduleName: 提供服务的模块名称
    ///   - version: 服务版本号
    ///   - protocolType: 服务协议类型
    func registerService<T>(
        _ instance: T,
        serviceName: String,
        moduleName: String,
        version: String,
        protocolType: T.Type
    ) {
        ServiceRegistry.shared.register(
            instance,
            serviceName: serviceName,
            moduleName: moduleName,
            version: version,
            protocolType: protocolType
        )
    }
}

// MARK: - ServiceInvoker
/// 服务调用器 (功能14)
/// 提供便捷的闭包风格服务调用，封装 ServiceRegistry 的查找逻辑
/// 支持指定模块调用和任意模块调用两种模式
public final class ServiceInvoker: Sendable {
    public static let shared = ServiceInvoker()
    
    private let registry = ServiceRegistry.shared
    private let logger = ModuleLogger(category: "ServiceInvoker")
    
    private init() {}
    
    // MARK: - 调用指定模块的服务
    /// 调用指定模块的指定服务，通过闭包执行方法
    /// 类型由闭包参数推断，编译期保证类型安全
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - serviceName: 服务名称
    ///   - method: 接收服务实例并返回结果的闭包
    /// - Returns: 闭包返回的结果，如果服务未找到返回 nil
    public func invoke<T, R>(
        moduleName: String,
        serviceName: String,
        method: (T) -> R
    ) -> R? {
        guard let service: T = registry.resolve(moduleName: moduleName, serviceName: serviceName, type: T.self) else {
            logger.warning("Invoke failed: cannot resolve \(moduleName).\(serviceName) as \(String(describing: T.self))")
            return nil
        }
        return method(service)
    }
    
    // MARK: - 调用任意提供该服务的模块
    /// 按服务名查找任意提供该服务的模块，通过闭包执行方法
    /// 支持最低版本要求，返回第一个匹配版本的服务实例
    /// - Parameters:
    ///   - serviceName: 服务名称
    ///   - method: 接收服务实例并返回结果的闭包
    ///   - minimumVersion: 最低版本要求（可选）
    /// - Returns: 闭包返回的结果，如果服务未找到返回 nil
    public func invokeAny<T, R>(
        serviceName: String,
        method: (T) -> R,
        minimumVersion: String? = nil
    ) -> R? {
        guard let service: T = registry.resolve(serviceName: serviceName, type: T.self, minimumVersion: minimumVersion) else {
            logger.warning("InvokeAny failed: cannot resolve service '\(serviceName)' (minVersion: \(minimumVersion ?? "none"))")
            return nil
        }
        return method(service)
    }
    
    // MARK: - 异步调用
    /// 异步调用指定模块的服务，在全局队列执行后回调到主队列
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - serviceName: 服务名称
    ///   - method: 接收服务实例并返回结果的闭包
    ///   - completion: 完成回调（主队列）
    public func invokeAsync<T, R>(
        moduleName: String,
        serviceName: String,
        method: @escaping (T) -> R,
        completion: @escaping (R?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.invoke(moduleName: moduleName, serviceName: serviceName, method: method)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

// MARK: - 测试代码
/// 服务注册表功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ServiceRegistryTests.runAllTests()`
public enum ServiceRegistryTests {
    
    // MARK: - 测试协议
    /// 数据源服务协议（模拟外部模块定义）
    public protocol DataSourceService {
        func fetchData(symbol: String) -> String
        var sourceName: String { get }
    }
    
    /// 指标计算服务协议（模拟外部模块定义）
    public protocol IndicatorService {
        func calculate(name: String) -> Double
    }
    
    // MARK: - 测试实现
    /// 模块 A 提供的数据源服务实现
    public final class MockDataSource: DataSourceService {
        public let sourceName = "MockDataSource"
        public func fetchData(symbol: String) -> String { "Data for \(symbol) from MockDataSource" }
    }
    
    /// 模块 B 提供的指标计算服务实现
    public final class MockIndicator: IndicatorService {
        public func calculate(name: String) -> Double { 42.0 }
    }
    
    /// 模块 C 提供的数据源服务实现（新版本）
    public final class MockDataSourceV2: DataSourceService {
        public let sourceName = "MockDataSourceV2"
        public func fetchData(symbol: String) -> String { "V2 Data for \(symbol)" }
    }
    
    // MARK: - 运行所有测试
    public static func runAllTests() {
        print("=== ServiceRegistry Tests ===")
        testRegisterAndResolve()
        testDiscover()
        testVersionMatching()
        testUnregister()
        testInvoke()
        testInvokeAny()
        testAsyncInvoke()
        testThreadSafety()
        print("\n=== All ServiceRegistry Tests Passed ✅ ===")
    }
    
    // MARK: - 测试1: 注册与精确解析
    private static func testRegisterAndResolve() {
        print("\n🧪 Test 1: Register and Resolve")
        
        let registry = ServiceRegistry()
        let ds = MockDataSource()
        registry.register(ds, serviceName: "DataSource", moduleName: "MarketModule", version: "1.0.0", protocolType: DataSourceService.self)
        
        // 精确解析
        guard let resolved: DataSourceService = registry.resolve(moduleName: "MarketModule", serviceName: "DataSource", type: DataSourceService.self) else {
            fatalError("❌ Test 1 failed: resolve returned nil")
        }
        guard resolved.fetchData(symbol: "BTC") == "Data for BTC from MockDataSource" else {
            fatalError("❌ Test 1 failed: wrong data")
        }
        guard resolved.sourceName == "MockDataSource" else {
            fatalError("❌ Test 1 failed: wrong sourceName")
        }
        
        // 解析不存在的模块
        let notFound = registry.resolve(moduleName: "FakeModule", serviceName: "DataSource", type: DataSourceService.self)
        guard notFound == nil else { fatalError("❌ Test 1b failed: should be nil for non-existent module") }
        
        // 解析不存在的类型（类型不匹配）
        let wrongType = registry.resolve(moduleName: "MarketModule", serviceName: "DataSource", type: IndicatorService.self)
        guard wrongType == nil else { fatalError("❌ Test 1c failed: should be nil for wrong type") }
        
        print("✅ Test 1 passed: Register and resolve work correctly")
    }
    
    // MARK: - 测试2: 服务发现
    private static func testDiscover() {
        print("\n🧪 Test 2: Service Discovery")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "MarketA", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "MarketB", version: "1.1.0", protocolType: DataSourceService.self)
        registry.register(MockIndicator(), serviceName: "Indicator", moduleName: "CalcModule", version: "2.0.0", protocolType: IndicatorService.self)
        
        // 发现 DataSource 的所有提供者
        let providers = registry.discover(serviceName: "DataSource")
        guard providers.count == 2 else { fatalError("❌ Test 2a failed: expected 2 providers, got \(providers.count)") }
        let names = providers.map(\.moduleName).sorted()
        guard names == ["MarketA", "MarketB"] else { fatalError("❌ Test 2a failed: wrong provider names: \(names)") }
        
        // 发现不存在的服
        let empty = registry.discover(serviceName: "NonExistent")
        guard empty.isEmpty else { fatalError("❌ Test 2b failed: should be empty") }
        
        // 验证服务描述符内容
        let desc = providers.first { $0.moduleName == "MarketB" }!
        guard desc.version == "1.1.0" && desc.serviceName == "DataSource" else {
            fatalError("❌ Test 2c failed: descriptor content incorrect")
        }
        
        print("✅ Test 2 passed: Service discovery works correctly")
    }
    
    // MARK: - 测试3: 版本匹配
    private static func testVersionMatching() {
        print("\n🧪 Test 3: Version Matching")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "OldModule", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSourceV2(), serviceName: "DataSource", moduleName: "NewModule", version: "2.0.0", protocolType: DataSourceService.self)
        
        // 不要求版本，应返回第一个注册的（OldModule，因为注册顺序优先）
        let any = registry.resolve(serviceName: "DataSource", type: DataSourceService.self)
        guard any != nil else { fatalError("❌ Test 3a failed: any resolve returned nil") }
        
        // 要求 >= 1.5.0，应返回 NewModule（V2）
        let v2 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "1.5.0")
        guard let v2ds = v2 else { fatalError("❌ Test 3b failed: v2 not found with minVersion 1.5.0") }
        guard v2ds.fetchData(symbol: "X") == "V2 Data for X" else { fatalError("❌ Test 3b failed: got wrong instance") }
        guard v2ds.sourceName == "MockDataSourceV2" else { fatalError("❌ Test 3b failed: not V2 instance") }
        
        // 要求 >= 3.0.0，应返回 nil（没有满足条件的）
        let v3 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "3.0.0")
        guard v3 == nil else { fatalError("❌ Test 3c failed: should be nil for minVersion 3.0.0") }
        
        // 边界：要求 >= 1.0.0，两个都满足，返回第一个（OldModule）
        let v1 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "1.0.0")
        guard v1 != nil else { fatalError("❌ Test 3d failed: v1 should be found") }
        
        print("✅ Test 3 passed: Version matching works correctly")
    }
    
    // MARK: - 测试4: 注销服务
    private static func testUnregister() {
        print("\n🧪 Test 4: Unregister")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "ModA", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockIndicator(), serviceName: "Indicator", moduleName: "ModA", version: "1.0.0", protocolType: IndicatorService.self)
        
        // 注销单个服务
        registry.unregister(moduleName: "ModA", serviceName: "DataSource")
        guard registry.resolve(moduleName: "ModA", serviceName: "DataSource", type: DataSourceService.self) == nil else {
            fatalError("❌ Test 4a failed: DataSource should be unregistered")
        }
        guard registry.resolve(moduleName: "ModA", serviceName: "Indicator", type: IndicatorService.self) != nil else {
            fatalError("❌ Test 4b failed: Indicator should still exist")
        }
        
        // 注销模块的所有服务
        registry.unregisterAll(moduleName: "ModA")
        guard registry.services(of: "ModA").isEmpty else {
            fatalError("❌ Test 4c failed: all services of ModA should be removed")
        }
        guard registry.discover(serviceName: "DataSource").isEmpty else {
            fatalError("❌ Test 4d failed: DataSource should be removed from discover")
        }
        
        // 注销不存在的服务（不应崩溃）
        registry.unregister(moduleName: "ModA", serviceName: "FakeService")
        
        print("✅ Test 4 passed: Unregister works correctly")
    }
    
    // MARK: - 测试5: 调用器（指定模块）
    private static func testInvoke() {
        print("\n🧪 Test 5: ServiceInvoker (invoke)")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "Market", version: "1.0.0", protocolType: DataSourceService.self)
        
        let result = ServiceInvoker.shared.invoke(moduleName: "Market", serviceName: "DataSource") { (svc: DataSourceService) in
            svc.fetchData(symbol: "ETH")
        }
        guard result == "Data for ETH from MockDataSource" else {
            fatalError("❌ Test 5 failed: wrong result: \(String(describing: result))")
        }
        
        // 调用不存在的服务
        let nilResult = ServiceInvoker.shared.invoke(moduleName: "Fake", serviceName: "Fake") { (svc: DataSourceService) in
            svc.fetchData(symbol: "X")
        }
        guard nilResult == nil else { fatalError("❌ Test 5b failed: should be nil") }
        
        print("✅ Test 5 passed: ServiceInvoker invoke works correctly")
    }
    
    // MARK: - 测试6: 调用器（任意模块）
    private static func testInvokeAny() {
        print("\n🧪 Test 6: ServiceInvoker (invokeAny)")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "Market", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSourceV2(), serviceName: "DataSource", moduleName: "MarketV2", version: "2.0.0", protocolType: DataSourceService.self)
        
        // 任意调用，不指定版本
        let result1 = ServiceInvoker.shared.invokeAny(serviceName: "DataSource") { (svc: DataSourceService) in
            svc.fetchData(symbol: "BTC")
        }
        guard result1 != nil else { fatalError("❌ Test 6a failed: invokeAny returned nil") }
        
        // 指定最低版本 2.0.0，应返回 V2
        let result2 = ServiceInvoker.shared.invokeAny(serviceName: "DataSource", method: { (svc: DataSourceService) in
            svc.sourceName
        }, minimumVersion: "2.0.0")
        guard result2 == "MockDataSourceV2" else { fatalError("❌ Test 6b failed: expected V2, got \(String(describing: result2))") }
        
        print("✅ Test 6 passed: ServiceInvoker invokeAny works correctly")
    }
    
    // MARK: - 测试7: 异步调用
    private static func testAsyncInvoke() {
        print("\n🧪 Test 7: Async Invoke")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "AsyncMarket", version: "1.0.0", protocolType: DataSourceService.self)
        
        let semaphore = DispatchSemaphore(value: 0)
        var asyncResult: String?
        var onMainThread = false
        
        ServiceInvoker.shared.invokeAsync(moduleName: "AsyncMarket", serviceName: "DataSource") { (svc: DataSourceService) in
            svc.fetchData(symbol: "SOL")
        } completion: { result in
            onMainThread = Thread.isMainThread
            asyncResult = result
            semaphore.signal()
        }
        
        let timeout = semaphore.wait(timeout: .now() + 2)
        guard timeout == .success else { fatalError("❌ Test 7 failed: async timeout") }
        guard asyncResult == "Data for SOL from MockDataSource" else { fatalError("❌ Test 7 failed: wrong result: \(String(describing: asyncResult))") }
        guard onMainThread else { fatalError("❌ Test 7 failed: completion not on main thread") }
        
        print("✅ Test 7 passed: Async invoke works correctly")
    }
    
    // MARK: - 测试8: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 Test 8: Thread Safety (100 concurrent registrations)")
        
        let registry = ServiceRegistry()
        let group = DispatchGroup()
        
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "Mod\(i)", version: "1.0.0", protocolType: DataSourceService.self)
                group.leave()
            }
        }
        group.wait()
        
        // 验证发现结果
        let providers = registry.discover(serviceName: "DataSource")
        guard providers.count == 100 else { fatalError("❌ Test 8a failed: expected 100 providers, got \(providers.count)") }
        
        // 验证总数
        guard registry.totalServiceCount == 100 else { fatalError("❌ Test 8b failed: expected 100 services, got \(registry.totalServiceCount)") }
        
        // 并发解析
        let resolveGroup = DispatchGroup()
        var resolvedCount = 0
        let countLock = NSLock()
        for i in 0..<100 {
            resolveGroup.enter()
            DispatchQueue.global().async {
                let svc: DataSourceService? = registry.resolve(moduleName: "Mod\(i)", serviceName: "DataSource", type: DataSourceService.self)
                if svc != nil {
                    countLock.lock()
                    resolvedCount += 1
                    countLock.unlock()
                }
                resolveGroup.leave()
            }
        }
        resolveGroup.wait()
        guard resolvedCount == 100 else { fatalError("❌ Test 8c failed: expected 100 resolved, got \(resolvedCount)") }
        
        print("✅ Test 8 passed: Thread safety verified (100 concurrent registrations + 100 concurrent resolves)")
    }
}

// MARK: - 使用示例
/*
 // 1. 定义服务协议（在公共头文件中）
 public protocol IndicatorEngineProtocol {
     func calculateRSI(symbol: String, period: Int) -> [Double]
     func calculateMA(symbol: String, period: Int) -> [Double]
 }
 
 // 2. 模块实现并注册服务（在模块的 start() 中）
 class IndicatorEngineModule: XRZModule {
     func start() throws {
         let engine = IndicatorEngineImpl()
         registerService(
             engine,
             serviceName: "IndicatorEngine",
             moduleName: "IndicatorEngine",
             version: "1.0.0",
             protocolType: IndicatorEngineProtocol.self
         )
     }
 }
 
 // 3. 其他模块调用服务（三种方式）
 
 // 方式A：精确调用（知道要找哪个模块）
 let rsi = ServiceInvoker.shared.invoke(
     moduleName: "IndicatorEngine",
     serviceName: "IndicatorEngine"
 ) { (engine: IndicatorEngineProtocol) in
     engine.calculateRSI(symbol: "BTC", period: 14)
 }
 
 // 方式B：任意调用（不关心哪个模块提供）
 let ma = ServiceInvoker.shared.invokeAny(
     serviceName: "IndicatorEngine",
     minimumVersion: "1.0.0"
 ) { (engine: IndicatorEngineProtocol) in
     engine.calculateMA(symbol: "BTC", period: 20)
 }
 
 // 方式C：先发现再选择
 let providers = ServiceRegistry.shared.discover(serviceName: "IndicatorEngine")
 for provider in providers {
     print("Provider: \(provider.moduleName) v\(provider.version)")
 }
 
 // 4. 模块卸载时自动注销
 ServiceRegistry.shared.unregisterAll(moduleName: "IndicatorEngine")
 */
