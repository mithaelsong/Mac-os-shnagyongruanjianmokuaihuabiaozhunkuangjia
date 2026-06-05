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
public final class VersionChecker {

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
    /// 重置所有状态（仅用于测试）
    public func resetForTesting() {
        withLock {
            frameworkVersion = nil
            minimumVersions.removeAll()
            moduleVersions.removeAll()
        }
    }
}

// MARK: - 测试代码
/// 模块版本检查器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `VersionCheckerTests.run()`
public enum VersionCheckerTests {

    /// 运行所有测试
    public static func run() {
        let checker = VersionChecker.shared
        checker.resetForTesting()
        checker.registerFrameworkVersion(Version(major: 2, minor: 5, patch: 0))
        checker.setMinimumVersion(moduleName: "TestModule", version: Version(major: 2, minor: 0, patch: 0))

        print("=== 模块版本检查测试 ===")
        testVersionParsing()
        testVersionComparisonOperators()
        testExactCompatibleVersion(checker: checker)
        testOutdatedVersion(checker: checker)
        testNewerVersion(checker: checker)
        testMajorVersionMismatch(checker: checker)
        testBelowMinimumVersion(checker: checker)
        testFrameworkVersionNotRegistered(checker: checker)
        testBatchCheckAllModules(checker: checker)
        testThreadSafety(checker: checker)
        testEdgeCaseVersionParsing()
        testQueryMethods(checker: checker)
        print("\n=== 全部模块版本检查测试通过 ✅ ===")
    }

    // MARK: - 测试1: 版本号解析
    static func testVersionParsing() {
        print("\n🧪 测试1: 版本号解析")
        let v = Version("1.2.3")
        guard v.major == 1 else { fatalError("❌ 测试1失败: major应为1，实际\(v.major)") }
        guard v.minor == 2 else { fatalError("❌ 测试1失败: minor应为2，实际\(v.minor)") }
        guard v.patch == 3 else { fatalError("❌ 测试1失败: patch应为3，实际\(v.patch)") }
        guard v.stringValue == "1.2.3" else { fatalError("❌ 测试1失败: stringValue应为1.2.3，实际\(v.stringValue)") }
        print("✅ 测试1通过: 版本号解析正确")
    }

    // MARK: - 测试2: 版本比较操作符
    static func testVersionComparisonOperators() {
        print("\n🧪 测试2: 版本比较操作符")
        let v1 = Version(major: 1, minor: 0, patch: 0)
        let v2 = Version(major: 1, minor: 1, patch: 0)
        let v3 = Version(major: 2, minor: 0, patch: 0)
        let v1_copy = Version(major: 1, minor: 0, patch: 0)
        guard v1 < v2 else { fatalError("❌ 测试2失败: v1应小于v2") }
        guard v2 < v3 else { fatalError("❌ 测试2失败: v2应小于v3") }
        guard v3 > v1 else { fatalError("❌ 测试2失败: v3应大于v1") }
        guard v2 >= v1 else { fatalError("❌ 测试2失败: v2应大于等于v1") }
        guard v1 <= v2 else { fatalError("❌ 测试2失败: v1应小于等于v2") }
        guard v1 == v1_copy else { fatalError("❌ 测试2失败: v1应等于v1_copy") }
        guard !(v1 > v2) else { fatalError("❌ 测试2失败: v1不应大于v2") }
        print("✅ 测试2通过: 版本比较操作符正确")
    }

    // MARK: - 测试3: 兼容版本
    static func testExactCompatibleVersion(checker: VersionChecker) {
        print("\n🧪 测试3: 兼容版本")
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 5, patch: 0))
        guard case .compatible = result else {
            fatalError("❌ 测试3失败: 期望.compatible，实际\(result)")
        }
        print("✅ 测试3通过: 兼容版本正确")
    }

    // MARK: - 测试4: 版本过旧
    static func testOutdatedVersion(checker: VersionChecker) {
        print("\n🧪 测试4: 版本过旧")
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 3, patch: 1))
        guard case .outdated = result else {
            fatalError("❌ 测试4失败: 期望.outdated，实际\(result)")
        }
        print("✅ 测试4通过: 版本过旧正确")
    }

    // MARK: - 测试5: 版本比框架新
    static func testNewerVersion(checker: VersionChecker) {
        print("\n🧪 测试5: 版本比框架新")
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 2, minor: 6, patch: 0))
        guard case .newer = result else {
            fatalError("❌ 测试5失败: 期望.newer，实际\(result)")
        }
        print("✅ 测试5通过: 版本比框架新正确")
    }

    // MARK: - 测试6: 主版本不匹配
    static func testMajorVersionMismatch(checker: VersionChecker) {
        print("\n🧪 测试6: 主版本不匹配")
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 3, minor: 0, patch: 0))
        guard case .incompatible = result else {
            fatalError("❌ 测试6失败: 期望.incompatible，实际\(result)")
        }
        print("✅ 测试6通过: 主版本不匹配正确")
    }

    // MARK: - 测试7: 低于最低要求版本
    static func testBelowMinimumVersion(checker: VersionChecker) {
        print("\n🧪 测试7: 低于最低要求版本")
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 1, minor: 9, patch: 9))
        guard case .incompatible = result else {
            fatalError("❌ 测试7失败: 期望.incompatible，实际\(result)")
        }
        print("✅ 测试7通过: 低于最低要求版本正确")
    }

    // MARK: - 测试8: 未注册框架版本
    static func testFrameworkVersionNotRegistered(checker: VersionChecker) {
        print("\n🧪 测试8: 未注册框架版本")
        checker.resetForTesting()
        let result = checker.checkModuleVersion(moduleName: "TestModule", version: Version(major: 1, minor: 0, patch: 0))
        guard case .incompatible = result else {
            fatalError("❌ 测试8失败: 期望.incompatible，实际\(result)")
        }
        checker.registerFrameworkVersion(Version(major: 2, minor: 5, patch: 0))
        checker.setMinimumVersion(moduleName: "TestModule", version: Version(major: 2, minor: 0, patch: 0))
        print("✅ 测试8通过: 未注册框架版本正确")
    }

    // MARK: - 测试9: 批量检查所有已注册模块
    static func testBatchCheckAllModules(checker: VersionChecker) {
        print("\n🧪 测试9: 批量检查所有已注册模块")
        checker.registerModuleVersion(moduleName: "ModuleA", version: Version(major: 2, minor: 3, patch: 0))
        checker.registerModuleVersion(moduleName: "ModuleB", version: Version(major: 2, minor: 5, patch: 0))
        checker.registerModuleVersion(moduleName: "ModuleC", version: Version(major: 3, minor: 0, patch: 0))
        let results = checker.checkAllRegisteredModules()
        guard results.count == 3 else {
            fatalError("❌ 测试9失败: 期望3个结果，实际\(results.count)")
        }
        let statusMap = Dictionary(uniqueKeysWithValues: results.map { ($0.moduleName, $0.status) })
        guard case .outdated = statusMap["ModuleA"]! else {
            fatalError("❌ 测试9失败: ModuleA应过期")
        }
        guard case .compatible = statusMap["ModuleB"]! else {
            fatalError("❌ 测试9失败: ModuleB应兼容")
        }
        guard case .incompatible = statusMap["ModuleC"]! else {
            fatalError("❌ 测试9失败: ModuleC应不兼容")
        }
        print("✅ 测试9通过: 批量检查正确")
    }

    // MARK: - 测试10: 线程安全并发访问
    static func testThreadSafety(checker: VersionChecker) {
        print("\n🧪 测试10: 线程安全")
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                let minor = i % 10
                let v = Version(major: 2, minor: minor, patch: 0)
                _ = checker.checkModuleVersion(moduleName: "ConcurrentModule", version: v)
                if i % 2 == 0 {
                    checker.registerModuleVersion(moduleName: "DynamicModule\(i)", version: v)
                }
                group.leave()
            }
        }
        group.wait()
        print("✅ 测试10通过: 200次并发访问完成无崩溃")
    }

    // MARK: - 测试11: 边界版本解析
    static func testEdgeCaseVersionParsing() {
        print("\n🧪 测试11: 边界版本解析")
        let v1 = Version("2.0")
        guard v1.major == 2 && v1.minor == 0 && v1.patch == 0 else {
            fatalError("❌ 测试11失败: 2.0应解析为2.0.0")
        }
        let v2 = Version("")
        guard v2.major == 0 && v2.minor == 0 && v2.patch == 0 else {
            fatalError("❌ 测试11失败: 空字符串应解析为0.0.0")
        }
        let v3 = Version("5")
        guard v3.major == 5 && v3.minor == 0 && v3.patch == 0 else {
            fatalError("❌ 测试11失败: 5应解析为5.0.0")
        }
        print("✅ 测试11通过: 边界版本解析正确")
    }

    // MARK: - 测试12: 查询方法
    static func testQueryMethods(checker: VersionChecker) {
        print("\n🧪 测试12: 查询方法")
        guard checker.currentFrameworkVersion() == Version(major: 2, minor: 5, patch: 0) else {
            fatalError("❌ 测试12失败: 框架版本不正确")
        }
        guard checker.minimumVersion(for: "TestModule") == Version(major: 2, minor: 0, patch: 0) else {
            fatalError("❌ 测试12失败: 最低版本不正确")
        }
        guard checker.minimumVersion(for: "NonExistent") == nil else {
            fatalError("❌ 测试12失败: 不存在模块的minimumVersion应为nil")
        }
        print("✅ 测试12通过: 查询方法正确")
    }
}
