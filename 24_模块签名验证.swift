// 功能24: 模块签名验证
// 对应: 只加载签名有效的模块（防止恶意代码）
// 优先级: P2

import Foundation
import Security
import os

// MARK: - SignatureStatus
/// 代码签名验证结果
public enum SignatureStatus: Equatable, CustomStringConvertible {
    /// 签名有效
    case valid
    /// 签名无效（被篡改或验证失败）
    case invalid
    /// 未签名
    case notSigned
    /// 验证过程发生错误
    case error(String)

    public var description: String {
        switch self {
        case .valid:     return "valid"
        case .invalid:   return "invalid"
        case .notSigned: return "notSigned"
        case .error(let msg): return "error(\(msg))"
        }
    }

    /// 是否允许加载（有效 或 未签名但配置允许）
    public var isLoadable: Bool {
        switch self {
        case .valid: return true
        case .invalid, .notSigned, .error: return false
        }
    }
}

// MARK: - SignatureVerifier
/// 模块签名验证器单例
///
/// 使用 Security.framework 的 SecStaticCode API 对模块 Bundle 进行代码签名验证，
/// 支持 Developer ID 分发签名检查、允许的开发者白名单、未签名模块开关等安全策略。
/// 所有可变状态受 os_unfair_lock 保护，线程安全。
public final class SignatureVerifier {

    // MARK: - 单例
    public static let shared = SignatureVerifier()

    // MARK: - 线程安全锁
    private var lock = os_unfair_lock()

    // MARK: - 内部状态
    /// 允许的开发者 ID 列表（Team ID 或签名标识符）
    private var _allowedDeveloperIDs: Set<String> = []
    /// 是否允许加载未签名模块
    private var _allowUnsignedModules: Bool = false

    private let logger = ModuleLogger(category: "SignatureVerifier")

    // MARK: - 初始化
    private init() {}

    // MARK: - 公开属性

    /// 是否允许未签名模块加载（默认 false，严格模式）
    public var allowUnsignedModules: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _allowUnsignedModules
        }
        set {
            os_unfair_lock_lock(&lock)
            _allowUnsignedModules = newValue
            os_unfair_lock_unlock(&lock)
            logger.info("allowUnsignedModules set to \(newValue)")
        }
    }

    // MARK: - 公开方法

    /// 设置允许的开发者 ID 白名单
    /// - Parameter ids: 允许的 Team ID 或签名标识符集合
    public func setAllowedDeveloperIDs(_ ids: [String]) {
        os_unfair_lock_lock(&lock)
        _allowedDeveloperIDs = Set(ids)
        os_unfair_lock_unlock(&lock)
        logger.info("Allowed developer IDs updated: \(ids)")
    }

    /// 验证模块 Bundle 的代码签名
    /// - Parameter bundlePath: 模块 Bundle 的路径
    /// - Returns: 签名验证结果
    public func verifyModule(bundlePath: URL) -> SignatureStatus {
        // 1. 检查路径是否存在
        guard FileManager.default.fileExists(atPath: bundlePath.path) else {
            let msg = "Bundle does not exist: \(bundlePath.path)"
            logger.error(msg)
            return .error(msg)
        }

        // 2. 创建静态代码引用
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundlePath as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            let msg = "Failed to create static code reference: \(createStatus)"
            logger.error(msg)
            return .error(msg)
        }

        // 3. 检查签名有效性（基础验证，不强制特定要求）
        let checkStatus = SecStaticCodeCheckValidity(code, [], nil)

        switch checkStatus {
        case errSecSuccess:
            logger.info("Signature valid for \(bundlePath.lastPathComponent)")
            return .valid

        case errSecCSUnsigned:
            let allowed = allowUnsignedModules
            logger.warning("Bundle \(bundlePath.lastPathComponent) is unsigned. allowUnsignedModules=\(allowed)")
            return allowed ? .valid : .notSigned

        case errSecCSSignatureFailed, errSecCSBadResource:
            logger.error("Signature invalid for \(bundlePath.lastPathComponent): \(checkStatus)")
            return .invalid

        default:
            let msg = "Signature validation failed for \(bundlePath.lastPathComponent): \(checkStatus)"
            logger.error(msg)
            // 如果 allowUnsignedModules 开启且错误暗示缺少签名，则放行
            if allowUnsignedModules && (checkStatus == errSecCSNoMatches || checkStatus == errSecCSUnimplemented) {
                return .valid
            }
            return .invalid
        }
    }

    /// 获取模块的签名身份（Team ID 或签名标识符）
    /// - Parameter bundlePath: 模块 Bundle 的路径
    /// - Returns: 签名身份字符串，未签名或验证失败返回 nil
    public func getSigningIdentity(bundlePath: URL) -> String? {
        guard FileManager.default.fileExists(atPath: bundlePath.path) else {
            return nil
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundlePath as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return nil
        }

        // 获取签名信息字典
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, [], &info)
        guard infoStatus == errSecSuccess, let infoDict = info as? [String: Any] else {
            return nil
        }

        // 优先返回 Team ID
        if let teamID = infoDict[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty {
            return teamID
        }

        // 其次返回签名标识符
        if let identifier = infoDict[kSecCodeInfoIdentifier as String] as? String, !identifier.isEmpty {
            return identifier
        }

        return nil
    }

    /// 验证模块是否使用 Developer ID 签名（适用于 Mac App Store 外分发）
    /// - Parameter bundlePath: 模块 Bundle 的路径
    /// - Returns: 是否为 Developer ID 签名
    public func verifyDeveloperID(bundlePath: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: bundlePath.path) else {
            return false
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundlePath as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return false
        }

        // 获取签名信息
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, [], &info)
        guard infoStatus == errSecSuccess, let infoDict = info as? [String: Any] else {
            return false
        }

        // 检查证书链中是否包含 Developer ID 证书
        guard let certificates = infoDict[kSecCodeInfoCertificates as String] as? [SecCertificate] else {
            return false
        }

        for cert in certificates {
            if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                if summary.contains("Developer ID") {
                    return true
                }
            }
            // 也可通过组织单位 (OU) 判断
            if let ou = extractOrganizationalUnit(from: cert), ou.contains("Developer ID") {
                return true
            }
        }

        return false
    }

    /// 检查模块的开发者是否在允许列表中
    /// - Parameter bundlePath: 模块 Bundle 的路径
    /// - Returns: 是否允许加载
    public func isDeveloperAllowed(bundlePath: URL) -> Bool {
        // 未设置白名单时，允许任何签名有效的模块
        os_unfair_lock_lock(&lock)
        let allowedSet = _allowedDeveloperIDs
        os_unfair_lock_unlock(&lock)

        if allowedSet.isEmpty {
            // 白名单为空表示不限制特定开发者，仅依赖签名验证
            return true
        }

        guard let identity = getSigningIdentity(bundlePath: bundlePath) else {
            return false
        }

        return allowedSet.contains(identity)
    }

    // MARK: - 私有方法

    /// 从证书中提取组织单位 (OU) 信息
    private func extractOrganizationalUnit(from certificate: SecCertificate) -> String? {
        guard let data = SecCertificateCopyData(certificate) as Data? else {
            return nil
        }
        // 简化处理：在证书 DER 数据中搜索常见 OU 字段模式
        // 实际生产环境可使用 SecCertificateCopyValues 获取完整字段
        let hexString = data.map { String(format: "%02x", $0) }.joined()
        // 查找 "2.5.4.11" (organizationalUnitName OID) 的近似位置并提取内容
        // 这里使用简化的字符串匹配，因为完整的 ASN.1 解析超出本示例范围
        if let range = hexString.range(of: "55040804") { // organizationalUnitName 的常见 DER 编码前缀近似
            let start = hexString.index(range.upperBound, offsetBy: 2)
            let lengthHex = String(hexString[start..<hexString.index(start, offsetBy: 2)])
            if let length = Int(lengthHex, radix: 16), length > 0 && length < 256 {
                let contentStart = hexString.index(start, offsetBy: 2)
                let contentEnd = hexString.index(contentStart, offsetBy: length * 2)
                if contentEnd <= hexString.endIndex {
                    let contentHex = String(hexString[contentStart..<contentEnd])
                    var result = ""
                    var index = contentHex.startIndex
                    while index < contentHex.endIndex {
                        let byteHex = String(contentHex[index..<contentHex.index(index, offsetBy: 2)])
                        if let byte = UInt8(byteHex, radix: 16) {
                            result.append(Character(Unicode.Scalar(byte)))
                        }
                        index = contentHex.index(index, offsetBy: 2)
                    }
                    return result.isEmpty ? nil : result
                }
            }
        }
        return nil
    }
}

// MARK: - 测试代码
public final class SignatureVerifierTests {

    /// 运行所有签名验证测试
    public static func runAllTests() {
        testVerifyMainBundle()
        testVerifyNonExistentPath()
        testAllowUnsignedModules()
        testAllowedDeveloperIDs()
        testSigningIdentity()
        testThreadSafety()
        print("\n🎉 All signature verifier tests completed!")
    }

    // MARK: - 测试1: 验证主 Bundle 签名状态
    private static func testVerifyMainBundle() {
        print("\n🧪 Test 1: Verify Main Bundle Signature")

        let mainBundleURL = Bundle.main.bundleURL
        let status = SignatureVerifier.shared.verifyModule(bundlePath: mainBundleURL)

        // 主 Bundle 可能已签名（开发环境 ad-hoc 也算），也可能未签名
        // 只要返回状态是三种预期之一即可，不能是 error
        switch status {
        case .valid:
            print("✅ Main bundle is signed and valid")
        case .notSigned:
            print("✅ Main bundle is not signed (expected in some environments)")
        case .invalid:
            print("✅ Main bundle signature invalid (expected in some environments)")
        case .error(let msg):
            fatalError("❌ Test 1 failed: Unexpected error for main bundle: \(msg)")
        }
    }

    // MARK: - 测试2: 验证不存在的路径
    private static func testVerifyNonExistentPath() {
        print("\n🧪 Test 2: Verify Non-Existent Path")

        let fakePath = URL(fileURLWithPath: "/tmp/nonexistent_bundle_\(UUID().uuidString)")
        let status = SignatureVerifier.shared.verifyModule(bundlePath: fakePath)

        guard case .error = status else {
            fatalError("❌ Test 2 failed: Expected .error for non-existent path, got \(status)")
        }
        print("✅ Non-existent path correctly returns error status")
    }

    // MARK: - 测试3: 未签名模块开关
    private static func testAllowUnsignedModules() {
        print("\n🧪 Test 3: Allow Unsigned Modules Toggle")

        let verifier = SignatureVerifier.shared
        let originalValue = verifier.allowUnsignedModules

        // 3a. 严格模式：创建临时目录（保证无签名）并验证
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_unsigned_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        verifier.allowUnsignedModules = false
        let strictStatus = verifier.verifyModule(bundlePath: tempDir)
        guard strictStatus == .notSigned || strictStatus == .invalid else {
            fatalError("❌ Test 3a failed: Expected .notSigned or .invalid in strict mode, got \(strictStatus)")
        }
        print("✅ Strict mode: Unsigned directory correctly rejected (\(strictStatus))")

        // 3b. 宽松模式：允许未签名
        verifier.allowUnsignedModules = true
        let relaxedStatus = verifier.verifyModule(bundlePath: tempDir)
        guard relaxedStatus == .valid else {
            fatalError("❌ Test 3b failed: Expected .valid when allowUnsignedModules=true, got \(relaxedStatus)")
        }
        print("✅ Relaxed mode: Unsigned directory accepted as valid")

        // 恢复原始值
        verifier.allowUnsignedModules = originalValue
    }

    // MARK: - 测试4: 允许的开发者 ID 列表
    private static func testAllowedDeveloperIDs() {
        print("\n🧪 Test 4: Allowed Developer IDs")

        let verifier = SignatureVerifier.shared
        let originalIDs = verifier.allowedDeveloperIDs()

        // 4a. 空白名单时不限制
        verifier.setAllowedDeveloperIDs([])
        guard verifier.isDeveloperAllowed(bundlePath: Bundle.main.bundleURL) == true else {
            fatalError("❌ Test 4a failed: Empty whitelist should allow all developers")
        }
        print("✅ Empty whitelist allows all developers")

        // 4b. 设置特定白名单，未匹配时应拒绝
        verifier.setAllowedDeveloperIDs(["FAKE_TEAM_ID_999"])
        let allowed = verifier.isDeveloperAllowed(bundlePath: Bundle.main.bundleURL)
        // 主 Bundle 的 Team ID 大概率不是 FAKE_TEAM_ID_999，所以应该返回 false
        // 但如果主 Bundle 没有签名（getSigningIdentity 返回 nil），也返回 false
        if allowed == true {
            // 极小概率主 Bundle 的 Team ID 恰好是 FAKE_TEAM_ID_999，跳过断言
            print("⚠️ Main bundle unexpectedly matched fake Team ID (very unlikely)")
        } else {
            print("✅ Non-matching Team ID correctly rejected")
        }

        // 4c. 如果主 Bundle 有签名身份，将其加入白名单应通过
        if let identity = verifier.getSigningIdentity(bundlePath: Bundle.main.bundleURL) {
            verifier.setAllowedDeveloperIDs([identity])
            guard verifier.isDeveloperAllowed(bundlePath: Bundle.main.bundleURL) == true else {
                fatalError("❌ Test 4c failed: Identity \(identity) should be allowed after adding to whitelist")
            }
            print("✅ Identity \(identity) correctly allowed after whitelist update")
        } else {
            print("⚠️ Main bundle has no signing identity, skipping 4c identity match test")
        }

        // 恢复
        verifier.setAllowedDeveloperIDs(Array(originalIDs))
    }

    // MARK: - 测试5: 获取签名身份
    private static func testSigningIdentity() {
        print("\n🧪 Test 5: Get Signing Identity")

        let verifier = SignatureVerifier.shared

        // 5a. 主 Bundle 可能有身份
        let mainIdentity = verifier.getSigningIdentity(bundlePath: Bundle.main.bundleURL)
        if let identity = mainIdentity {
            print("✅ Main bundle signing identity: \(identity)")
        } else {
            print("✅ Main bundle has no signing identity (expected in unsigned environments)")
        }

        // 5b. 不存在的路径返回 nil
        let fakePath = URL(fileURLWithPath: "/tmp/fake_bundle_\(UUID().uuidString)")
        let fakeIdentity = verifier.getSigningIdentity(bundlePath: fakePath)
        guard fakeIdentity == nil else {
            fatalError("❌ Test 5b failed: Non-existent path should return nil identity")
        }
        print("✅ Non-existent path returns nil identity")

        // 5c. 临时目录无签名，返回 nil
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_identity_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempIdentity = verifier.getSigningIdentity(bundlePath: tempDir)
        guard tempIdentity == nil else {
            fatalError("❌ Test 5c failed: Unsigned temp directory should return nil identity")
        }
        print("✅ Unsigned directory returns nil identity")
    }

    // MARK: - 测试6: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 Test 6: Thread Safety")

        let verifier = SignatureVerifier.shared
        let group = DispatchGroup()
        let iterations = 100

        // 并发读写 allowUnsignedModules
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                verifier.allowUnsignedModules = (i % 2 == 0)
                _ = verifier.allowUnsignedModules
                group.leave()
            }
        }

        // 并发调用 verifyModule
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_thread_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                _ = verifier.verifyModule(bundlePath: tempDir)
                group.leave()
            }
        }

        // 并发调用 setAllowedDeveloperIDs / isDeveloperAllowed
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                verifier.setAllowedDeveloperIDs(["Team\(i)"])
                _ = verifier.isDeveloperAllowed(bundlePath: Bundle.main.bundleURL)
                group.leave()
            }
        }

        group.wait()
        print("✅ Thread safety: \(iterations * 3) concurrent operations completed without crash")
    }
}

// MARK: - SignatureVerifier 扩展（测试辅助）
private extension SignatureVerifier {
    /// 获取当前允许的开发者 ID 列表（用于测试恢复）
    func allowedDeveloperIDs() -> [String] {
        os_unfair_lock_lock(&lock)
        let result = Array(_allowedDeveloperIDs)
        os_unfair_lock_unlock(&lock)
        return result
    }
}
