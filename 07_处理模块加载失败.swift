// 功能7: 处理模块加载失败
// 对应: 5种加载失败类型的处理策略（重试/降级/默认配置/中止/放弃），指数退避
// 优先级: P1

import Foundation
import os

// MARK: - Module Failure Types
/// 5 types of failures that may occur during module loading
public enum ModuleFailureType {
    /// Dependency missing: target module lacks a required dependency
    case dependencyMissing(module: String, dependency: String)
    /// Circular dependency: modules form a dependency cycle
    case circularDependency(path: [String])
    /// Version incompatible: module version does not meet requirements
    case versionIncompatible(module: String, required: String, actual: String)
    /// Configuration error: failed to parse or validate module config
    case configurationError(module: String, reason: String)
    /// Load timeout: module loading exceeded maximum allowed time
    case loadTimeout(module: String, duration: TimeInterval)
}

// MARK: - Failure Resolution
/// Resolution decision after handling a failure
public enum ModuleFailureResolution {
    /// Retry after a delay (exponential backoff)
    case retry(delay: TimeInterval)
    /// Attempt to downgrade to a compatible version
    case downgrade
    /// Use default configuration and continue loading
    case useDefaultConfig
    /// Reject loading this module without crashing the system
    case abort
    /// Exceeded max retries, give up completely
    case giveUp
}

// MARK: - Retry Record
/// State record for a single module retry
private struct RetryRecord {
    var count: Int = 0
    var nextRetryAt: Date?
}

// MARK: - ModuleFailureHandler
/// Module failure handler (Function 7)
/// Handles 5 types of module loading failures with recovery strategies and exponential backoff retry
/// All operations thread-safe using os_unfair_lock
public final class ModuleFailureHandler {
    private let logger = ModuleLogger(category: "ModuleFailureHandler")
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0
    
    private var retryRecords: [String: RetryRecord] = [:]
    private var lock = os_unfair_lock()
    
    // MARK: - Handle Failure
    /// Execute the corresponding handling strategy for each failure type
    /// - Parameter failure: The specific failure type
    /// - Returns: Resolution decision for the failure
    public func handle(_ failure: ModuleFailureType) -> ModuleFailureResolution {
        switch failure {
        case .dependencyMissing(let module, let dependency):
            // Log and mark for retry
            logger.info("模块 [\(module)] 依赖缺失: \(dependency)，标记重试")
            return scheduleRetry(module: module)
            
        case .circularDependency(let path):
            // Abort: reject loading, report error
            let pathStr = path.joined(separator: " -> ")
            logger.error("检测到循环依赖: \(pathStr)，中止加载")
            return .abort
            
        case .versionIncompatible(let module, let required, let actual):
            // Downgrade: log and attempt downgrade
            logger.warning("模块 [\(module)] 版本不兼容: 需要 \(required)，实际 \(actual)，尝试降级")
            return .downgrade
            
        case .configurationError(let module, let reason):
            // Use default config: log and continue
            logger.warning("模块 [\(module)] 配置错误: \(reason)，使用默认配置")
            return .useDefaultConfig
            
        case .loadTimeout(let module, let duration):
            // Retry: log, retry up to 3 times, then give up
            logger.error("模块 [\(module)] 加载超时: \(String(format: "%.2f", duration))s，重试")
            return scheduleRetry(module: module)
        }
    }
    
    // MARK: - Retry Management
    /// Calculate and record retry plan (exponential backoff)
    /// - Parameter module: Module name
    /// - Returns: Retry decision (retry / giveUp)
    private func scheduleRetry(module: String) -> ModuleFailureResolution {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        var record = retryRecords[module] ?? RetryRecord()
        record.count += 1
        
        if record.count > maxRetries {
            logger.error("模块 \(module) 超过最大重试次数 (\(maxRetries))，放弃")
            retryRecords.removeValue(forKey: module)
            return .giveUp
        }
        
        // Exponential backoff: delay = baseDelay * 2^(attempt-1)
        let delay = baseDelay * pow(2.0, Double(record.count - 1))
        record.nextRetryAt = Date().addingTimeInterval(delay)
        retryRecords[module] = record
        
        logger.info("模块 \(module) 将在 \(String(format: "%.2f", delay))s 后重试 (第\(record.count)/\(maxRetries)次)")
        return .retry(delay: delay)
    }
    
    /// Check if a module can still be retried
    /// - Parameter module: Module name
    /// - Returns: Whether it has not exceeded max retries
    public func canRetry(module: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let record = retryRecords[module] else { return true }
        return record.count < maxRetries
    }
    
    /// Get current retry count for a module
    /// - Parameter module: Module name
    /// - Returns: Retry count, 0 if not recorded
    public func retryCount(for module: String) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords[module]?.count ?? 0
    }
    
    /// Get next retry time for a module
    /// - Parameter module: Module name
    /// - Returns: Next retry time, nil if no retry planned
    public func nextRetryTime(for module: String) -> Date? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords[module]?.nextRetryAt
    }
    
    /// Reset retry record for a module (call after successful load)
    /// - Parameter module: Module name
    public func reset(module: String) {
        os_unfair_lock_lock(&lock)
        retryRecords.removeValue(forKey: module)
        os_unfair_lock_unlock(&lock)
        logger.info("模块 \(module) 重试记录已重置")
    }
    
    /// Reset all retry records
    public func resetAll() {
        os_unfair_lock_lock(&lock)
        retryRecords.removeAll()
        os_unfair_lock_unlock(&lock)
        logger.info("全部模块重试记录已重置")
    }
    
    // MARK: - Query Status
    /// Get all modules pending retry
    public var pendingRetryModules: [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(retryRecords.keys)
    }
    
    /// Get count of modules pending retry
    public var pendingRetryCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return retryRecords.count
    }
}

// MARK: - Tests
/// Verify ModuleFailureHandler functionality
/// Run: call `ModuleFailureHandlerTests.runAllTests()` in unit tests or Playground
public enum ModuleFailureHandlerTests {
    
    /// Run all tests
    public static func runAllTests() {
        print("=== 功能7测试 ===")
        
        testDependencyMissingRetry()
        testCircularDependencyAbort()
        testVersionIncompatibleDowngrade()
        testConfigurationErrorUseDefault()
        testLoadTimeoutRetryThenGiveUp()
        testExponentialBackoff()
        testResetAndStateQuery()
        testThreadSafety()
        
        print("\n=== 全部功能7测试通过 ✅ ===")
    }
    
    // MARK: - Test 1: Dependency Missing -> Mark for Retry
    public static func testDependencyMissingRetry() {
        print("\n🧪 测试1: 依赖缺失 -> 标记重试")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.dependencyMissing(
            module: "TradeModule",
            dependency: "KLineModule"
        )
        let result = handler.handle(failure)
        
        guard case .retry(let delay) = result else {
            fatalError("❌ 测试1失败: 期望重试，实际 \(result)")
        }
        guard delay == 1.0 else {
            fatalError("❌ 测试1失败: 首次重试延迟应为1.0秒，实际 \(delay)")
        }
        guard handler.retryCount(for: "TradeModule") == 1 else {
            fatalError("❌ 测试1失败: 重试次数应为1")
        }
        
        print("✅ 测试1通过: 依赖缺失 -> 标记重试，延迟 \(delay)s")
    }
    
    // MARK: - Test 2: Circular Dependency -> Abort Loading
    public static func testCircularDependencyAbort() {
        print("\n🧪 测试2: 循环依赖 -> 中止")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.circularDependency(
            path: ["ModuleA", "ModuleB", "ModuleC", "ModuleA"]
        )
        let result = handler.handle(failure)
        
        guard case .abort = result else {
            fatalError("❌ 测试2失败: 期望中止，实际 \(result)")
        }
        
        print("✅ 测试2通过: 循环依赖 -> 中止加载")
    }
    
    // MARK: - Test 3: Version Incompatible -> Attempt Downgrade
    public static func testVersionIncompatibleDowngrade() {
        print("\n🧪 测试3: 版本不兼容 -> 降级")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.versionIncompatible(
            module: "IndicatorModule",
            required: "2.0.0",
            actual: "1.5.0"
        )
        let result = handler.handle(failure)
        
        guard case .downgrade = result else {
            fatalError("❌ 测试3失败: 期望降级，实际 \(result)")
        }
        
        print("✅ 测试3通过: 版本不兼容 -> 尝试降级")
    }
    
    // MARK: - Test 4: Config Error -> Use Default Config
    public static func testConfigurationErrorUseDefault() {
        print("\n🧪 测试4: 配置错误 -> 使用默认配置")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.configurationError(
            module: "ConfigModule",
            reason: "missing required field 'apiEndpoint'"
        )
        let result = handler.handle(failure)
        
        guard case .useDefaultConfig = result else {
            fatalError("❌ 测试4失败: 期望useDefaultConfig，实际 \(result)")
        }
        
        print("✅ 测试4通过: 配置错误 -> 使用默认配置")
    }
    
    // MARK: - Test 5: Load Timeout -> Retry 3 Times Then Give Up
    public static func testLoadTimeoutRetryThenGiveUp() {
        print("\n🧪 测试5: 加载超时 -> 重试3次后放弃")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "SlowModule"
        
        // 1st timeout
        let r1 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r1 else { fatalError("❌ 测试5失败: 第1次期望重试") }
        
        // 2nd timeout
        let r2 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r2 else { fatalError("❌ 测试5失败: 第2次期望重试") }
        
        // 3rd timeout
        let r3 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r3 else { fatalError("❌ 测试5失败: 第3次期望重试") }
        
        // 4th timeout -> give up
        let r4 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .giveUp = r4 else { fatalError("❌ 测试5失败: 第4次期望giveUp，实际 \(r4)") }
        
        guard !handler.canRetry(module: moduleName) else {
            fatalError("❌ 测试5失败: 3次尝试后不应可重试")
        }
        
        print("✅ 测试5通过: 加载超时 -> 重试3次后放弃")
    }
    
    // MARK: - Test 6: Exponential Backoff Calculation
    public static func testExponentialBackoff() {
        print("\n🧪 测试6: 指数退避计算")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "BackoffModule"
        
        // 1st: 1.0 * 2^0 = 1.0
        let r1 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d1) = r1, d1 == 1.0 else {
            fatalError("❌ 测试6失败: 第1次重试延迟应为1.0秒，实际 \(d1)")
        }
        
        // 2nd: 1.0 * 2^1 = 2.0
        let r2 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d2) = r2, d2 == 2.0 else {
            fatalError("❌ 测试6失败: 第2次重试延迟应为2.0秒，实际 \(d2)")
        }
        
        // 3rd: 1.0 * 2^2 = 4.0
        let r3 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d3) = r3, d3 == 4.0 else {
            fatalError("❌ 测试6失败: 第3次延迟应为4.0秒，实际 \(d3)")
        }
        
        print("✅ 测试6通过: 指数退避延迟1.0秒 -> 2.0秒 -> 4.0秒")
    }
    
    // MARK: - Test 7: Reset and State Query
    public static func testResetAndStateQuery() {
        print("\n🧪 测试7: 重置与状态查询")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        // Create two pending retry modules
        _ = handler.handle(.dependencyMissing(module: "ModA", dependency: "DepA"))
        _ = handler.handle(.dependencyMissing(module: "ModB", dependency: "DepB"))
        
        guard handler.pendingRetryCount == 2 else {
            fatalError("❌ 测试7失败: 待重试计数应为2")
        }
        
        let pending = handler.pendingRetryModules.sorted()
        guard pending == ["ModA", "ModB"] else {
            fatalError("❌ 测试7失败: 待重试列表错误: \(pending)")
        }
        
        // Reset single
        handler.reset(module: "ModA")
        guard handler.pendingRetryCount == 1 else {
            fatalError("❌ 测试7失败: 重置后待重试计数应为1")
        }
        
        // Reset all
        handler.resetAll()
        guard handler.pendingRetryCount == 0 else {
            fatalError("❌ 测试7失败: 全部重置后待重试计数应为0")
        }
        
        print("✅ 测试7通过: 状态查询和重置正确")
    }
    
    // MARK: - Test 8: Thread Safety (100 concurrent retries)
    public static func testThreadSafety() {
        print("\n🧪 测试8: 线程安全(100并发重试)")
        
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
            fatalError("❌ 测试8失败: 并发写入后待重试计数应为 \(moduleCount), got \(handler.pendingRetryCount)")
        }
        
        print("✅ 测试8通过: \(moduleCount) concurrent failure handling has no data race")
    }
}