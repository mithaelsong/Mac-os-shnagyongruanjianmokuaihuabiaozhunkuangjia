// 功能26: 崩溃隔离
// 对应: 将模块抛出的异常/崩溃限制在自身范围内，不影响主进程
// 优先级: P1

import Foundation
import os

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

// MARK: - 测试代码
/// 崩溃隔离器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `CrashIsolatorTests.run()`
public enum CrashIsolatorTests {

    /// 运行所有测试
    public static func run() {
        let isolator = CrashIsolator.shared
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3

        print("=== 崩溃隔离测试 ===")
        testExecuteSuccess(isolator: isolator)
        testExecuteFailure(isolator: isolator)
        testCrashCount(isolator: isolator)
        testAutoDisable(isolator: isolator)
        testEnableModule(isolator: isolator)
        testResetCrashRecords(isolator: isolator)
        testDisabledModules(isolator: isolator)
        testEnableNotDisabledModule(isolator: isolator)
        testThreadSafety(isolator: isolator)
        testEnableResetsCrashCount(isolator: isolator)
        print("\n=== 全部崩溃隔离测试通过 ✅ ===")
    }

    // MARK: - 测试1: 正常执行
    static func testExecuteSuccess(isolator: CrashIsolator) {
        print("\n🧪 测试1: 正常执行")
        isolator.thresholdCrashCount = 3
        let result = isolator.execute(moduleName: "TestModule") { return 42 }
        guard case .success(let value) = result, value == 42 else {
            fatalError("❌ 测试1失败: 期望成功返回42")
        }
        print("✅ 测试1通过: 正常执行正确")
    }

    // MARK: - 测试2: 崩溃记录
    static func testExecuteFailure(isolator: CrashIsolator) {
        print("\n🧪 测试2: 崩溃记录")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        let result = isolator.execute(moduleName: "FaultyModule") {
            throw NSError(domain: "TestError", code: 1, userInfo: nil)
        }
        guard case .failure(let error) = result else {
            fatalError("❌ 测试2失败: 期望失败结果")
        }
        guard case .moduleCrashed(let moduleName, _) = error, moduleName == "FaultyModule" else {
            fatalError("❌ 测试2失败: 期望模块崩溃错误")
        }
        let records = isolator.crashRecords(for: "FaultyModule")
        guard records.count == 1, records[0].moduleName == "FaultyModule" else {
            fatalError("❌ 测试2失败: 期望1条崩溃记录")
        }
        print("✅ 测试2通过: 崩溃记录正确")
    }

    // MARK: - 测试3: 崩溃计数
    static func testCrashCount(isolator: CrashIsolator) {
        print("\n🧪 测试3: 崩溃计数")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        for _ in 1...3 {
            _ = isolator.execute(moduleName: "CountModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        let count = isolator.crashCount(for: "CountModule")
        guard count == 3 else {
            fatalError("❌ 测试3失败: 期望崩溃次数为3，实际为\(count)")
        }
        print("✅ 测试3通过: 崩溃计数正确")
    }

    // MARK: - 测试4: 自动禁用
    static func testAutoDisable(isolator: CrashIsolator) {
        print("\n🧪 测试4: 自动禁用")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 2
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "AutoDisableModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        guard isolator.isModuleDisabled("AutoDisableModule") else {
            fatalError("❌ 测试4失败: 期望模块被自动禁用")
        }
        let result = isolator.execute(moduleName: "AutoDisableModule") { return "should not execute" }
        guard case .failure(let error) = result,
              case .moduleDisabled(let name) = error,
              name == "AutoDisableModule" else {
            fatalError("❌ 测试4失败: 期望模块已禁用错误")
        }
        print("✅ 测试4通过: 自动禁用正确")
    }

    // MARK: - 测试5: 恢复模块
    static func testEnableModule(isolator: CrashIsolator) {
        print("\n🧪 测试5: 恢复模块")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        isolator.autoDisableModule(moduleName: "ManualEnableModule")
        guard isolator.isModuleDisabled("ManualEnableModule") else {
            fatalError("❌ 测试5失败: 期望模块已被禁用")
        }
        let enabled = isolator.enableModule(moduleName: "ManualEnableModule")
        guard enabled else {
            fatalError("❌ 测试5失败: 期望成功恢复模块")
        }
        guard !isolator.isModuleDisabled("ManualEnableModule") else {
            fatalError("❌ 测试5失败: 期望模块已恢复")
        }
        let result = isolator.execute(moduleName: "ManualEnableModule") { return "success" }
        guard case .success(let value) = result, value == "success" else {
            fatalError("❌ 测试5失败: 期望恢复后执行成功")
        }
        print("✅ 测试5通过: 恢复模块正确")
    }

    // MARK: - 测试6: 重置崩溃记录
    static func testResetCrashRecords(isolator: CrashIsolator) {
        print("\n🧪 测试6: 重置崩溃记录")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "ResetModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        isolator.autoDisableModule(moduleName: "ResetModule")
        guard isolator.crashRecords.count == 2 else {
            fatalError("❌ 测试6失败: 期望2条崩溃记录")
        }
        isolator.resetCrashRecords()
        guard isolator.crashRecords.isEmpty else {
            fatalError("❌ 测试6失败: 期望崩溃记录为空")
        }
        guard isolator.crashCount(for: "ResetModule") == 0 else {
            fatalError("❌ 测试6失败: 期望崩溃计数为0")
        }
        guard !isolator.isModuleDisabled("ResetModule") else {
            fatalError("❌ 测试6失败: 期望模块未被禁用")
        }
        print("✅ 测试6通过: 重置崩溃记录正确")
    }

    // MARK: - 测试7: 禁用模块列表
    static func testDisabledModules(isolator: CrashIsolator) {
        print("\n🧪 测试7: 禁用模块列表")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        isolator.autoDisableModule(moduleName: "ModuleA")
        isolator.autoDisableModule(moduleName: "ModuleB")
        let disabled = isolator.disabledModules
        guard disabled.count == 2 else {
            fatalError("❌ 测试7失败: 期望2个禁用模块")
        }
        guard disabled.contains("ModuleA"), disabled.contains("ModuleB") else {
            fatalError("❌ 测试7失败: 期望包含ModuleA和ModuleB")
        }
        print("✅ 测试7通过: 禁用模块列表正确")
    }

    // MARK: - 测试8: 恢复未禁用模块
    static func testEnableNotDisabledModule(isolator: CrashIsolator) {
        print("\n🧪 测试8: 恢复未禁用模块")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        let result = isolator.enableModule(moduleName: "NeverDisabledModule")
        guard !result else {
            fatalError("❌ 测试8失败: 期望恢复未禁用模块返回false")
        }
        print("✅ 测试8通过: 恢复未禁用模块正确处理")
    }

    // MARK: - 测试9: 线程安全
    static func testThreadSafety(isolator: CrashIsolator) {
        print("\n🧪 测试9: 线程安全")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 1000
        let expectation = 100
        let group = DispatchGroup()
        for i in 0..<expectation {
            group.enter()
            DispatchQueue.global().async {
                _ = isolator.execute(moduleName: "ThreadSafeModule") {
                    if i % 2 == 0 {
                        throw NSError(domain: "TestError", code: i, userInfo: nil)
                    }
                    return i
                }
                group.leave()
            }
        }
        group.wait()
        let records = isolator.crashRecords(for: "ThreadSafeModule")
        let expectedCrashes = expectation / 2
        guard records.count == expectedCrashes else {
            fatalError("❌ 测试9失败: 期望\(expectedCrashes)条崩溃记录，实际\(records.count)")
        }
        print("✅ 测试9通过: 线程安全正确")
    }

    // MARK: - 测试10: 恢复模块重置计数
    static func testEnableResetsCrashCount(isolator: CrashIsolator) {
        print("\n🧪 测试10: 恢复模块重置计数")
        isolator.resetCrashRecords()
        isolator.thresholdCrashCount = 3
        for _ in 1...2 {
            _ = isolator.execute(moduleName: "ResetCountModule") {
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
        }
        guard isolator.crashCount(for: "ResetCountModule") == 2 else {
           fatalError("❌ 测试10失败: 期望崩溃计数为2")
        }
        isolator.autoDisableModule(moduleName: "ResetCountModule")
        isolator.enableModule(moduleName: "ResetCountModule")
        guard isolator.crashCount(for: "ResetCountModule") == 0 else {
            fatalError("❌ 测试10失败: 期望恢复后崩溃计数为0")
        }
        print("✅ 测试10通过: 恢复模块重置计数正确")
    }
}