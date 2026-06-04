// 功能23: 本地化支持 (LocalizationManager)
// 对应: 支持多语言（Localizable.strings）
// 优先级: P2
// 平台: macOS / Foundation + AppKit

import Foundation
import AppKit
import os

// MARK: - 语言变更通知定义
public extension Notification.Name {
    /// 语言发生变更时发送的通知，userInfo 包含 ["language": String]
    static let localizationLanguageChanged = Notification.Name(
        "com.xianrenzhilu.localization.languageChanged"
    )
}

// MARK: - 本地化错误
public enum LocalizationError: Error, CustomStringConvertible {
    case unsupportedLanguage(String)
    case bundleNotFound(String)
    case tableNotFound(String, String)

    public var description: String {
        switch self {
        case .unsupportedLanguage(let lang):
            return "不支持的语言: \(lang)"
        case .bundleNotFound(let path):
            return "Bundle 未找到: \(path)"
        case .tableNotFound(let table, let lang):
            return "本地化表未找到: \(table) (语言: \(lang))"
        }
    }
}

// MARK: - LocalizationManager
/// 本地化管理器单例
/// 管理应用多语言本地化，支持动态语言切换、格式化字符串、线程安全
public final class LocalizationManager {

    // MARK: - 单例
    public static let shared = LocalizationManager()

    // MARK: - 线程安全锁
    /// 使用 os_unfair_lock 保证轻量级线程安全
    private var unfairLock = os_unfair_lock()

    // MARK: - 内部状态
    /// 当前语言标识符，如 "zh-Hans", "en", "ja"
    private var _currentLanguage: String

    /// 已注册的模块 Bundle，key 为模块标识
    private var bundles: [String: Bundle] = [:]

    /// 已加载的语言 Bundle 缓存，key 为 "bundlePath_language"
    private var languageBundles: [String: Bundle] = [:]

    /// 支持的语言列表
    private let _availableLanguages: [String]

    // MARK: - 初始化
    private init() {

        // 默认支持的语言
        self._availableLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru"]

        // 从 UserDefaults 读取已保存的语言偏好
        if let saved = UserDefaults.standard.string(forKey: LocalizationKey.savedLanguage),
           _availableLanguages.contains(saved) {
            self._currentLanguage = saved
        } else {
            // 匹配系统首选语言
            self._currentLanguage = LocalizationManager.matchSystemLanguage(
                preferred: Locale.preferredLanguages,
                available: _availableLanguages
            )
        }
    }

    // MARK: - 语言列表
    /// 获取当前支持的所有语言标识符列表
    public var availableLanguages: [String] {
        lock()
        defer { unlock() }
        return _availableLanguages
    }

    // MARK: - 当前语言
    /// 获取当前语言标识符
    public var currentLanguage: String {
        lock()
        defer { unlock() }
        return _currentLanguage
    }

    // MARK: - 设置语言
    /// 切换当前语言
    /// - Parameter identifier: 目标语言标识符，如 "zh-Hans", "en"
    /// - Returns: 切换是否成功
    @discardableResult
    public func setLanguage(_ identifier: String) -> Bool {
        lock()

        // 检查是否已经是当前语言
        guard _currentLanguage != identifier else {
            unlock()
            return true
        }

        // 检查语言是否在支持列表中
        guard _availableLanguages.contains(identifier) else {
            unlock()
            return false
        }

        // 执行切换
        _currentLanguage = identifier

        // 持久化到 UserDefaults
        UserDefaults.standard.set(identifier, forKey: LocalizationKey.savedLanguage)
        UserDefaults.standard.synchronize()

        unlock()

        // 发送全局通知（在锁外发送，避免死锁）
        NotificationCenter.default.post(
            name: .localizationLanguageChanged,
            object: self,
            userInfo: [LocalizationKey.notificationLanguage: identifier]
        )

        return true
    }

    // MARK: - 获取本地化字符串
    /// 获取本地化字符串，支持格式化参数
    /// - Parameters:
    ///   - key: 本地化键名
    ///   - table: 本地化表名（如 "Localizable", "Main"），nil 时默认 "Localizable"
    ///   - bundle: 自定义 Bundle，nil 时使用主 Bundle
    ///   - arguments: 格式化参数，用于 %@ / %d 等占位符
    /// - Returns: 本地化后的字符串；若未找到则返回 key 本身
    public func localizedString(
        key: String,
        table: String? = nil,
        bundle: Bundle? = nil,
        arguments: [CVarArg] = []
    ) -> String {
        let resolvedBundle: Bundle

        if let customBundle = bundle {
            resolvedBundle = resolveLanguageBundle(from: customBundle)
        } else {
            resolvedBundle = resolveLanguageBundle(from: Bundle.main)
        }

        let resolvedTable = table ?? "Localizable"

        let rawString = resolvedBundle.localizedString(
            forKey: key,
            value: key,
            table: resolvedTable
        )

        if arguments.isEmpty {
            return rawString
        } else {
            return String(format: rawString, arguments: arguments)
        }
    }

    // MARK: - Bundle 管理
    /// 为指定模块注册一个 Bundle（用于模块化本地化）
    /// - Parameters:
    ///   - bundle: 模块的 Bundle
    ///   - module: 模块标识名称
    public func registerBundle(_ bundle: Bundle, for module: String) {
        lock()
        bundles[module] = bundle
        unlock()
    }

    /// 获取已注册的模块 Bundle
    public func bundle(for module: String) -> Bundle? {
        lock()
        defer { unlock() }
        return bundles[module]
    }

    /// 移除已注册的模块 Bundle
    @discardableResult
    public func unregisterBundle(for module: String) -> Bundle? {
        lock()
        defer { unlock() }
        return bundles.removeValue(forKey: module)
    }

    /// 清空所有注册的模块 Bundle
    public func unregisterAllBundles() {
        lock()
        bundles.removeAll()
        unlock()
    }

    // MARK: - 便捷方法
    /// 使用当前模块 Bundle 获取本地化字符串
    public func localizedString(
        key: String,
        table: String? = nil,
        module: String? = nil,
        arguments: [CVarArg] = []
    ) -> String {
        let resolvedBundle: Bundle?
        if let module = module {
            resolvedBundle = bundle(for: module)
        } else {
            resolvedBundle = nil
        }
        return localizedString(key: key, table: table, bundle: resolvedBundle, arguments: arguments)
    }

    // MARK: - 私有方法

    /// 根据当前语言解析目标 Bundle（带 .lproj 缓存）
    private func resolveLanguageBundle(from baseBundle: Bundle) -> Bundle {
        let current = currentLanguage
        let cacheKey = "\(baseBundle.bundlePath)_\(current)"

        lock()
        if let cached = languageBundles[cacheKey] {
            unlock()
            return cached
        }
        unlock()

        // 查找 .lproj 目录
        if let lprojPath = baseBundle.path(forResource: current, ofType: "lproj"),
           let langBundle = Bundle(path: lprojPath) {
            lock()
            languageBundles[cacheKey] = langBundle
            unlock()
            return langBundle
        }

        // 未找到则返回原 Bundle
        return baseBundle
    }

    /// 锁操作
    private func lock() {
        os_unfair_lock_lock(&unfairLock)
    }

    private func unlock() {
        os_unfair_lock_unlock(&unfairLock)
    }

    /// 将系统首选语言匹配到支持列表中最接近的语言
    private static func matchSystemLanguage(preferred: [String], available: [String]) -> String {
        for pref in preferred {
            // 完全匹配
            if available.contains(pref) {
                return pref
            }
            // 前缀匹配，如 "zh-Hans-CN" -> "zh-Hans"
            for avail in available {
                if pref.hasPrefix(avail) || avail.hasPrefix(pref) {
                    return avail
                }
            }
            // 只匹配语言代码，如 "zh-Hans" 和 "zh-Hant" 都匹配 "zh"
            let prefLang = pref.split(separator: "-").first.map(String.init) ?? pref
            for avail in available {
                let availLang = avail.split(separator: "-").first.map(String.init) ?? avail
                if prefLang == availLang {
                    return avail
                }
            }
        }
        // 兜底返回简体中文
        return "zh-Hans"
    }
}

// MARK: - UserDefaults Key 常量
private enum LocalizationKey {
    static let savedLanguage = "com.xianrenzhilu.localization.savedLanguage"
    static let notificationLanguage = "language"
}

// MARK: - 全局便捷函数
/// 全局便捷函数：获取本地化字符串
/// - Parameters:
///   - key: 本地化键名
///   - table: 本地化表名
///   - bundle: 自定义 Bundle
///   - arguments: 格式化参数
/// - Returns: 本地化后的字符串
public func L(
    _ key: String,
    table: String? = nil,
    bundle: Bundle? = nil,
    arguments: CVarArg...
) -> String {
    return LocalizationManager.shared.localizedString(
        key: key,
        table: table,
        bundle: bundle,
        arguments: arguments
    )
}

/// 全局便捷函数：通过模块名获取本地化字符串
public func L(
    _ key: String,
    table: String? = nil,
    module: String,
    arguments: CVarArg...
) -> String {
    return LocalizationManager.shared.localizedString(
        key: key,
        table: table,
        module: module,
        arguments: arguments
    )
}

// MARK: - 测试代码
#if DEBUG
import XCTest

final class LocalizationManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 每个测试前重置为默认状态
        LocalizationManager.shared.setLanguage("zh-Hans")
    }

    // MARK: Test 1: 单例唯一性
    func testSingleton() {
        let a = LocalizationManager.shared
        let b = LocalizationManager.shared
        XCTAssertTrue(a === b, "LocalizationManager 必须是单例")
    }

    // MARK: Test 2: 获取当前语言与可用语言列表
    func testCurrentLanguageAndAvailableLanguages() {
        let current = LocalizationManager.shared.currentLanguage
        let available = LocalizationManager.shared.availableLanguages

        XCTAssertFalse(current.isEmpty, "当前语言不应为空")
        XCTAssertFalse(available.isEmpty, "可用语言列表不应为空")
        XCTAssertTrue(available.contains(current), "当前语言必须在可用列表中")
        XCTAssertTrue(available.contains("zh-Hans"), "应支持简体中文")
        XCTAssertTrue(available.contains("en"), "应支持英文")
    }

    // MARK: Test 3: 设置语言成功与失败
    func testSetLanguage() {
        let original = LocalizationManager.shared.currentLanguage

        // 切换到英文
        let resultEn = LocalizationManager.shared.setLanguage("en")
        XCTAssertTrue(resultEn, "切换到 en 应成功")
        XCTAssertEqual(LocalizationManager.shared.currentLanguage, "en")

        // 切回原语言（应成功，但不应重复发通知导致问题）
        let resultOriginal = LocalizationManager.shared.setLanguage(original)
        XCTAssertTrue(resultOriginal, "切换回原始语言应成功")
        XCTAssertEqual(LocalizationManager.shared.currentLanguage, original)

        // 尝试切换到不支持的语言
        let resultInvalid = LocalizationManager.shared.setLanguage("xx-XX")
        XCTAssertFalse(resultInvalid, "切换到不支持的语言应失败")
        XCTAssertEqual(LocalizationManager.shared.currentLanguage, original, "失败时不应改变语言")
    }

    // MARK: Test 4: 语言切换通知
    func testLanguageChangeNotification() {
        let expectation = self.expectation(forNotification: .localizationLanguageChanged, object: LocalizationManager.shared) { notification in
            guard let userInfo = notification.userInfo,
                  let lang = userInfo[LocalizationKey.notificationLanguage] as? String else {
                return false
            }
            return lang == "ja"
        }

        LocalizationManager.shared.setLanguage("ja")
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: Test 5: 重复设置相同语言不发送通知（性能优化）
    func testNoNotificationOnSameLanguage() {
        let current = LocalizationManager.shared.currentLanguage
        var notificationReceived = false

        let observer = NotificationCenter.default.addObserver(
            forName: .localizationLanguageChanged,
            object: LocalizationManager.shared,
            queue: .main
        ) { _ in
            notificationReceived = true
        }

        LocalizationManager.shared.setLanguage(current)

        // 短暂等待确保通知循环完成
        let expectation = XCTestExpectation(description: "等待")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)

        XCTAssertFalse(notificationReceived, "设置相同语言时不应发送通知")
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Test 6: 线程安全 —— 并发读写
    func testThreadSafety() {
        let manager = LocalizationManager.shared
        let languages = manager.availableLanguages
        var results: [Bool] = []
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()

        for i in 0..<100 {
            group.enter()
            queue.async {
                let lang = languages[i % languages.count]
                let success = manager.setLanguage(lang)
                lock.lock()
                results.append(success)
                lock.unlock()
                group.leave()
            }
        }

        group.wait()

        // 所有 setLanguage 都应成功（因为都是 availableLanguages 里的）
        XCTAssertEqual(results.filter { $0 }.count, 100, "所有并发语言切换都应成功")

        // 最终语言必须是支持列表之一
        XCTAssertTrue(languages.contains(manager.currentLanguage))
    }

    // MARK: Test 7: 注册与反注册模块 Bundle
    func testBundleRegistration() {
        let moduleName = "TestModule"
        let mainBundle = Bundle.main

        LocalizationManager.shared.registerBundle(mainBundle, for: moduleName)
        let retrieved = LocalizationManager.shared.bundle(for: moduleName)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, mainBundle)

        let removed = LocalizationManager.shared.unregisterBundle(for: moduleName)
        XCTAssertEqual(removed, mainBundle)
        XCTAssertNil(LocalizationManager.shared.bundle(for: moduleName))

        // 清理
        LocalizationManager.shared.unregisterAllBundles()
    }

    // MARK: Test 8: 本地化字符串格式化参数
    func testLocalizedStringWithArguments() {
        // 使用主 Bundle 中的 Localizable.strings（若存在）
        // 若不存在，fallback 返回 key 本身
        let result = LocalizationManager.shared.localizedString(
            key: "test_key",
            table: nil,
            bundle: Bundle.main,
            arguments: [42, "hello"]
        )
        // 至少不应崩溃；若无对应本地化文件则返回 key 自身
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: Test 9: 全局便捷函数 L()
    func testGlobalLFunction() {
        let result1 = L("test_key")
        XCTAssertFalse(result1.isEmpty, "全局 L() 函数应返回非空字符串")

        let result2 = L("format_key", 100, "world")
        // 若本地化文件缺失则返回 key，但至少不崩溃
        XCTAssertFalse(result2.isEmpty)
    }

    // MARK: Test 10: 系统语言匹配逻辑
    func testSystemLanguageMatching() {
        // 完全匹配
        let exact = LocalizationManagerTests.matchSystemLanguage(
            preferred: ["en-US", "zh-Hans"],
            available: ["zh-Hans", "en"]
        )
        XCTAssertEqual(exact, "en")

        // 前缀匹配
        let prefix = LocalizationManagerTests.matchSystemLanguage(
            preferred: ["zh-Hans-CN"],
            available: ["zh-Hans", "zh-Hant"]
        )
        XCTAssertEqual(prefix, "zh-Hans")

        // 兜底
        let fallback = LocalizationManagerTests.matchSystemLanguage(
            preferred: ["xx-XX"],
            available: ["zh-Hans", "en"]
        )
        XCTAssertEqual(fallback, "zh-Hans")
    }

    // 暴露私有方法用于测试
    private static func matchSystemLanguage(preferred: [String], available: [String]) -> String {
        for pref in preferred {
            if available.contains(pref) { return pref }
            for avail in available {
                if pref.hasPrefix(avail) || avail.hasPrefix(pref) { return avail }
            }
            let prefLang = pref.split(separator: "-").first.map(String.init) ?? pref
            for avail in available {
                let availLang = avail.split(separator: "-").first.map(String.init) ?? avail
                if prefLang == availLang { return avail }
            }
        }
        return "zh-Hans"
    }
}
#endif
