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
    
    /// 内部初始化（用于测试创建独立实例）
    internal init() {}
    
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
        
        logger.info("注册服务 '\(serviceName)' v\(version) 来自模块 '\(moduleName)' (协议: \(descriptor.protocolName))")
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
            logger.warning("服务 '\(serviceName)' 在模块 '\(moduleName)' 中未找到")
            return nil
        }
        
        guard let typed = entry.instance as? T else {
            logger.error("服务 '\(serviceName)' 来自 '\(moduleName)' 类型不匹配: 期望 \(String(describing: T.self)), 实际 \(entry.descriptor.protocolName)")
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
            logger.warning("服务 '\(serviceName)' 未在注册表中找到")
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
                logger.warning("服务 '\(serviceName)' 已找到但无版本 >= \(minimumVersion!)")
            } else {
                logger.warning("服务 '\(serviceName)' 已找到但无有效实例")
            }
            return nil
        }
        
        guard let typed = entry.instance as? T else {
            logger.error("服务 '\(serviceName)' 来自 '\(entry.descriptor.moduleName)' 类型不匹配: 期望 \(String(describing: T.self)), 实际 \(entry.descriptor.protocolName)")
            return nil
        }
        
        if let minVersion = minimumVersion {
            logger.info("已解析服务 '\(serviceName)' v\(entry.descriptor.version) 来自 '\(entry.descriptor.moduleName)' (>= \(minVersion))")
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
            logger.info("已注销服务 '\(serviceName)' 来自模块 '\(moduleName)'")
        } else {
            os_unfair_lock_unlock(&storage.lock)
            logger.warning("注销失败: 服务 '\(serviceName)' 在模块 '\(moduleName)' 中未找到")
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
        logger.info("已注销模块 '\(moduleName)' 的所有服务 (\(keysToRemove.count) 个服务)")
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
    
    /// 内部初始化（用于测试创建独立实例）
    internal init() {}
    
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
            logger.warning("Invoke失败: 无法解析 \(moduleName).\(serviceName) 为 \(String(describing: T.self))")
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
            logger.warning("InvokeAny失败: 无法解析服务 '\(serviceName)' (最低版本: \(minimumVersion ?? "无"))")
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
        print("=== 服务注册表测试 ===")
        testRegisterAndResolve()
        testDiscover()
        testVersionMatching()
        testUnregister()
        testInvoke()
        testInvokeAny()
        testAsyncInvoke()
        testThreadSafety()
        print("\n=== 全部服务注册表测试通过 ✅ ===")
    }
    
    // MARK: - 测试1: 注册与精确解析
    private static func testRegisterAndResolve() {
        print("\n🧪 测试1: 注册与解析")
        
        let registry = ServiceRegistry()
        let ds = MockDataSource()
        registry.register(ds, serviceName: "DataSource", moduleName: "MarketModule", version: "1.0.0", protocolType: DataSourceService.self)
        
        // 精确解析
        guard let resolved: DataSourceService = registry.resolve(moduleName: "MarketModule", serviceName: "DataSource", type: DataSourceService.self) else {
            fatalError("❌ 测试1失败: resolve返回nil")
        }
        guard resolved.fetchData(symbol: "BTC") == "Data for BTC from MockDataSource" else {
            fatalError("❌ 测试1失败: 数据不正确")
        }
        guard resolved.sourceName == "MockDataSource" else {
            fatalError("❌ 测试1失败: sourceName不正确")
        }
        
        // 解析不存在的模块
        let notFound = registry.resolve(moduleName: "FakeModule", serviceName: "DataSource", type: DataSourceService.self)
        guard notFound == nil else { fatalError("❌ 测试1b失败: 不存在的模块应返回nil") }
        
        // 解析不存在的类型（类型不匹配）
        let wrongType = registry.resolve(moduleName: "MarketModule", serviceName: "DataSource", type: IndicatorService.self)
        guard wrongType == nil else { fatalError("❌ 测试1c失败: 类型不匹配应返回nil") }
        
        print("✅ 测试1通过: 注册与解析正确")
    }
    
    // MARK: - 测试2: 服务发现
    private static func testDiscover() {
        print("\n🧪 测试2: 服务发现")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "MarketA", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "MarketB", version: "1.1.0", protocolType: DataSourceService.self)
        registry.register(MockIndicator(), serviceName: "Indicator", moduleName: "CalcModule", version: "2.0.0", protocolType: IndicatorService.self)
        
        // 发现 DataSource 的所有提供者
        let providers = registry.discover(serviceName: "DataSource")
        guard providers.count == 2 else { fatalError("❌ 测试2a失败: 期望2个提供者，实际\(providers.count)") }
        let names = providers.map(\.moduleName).sorted()
        guard names == ["MarketA", "MarketB"] else { fatalError("❌ 测试2a失败: 提供者名称不正确: \(names)") }
        
        // 发现不存在的服
        let empty = registry.discover(serviceName: "NonExistent")
        guard empty.isEmpty else { fatalError("❌ 测试2b失败: 应为空") }
        
        // 验证服务描述符内容
        let desc = providers.first { $0.moduleName == "MarketB" }!
        guard desc.version == "1.1.0" && desc.serviceName == "DataSource" else {
            fatalError("❌ 测试2c失败: 描述符内容不正确")
        }
        
        print("✅ 测试2通过: 服务发现正确")
    }
    
    // MARK: - 测试3: 版本匹配
    private static func testVersionMatching() {
        print("\n🧪 测试3: 版本匹配")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "OldModule", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSourceV2(), serviceName: "DataSource", moduleName: "NewModule", version: "2.0.0", protocolType: DataSourceService.self)
        
        // 不要求版本，应返回第一个注册的（OldModule，因为注册顺序优先）
        let any = registry.resolve(serviceName: "DataSource", type: DataSourceService.self)
        guard any != nil else { fatalError("❌ 测试3a失败: 任意解析返回nil") }
        
        // 要求 >= 1.5.0，应返回 NewModule（V2）
        let v2 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "1.5.0")
        guard let v2ds = v2 else { fatalError("❌ 测试3b失败: minVersion 1.5.0未找到V2") }
        guard v2ds.fetchData(symbol: "X") == "V2 Data for X" else { fatalError("❌ 测试3b失败: 获取到错误的实例") }
        guard v2ds.sourceName == "MockDataSourceV2" else { fatalError("❌ 测试3b失败: 不是V2实例") }
        
        // 要求 >= 3.0.0，应返回 nil（没有满足条件的）
        let v3 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "3.0.0")
        guard v3 == nil else { fatalError("❌ 测试3c失败: minVersion 3.0.0应返回nil") }
        
        // 边界：要求 >= 1.0.0，两个都满足，返回第一个（OldModule）
        let v1 = registry.resolve(serviceName: "DataSource", type: DataSourceService.self, minimumVersion: "1.0.0")
        guard v1 != nil else { fatalError("❌ 测试3d失败: v1应能找到") }
        
        print("✅ 测试3通过: 版本匹配正确")
    }
    
    // MARK: - 测试4: 注销服务
    private static func testUnregister() {
        print("\n🧪 测试4: 注销服务")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "ModA", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockIndicator(), serviceName: "Indicator", moduleName: "ModA", version: "1.0.0", protocolType: IndicatorService.self)
        
        // 注销单个服务
        registry.unregister(moduleName: "ModA", serviceName: "DataSource")
        guard registry.resolve(moduleName: "ModA", serviceName: "DataSource", type: DataSourceService.self) == nil else {
            fatalError("❌ 测试4a失败: DataSource应已注销")
        }
        guard registry.resolve(moduleName: "ModA", serviceName: "Indicator", type: IndicatorService.self) != nil else {
            fatalError("❌ 测试4b失败: Indicator应仍存在")
        }
        
        // 注销模块的所有服务
        registry.unregisterAll(moduleName: "ModA")
        guard registry.services(of: "ModA").isEmpty else {
            fatalError("❌ 测试4c失败: ModA的所有服务应已移除")
        }
        guard registry.discover(serviceName: "DataSource").isEmpty else {
            fatalError("❌ 测试4d失败: DataSource应从发现中移除")
        }
        
        // 注销不存在的服务（不应崩溃）
        registry.unregister(moduleName: "ModA", serviceName: "FakeService")
        
        print("✅ 测试4通过: 注销服务正确")
    }
    
    // MARK: - 测试5: 调用器（指定模块）
    private static func testInvoke() {
        print("\n🧪 测试5: 调用器（invoke）")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "Market", version: "1.0.0", protocolType: DataSourceService.self)
        
        let result = ServiceInvoker.shared.invoke(moduleName: "Market", serviceName: "DataSource") { (svc: DataSourceService) in
            svc.fetchData(symbol: "ETH")
        }
        guard result == "Data for ETH from MockDataSource" else {
            fatalError("❌ 测试5失败: 结果不正确: \(String(describing: result))")
        }
        
        // 调用不存在的服务
        let nilResult = ServiceInvoker.shared.invoke(moduleName: "Fake", serviceName: "Fake") { (svc: DataSourceService) in
            svc.fetchData(symbol: "X")
        }
        guard nilResult == nil else { fatalError("❌ 测试5b失败: 应为nil") }
        
        print("✅ 测试5通过: 调用器invoke正确")
    }
    
    // MARK: - 测试6: 调用器（任意模块）
    private static func testInvokeAny() {
        print("\n🧪 测试6: 调用器（invokeAny）")
        
        let registry = ServiceRegistry()
        registry.register(MockDataSource(), serviceName: "DataSource", moduleName: "Market", version: "1.0.0", protocolType: DataSourceService.self)
        registry.register(MockDataSourceV2(), serviceName: "DataSource", moduleName: "MarketV2", version: "2.0.0", protocolType: DataSourceService.self)
        
        // 任意调用，不指定版本
        let result1 = ServiceInvoker.shared.invokeAny(serviceName: "DataSource") { (svc: DataSourceService) in
            svc.fetchData(symbol: "BTC")
        }
        guard result1 != nil else { fatalError("❌ 测试6a失败: invokeAny返回nil") }
        
        // 指定最低版本 2.0.0，应返回 V2
        let result2 = ServiceInvoker.shared.invokeAny(serviceName: "DataSource", method: { (svc: DataSourceService) in
            svc.sourceName
        }, minimumVersion: "2.0.0")
        guard result2 == "MockDataSourceV2" else { fatalError("❌ 测试6b失败: 期望V2，实际\(String(describing: result2))") }
        
        print("✅ 测试6通过: 调用器invokeAny正确")
    }
    
    // MARK: - 测试7: 异步调用
    private static func testAsyncInvoke() {
        print("\n🧪 测试7: 异步调用")
        
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
        guard timeout == .success else { fatalError("❌ 测试7失败: 异步超时") }
        guard asyncResult == "Data for SOL from MockDataSource" else { fatalError("❌ 测试7失败: 结果不正确: \(String(describing: asyncResult))") }
        guard onMainThread else { fatalError("❌ 测试7失败: 回调不在主线程") }
        
        print("✅ 测试7通过: 异步调用正确")
    }
    
    // MARK: - 测试8: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 测试8: 线程安全 (100个并发注册)")
        
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
        guard providers.count == 100 else { fatalError("❌ 测试8a失败: 期望100个提供者，实际\(providers.count)") }
        
        // 验证总数
        guard registry.totalServiceCount == 100 else { fatalError("❌ 测试8b失败: 期望100个服务，实际\(registry.totalServiceCount)") }
        
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
        guard resolvedCount == 100 else { fatalError("❌ 测试8c失败: 期望100个解析成功，实际\(resolvedCount)") }
        
        print("✅ 测试8通过: 线程安全验证 (100并发注册+100并发解析)")
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
