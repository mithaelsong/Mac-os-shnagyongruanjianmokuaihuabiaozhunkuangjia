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
            logger.info("[\(module)] dependency missing: \(dependency), marking for retry")
            return scheduleRetry(module: module)
            
        case .circularDependency(let path):
            // Abort: reject loading, report error
            let pathStr = path.joined(separator: " -> ")
            logger.error("Circular dependency detected: \(pathStr), aborting")
            return .abort
            
        case .versionIncompatible(let module, let required, let actual):
            // Downgrade: log and attempt downgrade
            logger.warning("[\(module)] version incompatible: required \(required), actual \(actual), attempting downgrade")
            return .downgrade
            
        case .configurationError(let module, let reason):
            // Use default config: log and continue
            logger.warning("[\(module)] configuration error: \(reason), using default config")
            return .useDefaultConfig
            
        case .loadTimeout(let module, let duration):
            // Retry: log, retry up to 3 times, then give up
            logger.error("[\(module)] load timeout: \(String(format: "%.2f", duration))s, retrying")
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
            logger.error("Module \(module) exceeded max retries (\(maxRetries)), giving up")
            retryRecords.removeValue(forKey: module)
            return .giveUp
        }
        
        // Exponential backoff: delay = baseDelay * 2^(attempt-1)
        let delay = baseDelay * pow(2.0, Double(record.count - 1))
        record.nextRetryAt = Date().addingTimeInterval(delay)
        retryRecords[module] = record
        
        logger.info("Module \(module) will retry in \(String(format: "%.2f", delay))s (attempt \(record.count)/\(maxRetries))")
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
        logger.info("Module \(module) retry record reset")
    }
    
    /// Reset all retry records
    public func resetAll() {
        os_unfair_lock_lock(&lock)
        retryRecords.removeAll()
        os_unfair_lock_unlock(&lock)
        logger.info("All module retry records reset")
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
    
    // MARK: - Test 1: Dependency Missing -> Mark for Retry
    public static func testDependencyMissingRetry() {
        print("\n🧪 Test 1: Dependency Missing -> Mark for Retry")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.dependencyMissing(
            module: "TradeModule",
            dependency: "KLineModule"
        )
        let result = handler.handle(failure)
        
        guard case .retry(let delay) = result else {
            fatalError("❌ Test 1 failed: expected retry, got \(result)")
        }
        guard delay == 1.0 else {
            fatalError("❌ Test 1 failed: first retry delay should be 1.0s, got \(delay)")
        }
        guard handler.retryCount(for: "TradeModule") == 1 else {
            fatalError("❌ Test 1 failed: retry count should be 1")
        }
        
        print("✅ Test 1 passed: Dependency Missing -> Mark for Retry, delay \(delay)s")
    }
    
    // MARK: - Test 2: Circular Dependency -> Abort Loading
    public static func testCircularDependencyAbort() {
        print("\n🧪 Test 2: Circular Dependency -> Abort")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.circularDependency(
            path: ["ModuleA", "ModuleB", "ModuleC", "ModuleA"]
        )
        let result = handler.handle(failure)
        
        guard case .abort = result else {
            fatalError("❌ Test 2 failed: expected abort, got \(result)")
        }
        
        print("✅ Test 2 passed: Circular Dependency -> Abort Loading")
    }
    
    // MARK: - Test 3: Version Incompatible -> Attempt Downgrade
    public static func testVersionIncompatibleDowngrade() {
        print("\n🧪 Test 3: Version Incompatible -> Downgrade")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.versionIncompatible(
            module: "IndicatorModule",
            required: "2.0.0",
            actual: "1.5.0"
        )
        let result = handler.handle(failure)
        
        guard case .downgrade = result else {
            fatalError("❌ Test 3 failed: expected downgrade, got \(result)")
        }
        
        print("✅ Test 3 passed: Version Incompatible -> Attempt Downgrade")
    }
    
    // MARK: - Test 4: Config Error -> Use Default Config
    public static func testConfigurationErrorUseDefault() {
        print("\n🧪 Test 4: Config Error -> Use Default")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        let failure = ModuleFailureType.configurationError(
            module: "ConfigModule",
            reason: "missing required field 'apiEndpoint'"
        )
        let result = handler.handle(failure)
        
        guard case .useDefaultConfig = result else {
            fatalError("❌ Test 4 failed: expected useDefaultConfig, got \(result)")
        }
        
        print("✅ Test 4 passed: Config Error -> Use Default Config")
    }
    
    // MARK: - Test 5: Load Timeout -> Retry 3 Times Then Give Up
    public static func testLoadTimeoutRetryThenGiveUp() {
        print("\n🧪 Test 5: Load Timeout -> Retry 3 Times Then Give Up")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "SlowModule"
        
        // 1st timeout
        let r1 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r1 else { fatalError("❌ Test 5 failed: 1st expected retry") }
        
        // 2nd timeout
        let r2 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r2 else { fatalError("❌ Test 5 failed: 2nd expected retry") }
        
        // 3rd timeout
        let r3 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .retry = r3 else { fatalError("❌ Test 5 failed: 3rd expected retry") }
        
        // 4th timeout -> give up
        let r4 = handler.handle(.loadTimeout(module: moduleName, duration: 5.0))
        guard case .giveUp = r4 else { fatalError("❌ Test 5 failed: 4th expected giveUp, got \(r4)") }
        
        guard !handler.canRetry(module: moduleName) else {
            fatalError("❌ Test 5 failed: should not retryable after 3 attempts")
        }
        
        print("✅ Test 5 passed: Load Timeout -> Retry 3 Times Then Give Up")
    }
    
    // MARK: - Test 6: Exponential Backoff Calculation
    public static func testExponentialBackoff() {
        print("\n🧪 Test 6: Exponential Backoff Calculation")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        let moduleName = "BackoffModule"
        
        // 1st: 1.0 * 2^0 = 1.0
        let r1 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d1) = r1, d1 == 1.0 else {
            fatalError("❌ Test 6 failed: 1st retry delay should be 1.0s, got \(d1)")
        }
        
        // 2nd: 1.0 * 2^1 = 2.0
        let r2 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d2) = r2, d2 == 2.0 else {
            fatalError("❌ Test 6 failed: 2nd retry delay should be 2.0s, got \(d2)")
        }
        
        // 3rd: 1.0 * 2^2 = 4.0
        let r3 = handler.handle(.dependencyMissing(module: moduleName, dependency: "Dep1"))
        guard case .retry(let d3) = r3, d3 == 4.0 else {
            fatalError("❌ Test 6 failed: 3rd delay should be 4.0s, got \(d3)")
        }
        
        print("✅ Test 6 passed: Exponential backoff delay 1.0s -> 2.0s -> 4.0s")
    }
    
    // MARK: - Test 7: Reset and State Query
    public static func testResetAndStateQuery() {
        print("\n🧪 Test 7: Reset and State Query")
        
        let handler = ModuleFailureHandler()
        handler.resetAll()
        
        // Create two pending retry modules
        _ = handler.handle(.dependencyMissing(module: "ModA", dependency: "DepA"))
        _ = handler.handle(.dependencyMissing(module: "ModB", dependency: "DepB"))
        
        guard handler.pendingRetryCount == 2 else {
            fatalError("❌ Test 7 failed: pending retry count should be 2")
        }
        
        let pending = handler.pendingRetryModules.sorted()
        guard pending == ["ModA", "ModB"] else {
            fatalError("❌ Test 7 failed: pending retry list wrong: \(pending)")
        }
        
        // Reset single
        handler.reset(module: "ModA")
        guard handler.pendingRetryCount == 1 else {
            fatalError("❌ Test 7 failed: after reset, pending retry count should be 1")
        }
        
        // Reset all
        handler.resetAll()
        guard handler.pendingRetryCount == 0 else {
            fatalError("❌ Test 7 failed: after reset all, pending retry count should be 0")
        }
        
        print("✅ Test 7 passed: State query and reset correct")
    }
    
    // MARK: - Test 8: Thread Safety (100 concurrent retries)
    public static func testThreadSafety() {
        print("\n🧪 Test 8: Thread Safety (100 concurrent retries)")
        
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
            fatalError("❌ Test 8 failed: after concurrent writes, pending retry count should be \(moduleCount), got \(handler.pendingRetryCount)")
        }
        
        print("✅ Test 8 passed: \(moduleCount) concurrent failure handling has no data race")
    }
}