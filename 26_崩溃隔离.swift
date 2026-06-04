import Foundation

// MARK: - 崩溃记录结构体
public struct CrashRecord: Equatable, CustomStringConvertible {
    public let moduleName: String
    public let timestamp: Date
    public let error: String
    public let recovered: Bool
    
    public var description: String {
        return "[CrashRecord] module: \(moduleName), time: \(timestamp), error: \(error), recovered: \(recovered)"
    }
}

// MARK: - 崩溃错误类型
public enum CrashError: Error, Equatable, CustomStringConvertible {
    case moduleCrashed(moduleName: String, underlyingError: String)
    case moduleDisabled(moduleName: String)
    case unknownError
    
    public var description: String {
        switch self {
        case .moduleCrashed(let name, let error):
            return "模块 [\(name)] 崩溃: \(error)"
        case .moduleDisabled(let name):
            return "模块 [\(name)] 已被禁用"
        case .unknownError:
            return "未知错误"
        }
    }
}

// MARK: - 崩溃隔离器
public final class CrashIsolator {
    
    public static let shared = CrashIsolator()
    
    public var thresholdCrashCount: Int = 3
    
    private var _crashRecords: [CrashRecord] = []
    private var _disabledModules: Set<String> = []
    private var _crashCounts: [String: Int] = [:]
    private var lock = os_unfair_lock()
    
    private init() {}
    
    public var crashRecords: [CrashRecord] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _crashRecords
    }
    
    public var disabledModules: [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(_disabledModules)
    }
    
    @discardableResult
    public func execute<T>(moduleName: String, closure: () throws -> T) -> Result<T, CrashError> {
        os_unfair_lock_lock(&lock)
        let isDisabled = _disabledModules.contains(moduleName)
        os_unfair_lock_unlock(&lock)
        
        if isDisabled {
            return .failure(.moduleDisabled(moduleName: moduleName))
        }
        
        do {
            let result = try closure()
            return .success(result)
        } catch {
            let record = CrashRecord(
                moduleName: moduleName,
                timestamp: Date(),
                error: String(describing: error),
                recovered: false
            )
            
            os_unfair_lock_lock(&lock)
            _crashRecords.append(record)
            _crashCounts[moduleName, default: 0] += 1
            let currentCount = _crashCounts[moduleName] ?? 0
            if currentCount >= thresholdCrashCount {
                _disabledModules.insert(moduleName)
            }
            os_unfair_lock_unlock(&lock)
            
            return .failure(.moduleCrashed(moduleName: moduleName, underlyingError: String(describing: error)))
        }
    }
    
    public func crashCount(for moduleName: String) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _crashCounts[moduleName] ?? 0
    }
    
    @discardableResult
    public func autoDisableModule(moduleName: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let wasDisabled = _disabledModules.insert(moduleName).inserted
        return wasDisabled
    }
    
    @discardableResult
    public func enableModule(moduleName: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let wasEnabled = _disabledModules.remove(moduleName) != nil
        if wasEnabled {
            _crashCounts[moduleName] = 0
        }
        return wasEnabled
    }
    
    public func resetCrashRecords() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        _crashRecords.removeAll()
        _crashCounts.removeAll()
        _disabledModules.removeAll()
    }
    
    public func crashRecords(for moduleName: String) -> [CrashRecord] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _crashRecords.filter { $0.moduleName == moduleName }
    }
    
    public func isModuleDisabled(_ moduleName: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _disabledModules.contains(moduleName)
    }
}

class CrashIsolatorTests {
    private var isolator: CrashIsolator!
    
    func setup() {
        isolator = CrashIsolator.shared
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
    }
    
    func testExecuteSuccess() -> Bool {
        setup()
        let result = isolator.execute(moduleName: "TestModule") { return 42 }
        guard case .success(let value) = result, value == 42 else {
            print("❌ testExecuteSuccess: 期望成功返回42")
            return false
        }
        print("✅ testExecuteSuccess: 通过")
        return true
    }
    
    func testExecuteFailure() -> Bool {
        setup()
        let result = isolator.execute(moduleName: "FaultyModule") {
            throw NSError(domain: "TestError", code: 1, userInfo: nil)
        }
        guard case .failure(let error) = result else {
            print("❌ testExecuteFailure: 期望失败")
            return false
        }
        guard case .moduleCrashed(let moduleName, _) = error, moduleName == "FaultyModule" else {
            print("❌ testExecuteFailure: 期望模块崩溃错误")
            return false
        }
        let records = isolator.crashRecords(for: "FaultyModule")
        guard records.count == 1, records[0].moduleName == "FaultyModule" else {
            print("❌ testExecuteFailure: 期望1条崩溃记录")
            return false
        }
        print("✅ testExecuteFailure: 通过")
        return true
    }
    
    func testCrashCount() -> Bool {
        setup()
        for _ in 1...3 {
            _ = isolator.execute(moduleName: "CountModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        let count = isolator.crashCount(for: "CountModule")
        guard count == 3 else {
            print("❌ testCrashCount: 期望崩溃次数为3，实际为\(count)")
            return false
        }
        print("✅ testCrashCount: 通过")
        return true
    }
    
    func testAutoDisable() -> Bool {
        setup()
        isolator.thresholdCrashCount = 2
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "AutoDisableModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        guard isolator.isModuleDisabled("AutoDisableModule") else {
            print("❌ testAutoDisable: 期望模块被自动禁用")
            return false
        }
        let result = isolator.execute(moduleName: "AutoDisableModule") { return "should not execute" }
        guard case .failure(let error) = result,
              case .moduleDisabled(let name) = error,
              name == "AutoDisableModule" else {
            print("❌ testAutoDisable: 期望模块已禁用错误")
            return false
        }
        print("✅ testAutoDisable: 通过")
        return true
    }
    
    func testEnableModule() -> Bool {
        setup()
        isolator.autoDisableModule(moduleName: "ManualEnableModule")
        guard isolator.isModuleDisabled("ManualEnableModule") else {
            print("❌ testEnableModule: 期望模块已被禁用")
            return false
        }
        let enabled = isolator.enableModule(moduleName: "ManualEnableModule")
        guard enabled else {
            print("❌ testEnableModule: 期望成功恢复模块")
            return false
        }
        guard !isolator.isModuleDisabled("ManualEnableModule") else {
            print("❌ testEnableModule: 期望模块已恢复")
            return false
        }
        let result = isolator.execute(moduleName: "ManualEnableModule") { return "success" }
        guard case .success(let value) = result, value == "success" else {
            print("❌ testEnableModule: 期望恢复后执行成功")
            return false
        }
        print("✅ testEnableModule: 通过")
        return true
    }
    
    func testResetCrashRecords() -> Bool {
        setup()
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "ResetModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        isolator.autoDisableModule(moduleName: "ResetModule")
        guard isolator.crashRecords.count == 2 else {
            print("❌ testResetCrashRecords: 期望2条崩溃记录")
            return false
        }
        isolator.resetCrashRecords()
        guard isolator.crashRecords.isEmpty else {
            print("❌ testResetCrashRecords: 期望崩溃记录为空")
            return false
        }
        guard isolator.crashCount(for: "ResetModule") == 0 else {
            print("❌ testResetCrashRecords: 期望崩溃计数为0")
            return false
        }
        guard !isolator.isModuleDisabled("ResetModule") else {
            print("❌ testResetCrashRecords: 期望模块未被禁用")
            return false
        }
        print("✅ testResetCrashRecords: 通过")
        return true
    }
    
    func testDisabledModules() -> Bool {
        setup()
        isolator.autoDisableModule(moduleName: "ModuleA")
        isolator.autoDisableModule(moduleName: "ModuleB")
        let disabled = isolator.disabledModules
        guard disabled.count == 2 else {
            print("❌ testDisabledModules: 期望2个禁用模块")
            return false
        }
        guard disabled.contains("ModuleA"), disabled.contains("ModuleB") else {
            print("❌ testDisabledModules: 期望包含ModuleA和ModuleB")
            return false
        }
        print("✅ testDisabledModules: 通过")
        return true
    }
    
    func testEnableNotDisabledModule() -> Bool {
        setup()
        let result = isolator.enableModule(moduleName: "NeverDisabledModule")
        guard !result else {
            print("❌ testEnableNotDisabledModule: 期望恢复未禁用模块返回false")
            return false
        }
        print("✅ testEnableNotDisabledModule: 通过")
        return true
    }
    
    func testThreadSafety() -> Bool {
        setup()
        isolator.thresholdCrashCount = 1000  // 设大值，避免自动禁用干扰并发测试
        
        let expectation = 100
        let group = DispatchGroup()
        
        // 并发执行崩溃操作
        for i in 0..<expectation {
            group.enter()
            DispatchQueue.global().async {
                _ = self.isolator.execute(moduleName: "ThreadSafeModule") {
                    if i % 2 == 0 {
                        throw NSError(domain: "TestError", code: i, userInfo: nil)
                    }
                    return i
                }
                group.leave()
            }
        }
        
        group.wait()
        
        // 验证记录数量正确（应该只有偶数次崩溃被记录）
        let records = isolator.crashRecords(for: "ThreadSafeModule")
        let expectedCrashes = expectation / 2
        
        guard records.count == expectedCrashes else {
            print("❌ testThreadSafety: 期望\(expectedCrashes)条崩溃记录，实际\(records.count)")
            return false
        }
        
        print("✅ testThreadSafety: 通过")
        return true
    }
    
    func testEnableResetsCrashCount() -> Bool {
        setup()
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "ResetCountModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        guard isolator.crashCount(for: "ResetCountModule") == 2 else {
            print("❌ testEnableResetsCrashCount: 期望崩溃计数为2")
            return false
        }
        isolator.autoDisableModule(moduleName: "ResetCountModule")
        isolator.enableModule(moduleName: "ResetCountModule")
        guard isolator.crashCount(for: "ResetCountModule") == 0 else {
            print("❌ testEnableResetsCrashCount: 期望恢复后崩溃计数为0")
            return false
        }
        print("✅ testEnableResetsCrashCount: 通过")
        return true
    }
    
    func runAllTests() {
        print("\n========== CrashIsolator 测试开始 ==========\n")
        let tests = [
            testExecuteSuccess,
            testExecuteFailure,
            testCrashCount,
            testAutoDisable,
            testEnableModule,
            testResetCrashRecords,
            testDisabledModules,
            testEnableNotDisabledModule,
            testThreadSafety,
            testEnableResetsCrashCount
        ]
        var passed = 0
        var failed = 0
        for test in tests {
            if test() {
                passed += 1
            } else {
                failed += 1
            }
        }
        print("\n========== 测试结果 ==========")
        print("通过: \(passed)/\(tests.count)")
        print("失败: \(failed)/\(tests.count)")
        print("============================\n")
    }
}

CrashIsolatorTests().runAllTests()
