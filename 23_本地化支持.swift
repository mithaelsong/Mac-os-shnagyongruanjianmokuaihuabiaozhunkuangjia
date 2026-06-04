// 功能23: 本地化支持
// 对应: 支持多语言（Localizable.strings）
// 优先级: P2

import Foundation

/// 本地化管理器 (功能23)
public final class LocalizationManager {
    public static let shared = LocalizationManager()
    
    private var currentLanguage: String = "zh-Hans"
    private var bundles: [String: Bundle] = [:] // module -> bundle
    private let lock = NSLock()
    
    private init() {
        // 读取用户偏好
        if let preferred = UserDefaults.standard.string(forKey: "app.language") {
            currentLanguage = preferred
        } else {
            // 使用系统语言
            currentLanguage = Locale.preferredLanguages.first ?? "zh-Hans"
        }
    }
    
    // MARK: - 设置语言
    public func setLanguage(_ code: String) {
        currentLanguage = code
        UserDefaults.standard.set(code, forKey: "app.language")
        
        // 通知语言变化
        EventBus.shared.emit(.languageChanged, userInfo: ["language": code])
    }
    
    // MARK: - 注册模块本地化 bundle
    public func registerBundle(_ bundle: Bundle, for module: String) {
        lock.lock()
        bundles[module] = bundle
        lock.unlock()
    }
    
    // MARK: - 获取本地化字符串
    public func string(_ key: String, module: String? = nil, comment: String = "") -> String {
        // 1. 尝试从模块 bundle 获取
        if let module = module,
           let bundle = getBundle(for: module) {
            let localized = NSLocalizedString(key, bundle: bundle, comment: comment)
            if localized != key { return localized }
        }
        
        // 2. 从主 bundle 获取
        return NSLocalizedString(key, comment: comment)
    }
    
    // MARK: - 格式化
    public func format(_ key: String, arguments: CVarArg..., module: String? = nil) -> String {
        let template = string(key, module: module)
        return String(format: template, arguments)
    }
    
    // MARK: - 获取可用语言
    public var availableLanguages: [String] {
        return ["zh-Hans", "zh-Hant", "en", "ja"]
    }
    
    // MARK: - 私有方法
    private func getBundle(for module: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        return bundles[module]
    }
}

// MARK: - 便捷方法
public func L(_ key: String, module: String? = nil) -> String {
    return LocalizationManager.shared.string(key, module: module)
}

// MARK: - 通知
public extension Notification.Name {
    static let languageChanged = Notification.Name("com.xianrenzhilu.localization.languageChanged")
}