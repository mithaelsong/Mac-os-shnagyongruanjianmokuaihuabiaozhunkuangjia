// 功能27: 模块版本检查
// 对应: 检查模块版本是否兼容当前框架
// 优先级: P1

import Foundation
import os

// MARK: - Version 结构体
/// 语义化版本号，支持 major.minor.patch 格式解析与比较
public struct Version: Codable, Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// 从字符串解析版本号，格式为 "major.minor.patch"
    /// 缺失部分默认补 0，非数字部分会被忽略
    public init(_ versionString: String) {
        let parts = versionString.split(separator: ".", omittingEmptySubsequences: false)
        self.major = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
        self.minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
    }

    public init(major: Int, minor: Int, patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    public var stringValue: String {
        return "\(major).\(minor).\(patch)"
    }

    public var description: String {
        return stringValue
    }

    // MARK: Comparable
    public static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }

    // MARK: 扩展比较操作符
    public static func > (lhs: Version, rhs: Version) -> Bool {
        return rhs < lhs
    }

    public static func <= (lhs: Version, rhs: Version) -> Bool {
        return !(rhs < lhs)
    }

    public static func >= (lhs: Version, rhs: Version) -> Bool {
        return !(lhs < rhs)
    }
}

// MARK: - VersionStatus
/// 模块版本检查结果
public enum VersionStatus: Equatable {
    /// 版本兼容
    case compatible
    /// 版本不兼容，附带原因
    case incompatible(String)
    /// 版本过旧，附带提示信息
    case outdated(String)
    /// 版本比框架新，附带提示信息
    case newer(String)
}

// MARK: - VersionChecker
/// 模块版本检查器（单例），线程安全
public final class VersionChecker: @unchecked Sendable {

    // MARK: - 单例
    public static let shared = VersionChecker()

    private init() {}

    // MARK: - 线程安全
    private var lock = os_unfair_lock()

    @inline(__always)
    private func withLock<T>(_ block: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return block()
    }

    // MARK: - 存储
    /// 当前框架版本
    private var frameworkVersion: Version?

    /// 各模块最低要求版本 [模块名: 最低版本]
    private var minimumVersions: [String: Version] = [:]

    /// 已注册模块版本 [模块名: 版本]
    private var moduleVersions: [String: Version] = [:]

    // MARK: - 注册方法

    /// 注册当前框架版本
    public func registerFrameworkVersion(_ version: Version) {
        withLock {
            frameworkVersion = version
        }
    }

    /// 设置指定模块的最低兼容版本
    public func setMinimumVersion(moduleName: String, version: Version) {
        withLock {
            minimumVersions[moduleName] = version
        }
    }

    /// 注册模块版本（用于批量检查）
    public func registerModuleVersion(moduleName: String, version: Version) {
        withLock {
            moduleVersions[moduleName] = version
        }
    }

    // MARK: - 检查方法

    /// 检查指定模块的版本状态
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - version: 模块当前版本
    /// - Returns: 版本兼容性状态
    public func checkModuleVersion(moduleName: String, version: Version) -> VersionStatus {
        return withLock {
            _checkModuleVersion(moduleName: moduleName, version: version)
        }
    }

    /// 内部检查逻辑（必须在锁内调用）
    private func _checkModuleVersion(moduleName: String, version: Version) -> VersionStatus {
        guard let fwVersion = frameworkVersion else {
            return .incompatible("Framework version not registered")
        }

        // 检查最低版本要求
        if let minVersion = minimumVersions[moduleName], version < minVersion {
            return .incompatible("Version \(version) is below minimum required \(minVersion)")
        }

        // 主版本必须一致
        if version.major != fwVersion.major {
            return .incompatible("Major version mismatch: module \(version.major).x.x vs framework \(fwVersion.major).x.x")
        }

        // 详细版本比较
        if version > fwVersion {
            return .newer("Module version \(version) is newer than framework version \(fwVersion)")
        } else if version < fwVersion {
            return .outdated("Module version \(version) is outdated, framework version is \(fwVersion)")
        } else {
            return .compatible
        }
    }

    /// 批量检查所有已注册模块版本
    /// - Returns: 各模块的检查结果数组
    public func checkAllRegisteredModules() -> [(moduleName: String, status: VersionStatus)] {
        return withLock {
            guard frameworkVersion != nil else {
                return moduleVersions.map { ($0.key, .incompatible("Framework version not registered")) }
            }

            return moduleVersions.map { (moduleName, version) in
                let status = _checkModuleVersion(moduleName: moduleName, version: version)
                return (moduleName, status)
            }
        }
    }

    // MARK: - 查询方法

    /// 获取当前注册的框架版本
    public func currentFrameworkVersion() -> Version? {
        return withLock { frameworkVersion }
    }

    /// 获取指定模块的最低要求版本
    public func minimumVersion(for moduleName: String) -> Version? {
        return withLock { minimumVersions[moduleName] }
    }

    // MARK: - 测试辅助
    #if DEBUG
    /// 重置所有状态（仅用于测试）
    public func resetForTesting() {
        withLock {
            frameworkVersion = nil
            minimumVersions.removeAll()
            moduleVersions.removeAll()
        }
    }
    #endif
}

// MARK: - 单元测试
#if DEBUG
import XCTest

final class VersionCheckerTests: XCTestCase {

    var checker: VersionChecker!

    override func setUp() {
        super.setUp()
        checker = VersionChecker.shared
        checker.resetForTesting()
        checker.registerFrameworkVersion(Version(major: 2, minor: 5, patch: 0))
        checker.setMinimumVersion(moduleName: "TestModule", version: Version(major: 2, minor: 0, patch: 0))
    }

    override func tearDown() {
        checker.resetForTesting()
        super.tearDown()
    }

    // MARK: 测试1: 版本号解析
    func testVersionParsing() {
        let v = Version("1.2.3")
        XCTAssertEqual(v.major, 1)
        XCTAssertEqual(v.minor, 2)
        XCTAssertEqual(v.patch, 3)
        XCTAssertEqual(v.stringValue, "1.2.3")
    }

    // MARK: 测试2: 版本比较操作符
    func testVersionComparisonOperators() {
        let v1 = Version(major: 1, minor: 0, patch: 0)
        let v2 = Version(major: 1, minor: 1, patch: 0)
        let v3 = Version(major: 2, minor: 0, patch: 0)
        let v1_copy = Version(major: 1, minor: 0, patch: 0)

        XCTAssertTrue(v1 < v2)
        XCTAssertTrue(v2 < v3)
        XCTAssertTrue(v1 < v3)
        XCTAssertTrue(v3 > v1)
        XCTAssertTrue(v2 >= v1)
        XCTAssertTrue(v1 <= v2)
        XCTAssertTrue(v1 == v1_copy)
        XCTAssertFalse(v1 > v2)
        XCTAssertFalse(v3 <= v1)
    }

    // MARK: 测试3: 兼容版本（完全一致）
    func testExactCompatibleVersion() {
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 5, patch: 0))
        XCTAssertEqual(result, .compatible)
    }

    // MARK: 测试4: 版本过旧
    func testOutdatedVersion() {
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 3, patch: 1))
        XCTAssertEqual(result, .outdated("Module version 2.3.1 is outdated, framework version is 2.5.0"))
    }

    // MARK: 测试5: 版本比框架新
    func testNewerVersion() {
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 6, patch: 0))
        XCTAssertEqual(result, .newer("Module version 2.6.0 is newer than framework version 2.5.0"))
    }

    // MARK: 测试6: 主版本不匹配
    func testMajorVersionMismatch() {
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 3, minor: 0, patch: 0))
        XCTAssertEqual(result, .incompatible("Major version mismatch: module 3.x.x vs framework 2.x.x"))
    }

    // MARK: 测试7: 低于最低要求版本
    func testBelowMinimumVersion() {
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 1, minor: 9, patch: 9))
        XCTAssertEqual(result, .incompatible("Version 1.9.9 is below minimum required 2.0.0"))
    }

    // MARK: 测试8: 未注册框架版本
    func testFrameworkVersionNotRegistered() {
        checker.resetForTesting()
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(result, .incompatible("Framework version not registered"))
    }

    // MARK: 测试9: 批量检查所有已注册模块
    func testBatchCheckAllModules() {
        checker.registerModuleVersion(moduleName: "ModuleA", version: Version(major: 2, minor: 3, patch: 0))
        checker.registerModuleVersion(moduleName: "ModuleB", version: Version(major: 2, minor: 5, patch: 0))
        checker.registerModuleVersion(moduleName: "ModuleC", version: Version(major: 3, minor: 0, patch: 0))

        let results = checker.checkAllRegisteredModules()
        XCTAssertEqual(results.count, 3)

        let statusMap = Dictionary(uniqueKeysWithValues: results.map { ($0.moduleName, $0.status) })

        XCTAssertEqual(statusMap["ModuleA"], .outdated("Module version 2.3.0 is outdated, framework version is 2.5.0"))
        XCTAssertEqual(statusMap["ModuleB"], .compatible)
        XCTAssertEqual(statusMap["ModuleC"], .incompatible("Major version mismatch: module 3.x.x vs framework 2.x.x"))
    }

    // MARK: 测试10: 线程安全并发访问
    func testThreadSafety() {
        let expectation = self.expectation(description: "Concurrent version checks")
        expectation.expectedFulfillmentCount = 200

        for i in 0..<200 {
            DispatchQueue.global().async {
                let minor = i % 10
                let v = Version(major: 2, minor: minor, patch: 0)
                _ = self.checker.checkModuleVersion(moduleName: "ConcurrentModule", version: v)
                if i % 2 == 0 {
                    self.checker.registerModuleVersion(moduleName: "DynamicModule\(i)", version: v)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: 测试11: 边界版本解析
    func testEdgeCaseVersionParsing() {
        let v1 = Version("2.0")
        XCTAssertEqual(v1.major, 2)
        XCTAssertEqual(v1.minor, 0)
        XCTAssertEqual(v1.patch, 0)

        let v2 = Version("")
        XCTAssertEqual(v2.major, 0)
        XCTAssertEqual(v2.minor, 0)
        XCTAssertEqual(v2.patch, 0)

        let v3 = Version("5")
        XCTAssertEqual(v3.major, 5)
        XCTAssertEqual(v3.minor, 0)
        XCTAssertEqual(v3.patch, 0)
    }

    // MARK: 测试12: 查询方法
    func testQueryMethods() {
        XCTAssertEqual(checker.currentFrameworkVersion(), Version(major: 2, minor: 5, patch: 0))
        XCTAssertEqual(checker.minimumVersion(for: "TestModule"), Version(major: 2, minor: 0, patch: 0))
        XCTAssertNil(checker.minimumVersion(for: "NonExistent"))
    }
}
#endif
