// 功能22: 模块私有资源
// 对应: 模块自己的资源放在自己的 .bundle 里，由全局单例统一管理
// 优先级: P1

import Foundation
import AppKit
import os

/// 模块私有资源管理器 (功能22)
/// 全局单例，统一管理所有模块的私有 bundle 资源
public final class ModuleResourceManager {

    // MARK: - Singleton

    public static let shared = ModuleResourceManager()

    private init() {}

    // MARK: - Storage

    /// 已注册模块的 bundle 映射 [moduleName: Bundle]
    private var moduleBundles: [String: Bundle] = [:]

    /// 资源缓存 [cacheKey: Any]
    private var resourceCache: [String: Any] = [:]

    /// 线程安全锁
    private var lock = os_unfair_lock()

    // MARK: - 注册 / 注销

    /// 注册模块的 bundle
    /// - Returns: 是否注册成功（同名模块已存在则返回 false，不覆盖）
    @discardableResult
    public func registerModule(moduleName: String, bundle: Bundle) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard moduleBundles[moduleName] == nil else {
            return false
        }

        moduleBundles[moduleName] = bundle
        return true
    }

    /// 注销模块
    /// - Returns: 是否注销成功（模块不存在返回 false）
    @discardableResult
    public func unregisterModule(moduleName: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard moduleBundles[moduleName] != nil else {
            return false
        }

        moduleBundles.removeValue(forKey: moduleName)

        // 清理该模块的缓存
        let prefix = "\(moduleName)_"
        resourceCache.keys.filter { $0.hasPrefix(prefix) }.forEach {
            resourceCache.removeValue(forKey: $0)
        }

        return true
    }

    // MARK: - 查询

    /// 获取已注册模块名称列表
    public var registeredModules: [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(moduleBundles.keys)
    }

    /// 检查模块是否已注册
    public func isModuleRegistered(_ moduleName: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return moduleBundles[moduleName] != nil
    }

    // MARK: - 资源获取（每方法均检查模块是否已注册）

    /// 从模块私有 bundle 加载图片
    public func getImage(moduleName: String, named: String) -> NSImage? {
        guard let bundle = bundleForModule(moduleName) else { return nil }

        let cacheKey = "\(moduleName)_image_\(named)"

        if let cached = cachedResource(for: cacheKey) as? NSImage {
            return cached
        }

        // 优先从 Asset Catalog 加载
        if let image = NSImage(named: named, bundle: bundle) {
            cacheResource(image, for: cacheKey)
            return image
        }

        // 回退到文件路径加载
        if let url = bundle.url(forResource: named, withExtension: nil),
           let image = NSImage(contentsOf: url) {
            cacheResource(image, for: cacheKey)
            return image
        }

        return nil
    }

    /// 从模块私有 bundle 加载字符串
    /// - parameter table: .strings 文件名（不含扩展名），传 nil 使用 Localizable.strings
    public func getString(moduleName: String, named: String, table: String?) -> String? {
        guard let bundle = bundleForModule(moduleName) else { return nil }
        let result = bundle.localizedString(forKey: named, value: nil, table: table)
        // 如果返回值与 key 相同，认为资源不存在（近似判断）
        return result == named ? nil : result
    }

    /// 从模块私有 bundle 加载数据
    /// - note: `named` 应包含完整文件名（含扩展名），或资源无扩展名
    public func getData(moduleName: String, named: String) -> Data? {
        guard let bundle = bundleForModule(moduleName) else { return nil }

        let cacheKey = "\(moduleName)_data_\(named)"

        if let cached = cachedResource(for: cacheKey) as? Data {
            return cached
        }

        guard let url = bundle.url(forResource: named, withExtension: nil) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        cacheResource(data, for: cacheKey)
        return data
    }

    /// 从模块私有 bundle 加载字体
    public func getFont(moduleName: String, named: String, size: CGFloat) -> NSFont? {
        guard let bundle = bundleForModule(moduleName) else { return nil }

        let cacheKey = "\(moduleName)_font_\(named)_\(size)"

        if let cached = cachedResource(for: cacheKey) as? NSFont {
            return cached
        }

        // 先尝试系统已有字体（PostScript 名称）
        if let font = NSFont(name: named, size: size) {
            cacheResource(font, for: cacheKey)
            return font
        }

        // 从 bundle 加载字体文件（.ttf / .otf / .ttc）
        let exts = ["ttf", "otf", "ttc"]
        var fontURL: URL?
        for ext in exts {
            if let url = bundle.url(forResource: named, withExtension: ext) {
                fontURL = url
                break
            }
        }

        guard let url = fontURL else {
            return nil
        }

        // 使用 CoreText 注册并加载字体
        guard let fontData = try? Data(contentsOf: url) as CFData,
              let provider = CGDataProvider(data: fontData),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName as? String else {
            return nil
        }

        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterGraphicsFont(cgFont, &error)
        if !registered {
            let errCode = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
            // 105 = kCTFontManagerErrorAlreadyRegistered
            if errCode != 105 {
                return nil
            }
        }

        guard let font = NSFont(name: psName, size: size) else {
            return nil
        }

        cacheResource(font, for: cacheKey)
        return font
    }

    /// 获取模块私有资源 URL
    public func getURL(moduleName: String, forResource: String, ofType: String) -> URL? {
        guard let bundle = bundleForModule(moduleName) else { return nil }
        return bundle.url(forResource: forResource, withExtension: ofType)
    }

    /// 检查资源是否存在
    /// - note: `named` 应包含完整文件名（含扩展名），或资源无扩展名
    public func resourceExists(moduleName: String, named: String) -> Bool {
        guard let bundle = bundleForModule(moduleName) else { return false }
        return bundle.url(forResource: named, withExtension: nil) != nil
    }

    // MARK: - 缓存管理

    /// 清空缓存，可指定模块或全部
    public func clearCache(forModule moduleName: String? = nil) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if let moduleName = moduleName {
            let prefix = "\(moduleName)_"
            resourceCache.keys.filter { $0.hasPrefix(prefix) }.forEach {
                resourceCache.removeValue(forKey: $0)
            }
        } else {
            resourceCache.removeAll()
        }
    }

    // MARK: - 内部方法

    private func bundleForModule(_ moduleName: String) -> Bundle? {
        os_unfair_lock_lock(&lock)
        let bundle = moduleBundles[moduleName]
        os_unfair_lock_unlock(&lock)
        return bundle
    }

    private func cachedResource(for key: String) -> Any? {
        os_unfair_lock_lock(&lock)
        let resource = resourceCache[key]
        os_unfair_lock_unlock(&lock)
        return resource
    }

    private func cacheResource(_ resource: Any, for key: String) {
        os_unfair_lock_lock(&lock)
        resourceCache[key] = resource
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - 测试
extension ModuleResourceManager {

    /// 运行全部测试
    public static func runTests() {
        print("=== 功能22: 模块私有资源 测试开始 ===")

        testRegisterModule()
        testUnregisterModule()
        testDuplicateRegister()
        testUnregisterNonExistent()
        testRegisteredModulesList()
        testThreadSafety()

        print("=== 全部测试通过 ===")
    }

    // MARK: - 测试1: 注册模块
    private static func testRegisterModule() {
        print("测试1: 注册模块...")

        let manager = ModuleResourceManager.shared
        let testBundle = Bundle.main

        let result = manager.registerModule(moduleName: "TestModule", bundle: testBundle)
        guard result == true else {
            fatalError("❌ 注册模块应返回 true")
        }

        guard manager.isModuleRegistered("TestModule") == true else {
            fatalError("❌ 注册后模块应存在")
        }

        // 清理
        _ = manager.unregisterModule(moduleName: "TestModule")

        print("✅ 测试1通过")
    }

    // MARK: - 测试2: 注销模块
    private static func testUnregisterModule() {
        print("测试2: 注销模块...")

        let manager = ModuleResourceManager.shared
        let testBundle = Bundle.main

        _ = manager.registerModule(moduleName: "TestModule2", bundle: testBundle)
        let result = manager.unregisterModule(moduleName: "TestModule2")
        guard result == true else {
            fatalError("❌ 注销已注册模块应返回 true")
        }

        guard manager.isModuleRegistered("TestModule2") == false else {
            fatalError("❌ 注销后模块不应存在")
        }

        print("✅ 测试2通过")
    }

    // MARK: - 测试3: 重复注册
    private static func testDuplicateRegister() {
        print("测试3: 重复注册...")

        let manager = ModuleResourceManager.shared
        let testBundle = Bundle.main

        let first = manager.registerModule(moduleName: "DupModule", bundle: testBundle)
        guard first == true else {
            fatalError("❌ 首次注册应返回 true")
        }

        let second = manager.registerModule(moduleName: "DupModule", bundle: testBundle)
        guard second == false else {
            fatalError("❌ 重复注册应返回 false")
        }

        // 清理
        _ = manager.unregisterModule(moduleName: "DupModule")

        print("✅ 测试3通过")
    }

    // MARK: - 测试4: 注销不存在模块
    private static func testUnregisterNonExistent() {
        print("测试4: 注销不存在模块...")

        let manager = ModuleResourceManager.shared

        let result = manager.unregisterModule(moduleName: "GhostModule")
        guard result == false else {
            fatalError("❌ 注销不存在模块应返回 false")
        }

        print("✅ 测试4通过")
    }

    // MARK: - 测试5: 已注册模块列表查询
    private static func testRegisteredModulesList() {
        print("测试5: 已注册模块列表查询...")

        let manager = ModuleResourceManager.shared
        let testBundle = Bundle.main

        let before = manager.registeredModules

        _ = manager.registerModule(moduleName: "ListModuleA", bundle: testBundle)
        _ = manager.registerModule(moduleName: "ListModuleB", bundle: testBundle)

        let after = manager.registeredModules
        guard after.count == before.count + 2 else {
            fatalError("❌ 注册后模块列表应增加2个，实际增加 \(after.count - before.count)")
        }

        guard after.contains("ListModuleA") && after.contains("ListModuleB") else {
            fatalError("❌ 模块列表应包含注册的两个模块")
        }

        // 清理
        _ = manager.unregisterModule(moduleName: "ListModuleA")
        _ = manager.unregisterModule(moduleName: "ListModuleB")

        print("✅ 测试5通过")
    }

    // MARK: - 测试6: 线程安全（100并发注册+查询）
    private static func testThreadSafety() {
        print("测试6: 线程安全（100并发注册+查询）...")

        let manager = ModuleResourceManager.shared
        let testBundle = Bundle.main
        let group = DispatchGroup()
        let count = 100

        // 并发注册
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                _ = manager.registerModule(moduleName: "ThreadModule\(i)", bundle: testBundle)
                group.leave()
            }
        }

        // 并发查询
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                _ = manager.isModuleRegistered("ThreadModule\(i)")
                _ = manager.registeredModules
                group.leave()
            }
        }

        group.wait()

        // 验证全部注册成功
        let modules = manager.registeredModules
        let registeredCount = modules.filter { $0.hasPrefix("ThreadModule") }.count
        guard registeredCount == count else {
            fatalError("❌ 并发注册后应有 \(count) 个模块，实际 \(registeredCount)")
        }

        // 并发注销
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                _ = manager.unregisterModule(moduleName: "ThreadModule\(i)")
                group.leave()
            }
        }

        group.wait()

        let remaining = manager.registeredModules.filter { $0.hasPrefix("ThreadModule") }.count
        guard remaining == 0 else {
            fatalError("❌ 并发注销后应无 ThreadModule，剩余 \(remaining)")
        }

        print("✅ 测试6通过")
    }
}
