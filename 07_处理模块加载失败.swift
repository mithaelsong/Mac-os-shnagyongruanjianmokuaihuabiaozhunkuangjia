import Foundation
import os

// MARK: - 模块失败类型
/// 模块加载过程中可能发生的5种失败类型
public enum ModuleFailureType {
    /// 依赖缺失：目标模块缺少必要的依赖
    case dependencyMissing(module: String, dependency: String)
    /// 循环依赖：模块之间存在循环依赖链
    case circularDependency(path: [String])
    /// 版本不兼容：模块版本与系统要求不匹配
    case versionIncompatible(module: String, required: String, actual: String)
    /// 配置错误：模块配置文件解析失败或配置项非法
    case configurationError(module: String, reason: String)
    /// 加载超时：模块加载超过最大允许时间
    case loadTimeout(module: String, duration: TimeInterval)
}

// MARK: - 模块失败处理结果
/// 失败处理后的决策结果
public enum ModuleFailureResolution {
    /// 延迟一定时间后重试（指数退避）
    case retry(delay: TimeInterval)
    /// 尝试降级到兼容版本
    case downgrade
    /// 使用默认配置继续加载
    case useDefaultConfig
    /// 拒绝加载该模块，不中断系统
    case abort
    /// 超过最大重试次数，彻底放弃
    case giveUp
}

// MARK: - 重试记录
/// 单个模块的重试状态记录
private struct RetryRecord {
    var count: Int = 0
    var nextRetryAt: Date?
}

// MARK: - ModuleFailureHandler
/// 模块加载失败处理器 (功能7)
/// 处理模块加载失败的5种情况，提供对应的恢复策略和指数退避重试机制
/// 所有操作线程安全，使用 os_unfair_lock 保证高并发性能
public final class ModuleFailureHandler {
    private let logger = ModuleLogger(category: "ModuleFailureHandler")
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0
    
    private var retryRecords: [String: RetryRecord] = [:]
    private var lock = os_unfair_lock()
    
    // MARK: - 处理失败
    /// 根据失败类型执行对应的处理策略
    /// - Parameter failure: 具体的失败类型
    /// - Returns: 处理决策结果
    public func handle(_ failure: ModuleFailureType) -> ModuleFailureResolution {
        switch failure {
        case .dependencyMissing(let module, let dependency):
            // 策略：记录日志，标记待重试
            logger.warning("[\(module)] 依赖缺失: \(dependency)，将标记为待重试")
            return scheduleRetry(module: module)
            
        case .circularDependency(let path):
            // 策略：拒绝加载，报告错误
            let pathStr = path.joined(separator: " -> ")
            logger.error("检测到循环依赖: \(pathStr)，拒绝加载涉及模块")
            return .abort
            
        case .versionIncompatible(let module, let required, let actual):
            // 策略：记录日志，尝试降级
            logger.warning("[\(module)] 版本不兼容: 需要 \(required)，实际 \(actual)，尝试降级")
            return .downgrade
            
        case .configurationError(let module, let reason):
            // 策略：记录日志，使用默认配置
            logger.warning("[\(module)] 配置错误: \(reason)，将使用默认配置继续加载")
            return .useDefaultConfig
            
        case .loadTimeout(let module, let duration):
            // 策略：记录日志，重试3次后放弃
            logger.error("[\(module)] 加载超时: \(String(format: "%.2f", duration))s，尝试重试")
            return scheduleRetry(module: module)
        }
    }
    
    // MARK: - 重试管理
    /// 计算并记录重试计划（指数退避）
    /// - Parameter module: 模块名称
    /// - Returns: 重试决策（retry / giveUp）
    private func scheduleRetry(module: String) -> ModuleFailureResolution {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        var record = retryRecords[module] ?? RetryRecord()
        record.count += 1
        
        if record.count > maxRetries {
            logger.error("模块 \(module) 超过最大重试次数 (\(maxRetries))，彻底放弃加载")
            retryRecords.removeValue(forKey: module)
            return .giveUp
        }
        
        // 指数退避：delay = baseDelay * 2^(attempt-1)
        let delay = baseDelay * pow(2.0, Double(record.count - 1))
        record.nextRetryAt = Date().addingTimeInterval(delay)
        retryRecords[module] = record
        
        logger.info("模块 \(module) 将在 \(String(format: "%.2f", delay))s 后重试 (第 \(record.count)/\(maxRetries) 次)")
        return .retry(delay: delay)
    }
    
    /// 检查指定模块是否还可以重试
    /// - Parameter module: 模块名称
    /// - Returns: 是否未超过最大重试次数
    public func canRetry(module: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let record = retryRecords[module] else { return true }
        return record.count < maxRetries
    }
    
    /// 获取模块的当前重试次数
    /// - Parameter module: 模块名称
    /// - Returns: 已重试次数，未记录返回0
    public func retryCount(for module: String) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords[module]?.count ?? 0
    }
    
    /// 获取模块的下次重试时间
    /// - Parameter module: 模块名称
    /// - Returns: 下次重试时间点，nil 表示无重试计划
    public func nextRetryTime(for module: String) -> Date? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords[module]?.nextRetryAt
    }
    
    /// 重置指定模块的重试记录（模块加载成功后调用）
    /// - Parameter module: 模块名称
    public func reset(module: String) {
        os_unfair_lock_lock(&lock)
        retryRecords.removeValue(forKey: module)
        os_unfair_lock_unlock(&lock)
        logger.info("模块 \(module) 的重试记录已重置")
    }
    
    /// 重置所有模块的重试记录
    public func resetAll() {
        os_unfair_lock_lock(&lock)
        retryRecords.removeAll()
        os_unfair_lock_unlock(&lock)
        logger.info("所有模块的重试记录已重置")
    }
    
    // MARK: - 查询状态
    /// 获取所有处于待重试状态的模块名称
    public var pendingRetryModules: [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(retryRecords.keys)
    }
    
    /// 获取待重试模块数量
    public var pendingRetryCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords.count
    }
}

// MARK: - 测试代码
/// ModuleFailureHandler 功能验证测试
/// 运行方式：在单元测试或 Playground 中调用 `ModuleFailureHandlerTests.runAllTests()`
public enum ModuleFailureHandlerTests {
    
    /// 运行所有测试
    public static func runAllTests() {
        print("=== ModuleFailureHandler Tests ===")
        
        testDependencyMissingRetry()
        testCircularDependencyAbort()
        testVersionIncompatibleDowngrade()
        testConfigurationErrorUseDefault()
        testLoadTimeoutRetryThenGiveUp()
        testExponentialBackoff()
        testResetAndStateQuery()
        testThreadSafety()
        
        print("\n=== All ModuleFailureHandler Tests Passed ✅ ===")
    }
    
    // MARK: - 测试1: 依赖缺失 -> 标记待重试
    public static func testDependencyMissingRetry() {
        print("\n🧪 Test 1: 依赖缺失处理（标记待重试）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.dependencyMissing(
            module: "TradeModule",
            dependency: "KLineModule"
        )
        let result = handler.handle(failure)
        
        guard case .retry(let delay) = result else {
            fatalError("❌ Test 1 失败: 期望返回 retry，实际 \(result)")
        }
        guard delay == 1.0 else {
            fatalError("❌ Test 1 失败: 首次重试延迟应为 1.0s，实际 \(delay)")
        }
        guard handler.retryCount(for: "TradeModule") == 1 else {
            fatalError("❌ Test 1 失败: 重试计数应为 1")
        }
        
        print("✅ Test 1 通过: 依赖缺失 -> 标记待重试，延迟 \(delay)s")
    }
    
    // MARK: - 测试2: 循环依赖 -> 拒绝加载
    public static func testCircularDependencyAbort() {
        print("\n🧪 Test 2: 循环依赖处理（拒绝加载）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.circularDependency(
            path: ["ModuleA", "ModuleB", "ModuleC", "ModuleA"]
        )
        let result = handler.handle(failure)
        
        guard case .abort = result else {
            fatalError("❌ Test 2 失败: 期望返回 abort，实际 \(result)")
        }
        
        print("✅ Test 2 通过: 循环依赖 -> 拒绝加载")
    }
    
    // MARK: - 测试3: 版本不兼容 -> 尝试降级
    public static func testVersionIncompatibleDowngrade() {
        print("\n🧪 Test 3: 版本不兼容处理（尝试降级）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.versionIncompatible(
            module: "IndicatorModule",
            required: "2.0.0",
            actual: "1.5.0"
        )
        let result = handler.handle(failure)
        
        guard case .downgrade = result else {
            fatalError("❌ Test 3 失败: 期望返回 downgrade，实际 \(result)")
        }
        
        print("✅ Test 3 通过: 版本不兼容 -> 尝试降级")
    }
    
    // MARK: - 测试4: 配置错误 -> 使用默认配置
    public static func testConfigurationErrorUseDefault() {
        print("\n🧪 Test 4: 配置错误处理（使用默认配置）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.configurationError(
            module: "ConfigModule",
            reason: "缺少必填字段 'apiEndpoint'"
        )
        let result = handler.handle(failure)
        
        guard case .useDefaultConfig = result else {
            fatalError("❌ Test 4 失败: 期望返回 useDefaultConfig，实际 \(result)")
        }
        
        print("✅ Test 4 通过: 配置错误 -> 使用默认配置")
    }
    
    // MARK: - 测试5: 加载超时 -> 重试3次后放弃
    public static func testLoadTimeoutRetryThenGiveUp() {
        print("\n🧪 Test 5: 加载超时处理（重试3次后放弃）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "SlowModule"
        
        // 第1次超时
        let r1 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r1 else { fatalError("❌ Test 5 失败: 第1次应返回 retry") }
        
        // 第2次超时
        let r2 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r2 else { fatalError("❌ Test 5 失败: 第2次应返回 retry") }
        
        // 第3次超时
        let r3 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r3 else { fatalError("❌ Test 5 失败: 第3次应返回 retry") }
        
        // 第4次超时 -> 放弃
        let r4 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .giveUp = r4 else { fatalError("❌ Test 5 失败: 第4次应返回 giveUp，实际 \(r4)") }
        
        guard !handler.canRetry(module: moduleName) else {
            fatalError("❌ Test 5 失败: 超过3次后应不可重试")
        }
        
        print("✅ Test 5 通过: 超时重试3次后放弃")
    }
    
    // MARK: - 测试6: 指数退避延迟计算
    public static func testExponentialBackoff() {
        print("\n🧪 Test 6: 指数退避延迟计算")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "BackoffModule"
        
        // 第1次: 1.0 * 2^0 = 1.0
        let r1 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d1) = r1, d1 == 1.0 else {
            fatalError("❌ Test 6 失败: 第1次延迟应为 1.0s")
        }
        
        // 第2次: 1.0 * 2^1 = 2.0
        let r2 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d2) = r2, d2 == 2.0 else {
            fatalError("❌ Test 6 失败: 第2次延迟应为 2.0s，实际 \(d2)")
        }
        
        // 第3次: 1.0 * 2^2 = 4.0
        let r3 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d3) = r3, d3 == 4.0 else {
            fatalError("❌ Test 6 失败: 第3次延迟应为 4.0s，实际 \(d3)")
        }
        
        print("✅ Test 6 通过: 指数退避延迟 1.0s -> 2.0s -> 4.0s")
    }
    
    // MARK: - 测试7: 重置和状态查询
    public static func testResetAndStateQuery() {
        print("\n🧪 Test 7: 重置和状态查询")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        // 制造两个待重试模块
        _ = handler.handle(.dependencyMissing(module: "ModA", dependency: "DepA"))
        _ = handler.handle(.dependencyMissing(module: "ModB", dependency: "DepB"))
        
        guard handler.pendingRetryCount == 2 else {
            fatalError("❌ Test 7 失败: 待重试数量应为 2")
        }
        
        let pending = handler.pendingRetryModules.sorted()
        guard pending == ["ModA", "ModB"] else {
            fatalError("❌ Test 7 失败: 待重试模块列表错误: \(pending)")
        }
        
        // 重置单个
        handler.reset(module: "ModA")
        guard handler.pendingRetryCount == 1 else {
            fatalError("❌ Test 7 失败: 重置后待重试数量应为 1")
        }
        
        // 重置全部
        handler.resetAll()
        guard handler.pendingRetryCount == 0 else {
            fatalError("❌ Test 7 失败: 重置全部后待重试数量应为 0")
        }
        
        print("✅ Test 7 通过: 状态查询和重置正确")
    }
    
    // MARK: - 测试8: 线程安全（100并发重试记录）
    public static func testThreadSafety() {
        print("\n🧪 Test 8: 线程安全（并发处理）")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let group = DispatchGroup()
        let moduleCount = 100
        
        for i in 0..<moduleCount {
            group.enter()
            DispatchQueue.global().async {
                let failure = ModuleFailureType.dependencyMissing(
                    module: "ConcurrentModule\(i)",
                    dependency: "Dep\(i)"
                )
                _ = handler.handle(failure)
                group.leave()
            }
        }
        
        group.wait()
        
        guard handler.pendingRetryCount == moduleCount else {
            fatalError("❌ Test 8 失败: 并发写入后待重试数量应为 \(moduleCount)，实际 \(handler.pendingRetryCount)")
        }
        
        print("✅ Test 8 通过: \(moduleCount) 并发失败处理无数据竞争")
    }
}