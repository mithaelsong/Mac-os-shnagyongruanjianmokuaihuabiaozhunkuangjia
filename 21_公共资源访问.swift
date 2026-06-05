// 功能21: 公共资源访问
// 对应: 模块可以访问 Resources/ 下的图片、字体等
// 优先级: P1

import Foundation
import AppKit
import CoreText
import os

// MARK: - ResourceManager
/// 公共资源管理器 (功能21)
///
/// 特性:
/// - 单例模式，全局统一资源访问入口
/// - 线程安全（os_unfair_lock 保护所有缓存与注册表操作）
/// - 支持从公共 Resources/ 目录和模块私有 bundle 读取
/// - 内置缓存机制，提升重复访问性能
/// - 支持图片、字符串、数据、字体、颜色等资源类型
/// - 统一资源存在性查询
public final class ResourceManager {
    public static let shared = ResourceManager()

    /// 资源缓存：复合键 -> 资源实例
    private var resourceCache: [String: Any] = [:]
    /// 已注册字体文件路径集合
    private var registeredFontPaths: Set<String> = []
    /// 线程安全锁
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "ResourceManager")

    private init() {}

    // MARK: - 缓存键
    private func cacheKey(named name: String, bundle: Bundle?) -> String {
        let bundleID = bundle?.bundleIdentifier ?? "main"
        return "\(bundleID)_\(name)"
    }

    // MARK: - 获取资源 URL
    /// 获取指定资源的文件 URL
    /// - Parameters:
    ///   - name: 资源名称（不含扩展名）
    ///   - type: 资源扩展名，nil 表示无扩展名
    ///   - bundle: 目标 bundle，nil 表示主 bundle / 公共 Resources 目录
    /// - Returns: 资源 URL，如果不存在返回 nil
    public func url(forResource name: String, ofType type: String?, bundle: Bundle? = nil) -> URL? {
        let targetBundle = bundle ?? Bundle.main

        // 1. 直接从 bundle 根目录查找
        if let url = targetBundle.url(forResource: name, withExtension: type) {
            return url
        }

        // 2. 从 Resources 子目录查找
        if let url = targetBundle.url(forResource: name, withExtension: type, subdirectory: "Resources") {
            return url
        }

        // 3. 从常见分类子目录查找（仅限主 bundle）
        if targetBundle == Bundle.main {
            let searchPaths = [
                "Resources/Images",
                "Resources/Fonts",
                "Resources/Data",
                "Resources/Colors",
                "Resources/Strings",
            ]
            for subdir in searchPaths {
                if let url = targetBundle.url(forResource: name, withExtension: type, subdirectory: subdir) {
                    return url
                }
            }
        }

        return nil
    }

    // MARK: - 检查资源是否存在
    /// 检查指定名称的资源是否存在（自动尝试常见扩展名）
    /// - Parameters:
    ///   - name: 资源名称
    ///   - bundle: 目标 bundle，nil 表示主 bundle
    /// - Returns: 资源是否存在
    public func resourceExists(named name: String, bundle: Bundle? = nil) -> Bool {
        let targetBundle = bundle ?? Bundle.main
        let extensions: [String?] = [nil, "png", "jpg", "jpeg", "tiff", "gif",
                                       "json", "plist", "xml", "data", "bin",
                                       "ttf", "otf", "ttc", "strings"]

        for ext in extensions {
            if url(forResource: name, ofType: ext, bundle: targetBundle) != nil {
                return true
            }
        }

        // 额外检查 Asset Catalog 中的图片/颜色（仅限主 bundle）
        if targetBundle == Bundle.main {
            if NSImage(named: name) != nil { return true }
            if #available(macOS 10.13, *) {
                if NSColor(named: NSColor.Name(name)) != nil { return true }
            }
        }

        return false
    }

    // MARK: - 加载图片
    /// 加载图片资源
    /// - Parameters:
    ///   - name: 图片名称（不含扩展名）或 Asset Catalog 中的名称
    ///   - bundle: 目标 bundle，nil 表示主 bundle / 公共 Resources 目录
    /// - Returns: NSImage 实例，如果不存在返回 nil
    public func image(named name: String, bundle: Bundle? = nil) -> NSImage? {
        let cacheKey = self.cacheKey(named: "image_\(name)", bundle: bundle)

        os_unfair_lock_lock(&lock)
        if let cached = resourceCache[cacheKey] as? NSImage {
            os_unfair_lock_unlock(&lock)
            logger.debug("图片缓存命中: '\(name)'")
            return cached
        }
        os_unfair_lock_unlock(&lock)

        let targetBundle = bundle ?? Bundle.main
        var image: NSImage?

        // 1. 从主 bundle Asset Catalog 加载
        if targetBundle == Bundle.main {
            image = NSImage(named: name)
        }

        // 2. 从指定 bundle 的 Asset Catalog 加载（macOS 11+）
        if image == nil, let bundle = bundle {
            if #available(macOS 11.0, *) {
                image = NSImage(named: NSImage.Name(name), bundle: bundle)
            }
        }

        // 3. 从文件系统加载
        if image == nil {
            let imageExts = ["png", "jpg", "jpeg", "tiff", "gif", "bmp", "heic"]
            for ext in imageExts {
                if let url = url(forResource: name, ofType: ext, bundle: targetBundle) {
                    image = NSImage(contentsOf: url)
                    if image != nil { break }
                }
            }
            // 尝试无扩展名
            if image == nil, let url = url(forResource: name, ofType: nil, bundle: targetBundle) {
                image = NSImage(contentsOf: url)
            }
        }

        if let image = image {
            os_unfair_lock_lock(&lock)
            resourceCache[cacheKey] = image
            os_unfair_lock_unlock(&lock)
            logger.info("已加载图片: '\(name)' 来自\(targetBundle.bundleIdentifier ?? "main")")
        } else {
            logger.warning("图片未找到: '\(name)'")
        }

        return image
    }

    // MARK: - 加载字符串
    /// 加载本地化字符串资源
    /// - Parameters:
    ///   - name: 字符串键名
    ///   - table: 字符串表名称，nil 表示 Localizable.strings
    ///   - bundle: 目标 bundle，nil 表示主 bundle
    /// - Returns: 本地化字符串，如果键不存在返回 nil
    public func string(named name: String, table: String? = nil, bundle: Bundle? = nil) -> String? {
        let targetBundle = bundle ?? Bundle.main
        let result = targetBundle.localizedString(forKey: name, value: nil, table: table)

        // localizedString 在没有找到时会返回 key 本身
        if result == name {
            logger.warning("字符串未找到: key='\(name)', table=\(table ?? "Localizable")")
            return nil
        }

        logger.debug("已加载字符串: key='\(name)'")
        return result
    }

    // MARK: - 加载数据
    /// 加载二进制数据资源
    /// - Parameters:
    ///   - name: 资源名称（不含扩展名）
    ///   - bundle: 目标 bundle，nil 表示主 bundle
    /// - Returns: Data 实例，如果不存在返回 nil
    public func data(named name: String, bundle: Bundle? = nil) -> Data? {
        let cacheKey = self.cacheKey(named: "data_\(name)", bundle: bundle)

        os_unfair_lock_lock(&lock)
        if let cached = resourceCache[cacheKey] as? Data {
            os_unfair_lock_unlock(&lock)
            logger.debug("数据缓存命中: '\(name)'")
            return cached
        }
        os_unfair_lock_unlock(&lock)

        let targetBundle = bundle ?? Bundle.main
        var data: Data?

        // 1. 尝试无扩展名
        if let url = url(forResource: name, ofType: nil, bundle: targetBundle) {
            data = try? Data(contentsOf: url)
        }

        // 2. 尝试常见扩展名
        if data == nil {
            let extensions = ["json", "plist", "xml", "data", "bin"]
            for ext in extensions {
                if let url = url(forResource: name, ofType: ext, bundle: targetBundle) {
                    data = try? Data(contentsOf: url)
                    if data != nil { break }
                }
            }
        }

        if let data = data {
            os_unfair_lock_lock(&lock)
            resourceCache[cacheKey] = data
            os_unfair_lock_unlock(&lock)
            logger.info("已加载数据: '\(name)' (\(data.count) 字节)")
        } else {
            logger.warning("数据未找到: '\(name)'")
        }

        return data
    }

    // MARK: - 加载字体
    /// 加载自定义字体
    /// - Parameters:
    ///   - name: 字体 PostScript 名称或字体文件名（不含扩展名）
    ///   - size: 字体大小（磅值）
    ///   - bundle: 目标 bundle，nil 表示主 bundle
    /// - Returns: NSFont 实例，如果不存在返回 nil
    public func font(named name: String, size: CGFloat, bundle: Bundle? = nil) -> NSFont? {
        let cacheKey = self.cacheKey(named: "font_\(name)_\(size)", bundle: bundle)

        os_unfair_lock_lock(&lock)
        if let cached = resourceCache[cacheKey] as? NSFont {
            os_unfair_lock_unlock(&lock)
            logger.debug("字体缓存命中: '\(name)' @ \(size)pt")
            return cached
        }
        os_unfair_lock_unlock(&lock)

        let targetBundle = bundle ?? Bundle.main
        var font: NSFont?

        // 1. 尝试按 PostScript 名称直接加载（系统字体或已注册字体）
        font = NSFont(name: name, size: size)

        // 2. 尝试从字体文件加载并动态注册
        if font == nil {
            let fontExts = ["ttf", "otf", "ttc"]
            for ext in fontExts {
                if let url = url(forResource: name, ofType: ext, bundle: targetBundle) {
                    font = loadAndRegisterFont(from: url, size: size)
                    if font != nil { break }
                }
            }
        }

        if let font = font {
            os_unfair_lock_lock(&lock)
            resourceCache[cacheKey] = font
            os_unfair_lock_unlock(&lock)
            logger.info("已加载字体: '\(name)' @ \(size)pt")
        } else {
            logger.warning("字体未找到: '\(name)' @ \(size)pt")
        }

        return font
    }

    /// 从 URL 加载字体文件并注册到当前进程
    private func loadAndRegisterFont(from url: URL, size: CGFloat) -> NSFont? {
        let path = url.path

        os_unfair_lock_lock(&lock)
        let alreadyRegistered = registeredFontPaths.contains(path)
        if !alreadyRegistered {
            registeredFontPaths.insert(path)
        }
        os_unfair_lock_unlock(&lock)

        // 首次使用时注册字体
        if !alreadyRegistered {
            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !success {
                if let err = error?.takeRetainedValue() {
                    logger.error("注册字体失败: \(path): \(err)")
                }
                // 注册失败，移除记录以便后续重试
                os_unfair_lock_lock(&lock)
                registeredFontPaths.remove(path)
                os_unfair_lock_unlock(&lock)
                return nil
            }
        }

        // 获取字体的 PostScript 名称
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName as String? else {
            return nil
        }

        return NSFont(name: psName, size: size)
    }

    // MARK: - 加载颜色
    /// 加载颜色资源
    /// - Parameters:
    ///   - name: 颜色名称（Asset Catalog 名称或颜色定义文件名）
    ///   - bundle: 目标 bundle，nil 表示主 bundle
    /// - Returns: NSColor 实例，如果不存在返回 nil
    public func color(named name: String, bundle: Bundle? = nil) -> NSColor? {
        let cacheKey = self.cacheKey(named: "color_\(name)", bundle: bundle)

        os_unfair_lock_lock(&lock)
        if let cached = resourceCache[cacheKey] as? NSColor {
            os_unfair_lock_unlock(&lock)
            logger.debug("颜色缓存命中: '\(name)'")
            return cached
        }
        os_unfair_lock_unlock(&lock)

        let targetBundle = bundle ?? Bundle.main
        var color: NSColor?

        // 1. 从 Asset Catalog 加载（macOS 10.13+）
        if #available(macOS 10.13, *) {
            if let bundle = bundle {
                color = NSColor(named: NSColor.Name(name), bundle: bundle)
            } else {
                color = NSColor(named: NSColor.Name(name))
            }
        }

        // 2. 从 JSON 颜色定义加载
        if color == nil {
            color = loadColorFromJSON(named: name, bundle: targetBundle)
        }

        // 3. 从 plist 颜色定义加载
        if color == nil {
            color = loadColorFromPlist(named: name, bundle: targetBundle)
        }

        if let color = color {
            os_unfair_lock_lock(&lock)
            resourceCache[cacheKey] = color
            os_unfair_lock_unlock(&lock)
            logger.info("已加载颜色: '\(name)'")
        } else {
            logger.warning("颜色未找到: '\(name)'")
        }

        return color
    }

    /// 从 JSON 文件加载颜色定义
    /// 支持格式: { "r": 255, "g": 128, "b": 0, "a": 1.0 }
    /// 或 { "red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0 }
    private func loadColorFromJSON(named name: String, bundle: Bundle) -> NSColor? {
        guard let url = url(forResource: name, ofType: "json", bundle: bundle),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let r = parseColorComponent(from: json, keys: ["r", "red"])
        let g = parseColorComponent(from: json, keys: ["g", "green"])
        let b = parseColorComponent(from: json, keys: ["b", "blue"])
        let a = parseColorComponent(from: json, keys: ["a", "alpha"]) ?? 1.0

        guard let red = r, let green = g, let blue = b else { return nil }
        return NSColor(red: red, green: green, blue: blue, alpha: a)
    }

    /// 从 plist 文件加载颜色定义
    private func loadColorFromPlist(named name: String, bundle: Bundle) -> NSColor? {
        guard let url = url(forResource: name, ofType: "plist", bundle: bundle),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let r = parseColorComponent(from: dict, keys: ["r", "red"])
        let g = parseColorComponent(from: dict, keys: ["g", "green"])
        let b = parseColorComponent(from: dict, keys: ["b", "blue"])
        let a = parseColorComponent(from: dict, keys: ["a", "alpha"]) ?? 1.0

        guard let red = r, let green = g, let blue = b else { return nil }
        return NSColor(red: red, green: green, blue: blue, alpha: a)
    }

    /// 解析颜色分量，支持 0~1 浮点数或 0~255 整数
    private func parseColorComponent(from dict: [String: Any], keys: [String]) -> CGFloat? {
        for key in keys {
            if let value = dict[key] as? CGFloat {
                return value > 1.0 ? value / 255.0 : value
            }
            if let value = dict[key] as? Double {
                return CGFloat(value > 1.0 ? value / 255.0 : value)
            }
            if let value = dict[key] as? Int {
                return CGFloat(value) / 255.0
            }
        }
        return nil
    }

    // MARK: - 缓存管理
    /// 清理所有缓存的资源
    public func clearCache() {
        os_unfair_lock_lock(&lock)
        resourceCache.removeAll()
        os_unfair_lock_unlock(&lock)
        logger.info("资源缓存已清理")
    }

    /// 获取当前缓存统计信息
    public var cacheStats: ResourceCacheStats {
        os_unfair_lock_lock(&lock)
        let count = resourceCache.count
        os_unfair_lock_unlock(&lock)
        return ResourceCacheStats(entryCount: count)
    }
}

// MARK: - 缓存统计
/// 资源缓存统计信息
public struct ResourceCacheStats: Sendable {
    public let entryCount: Int
}

// MARK: - 资源路径常量
public extension ResourceManager {
    /// 常用资源子目录路径常量
    enum ResourcePaths {
        public static let images = "Resources/Images"
        public static let fonts = "Resources/Fonts"
        public static let data = "Resources/Data"
        public static let colors = "Resources/Colors"
        public static let strings = "Resources/Strings"
    }
}

// MARK: - 测试代码
/// 公共资源管理器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ResourceManagerTests.run()`
public enum ResourceManagerTests {

    /// 运行所有测试
    public static func run() {
        print("=== 公共资源管理器测试 ===")

        let manager = ResourceManager.shared
        manager.clearCache()

        // 1. 单例测试
        testSingleton()

        // 2. URL 获取测试
        testURLFetching(manager: manager)

        // 3. 资源存在性检查测试
        testResourceExists(manager: manager)

        // 4. 字符串加载测试
        testStringLoading(manager: manager)

        // 5. 缓存机制测试
        testCacheMechanism(manager: manager)

        // 6. 缓存清理测试
        testCacheClear(manager: manager)

        // 7. 线程安全测试
        testThreadSafety(manager: manager)

        // 8. 颜色解析测试
        testColorParsing(manager: manager)

        // 9. 数据加载测试
        testDataLoading(manager: manager)

        // 10. 字体加载测试
        testFontLoading(manager: manager)

        print("\n=== 全部公共资源管理器测试通过 ✅ ===")
    }

    // MARK: - 测试1: 单例
    private static func testSingleton() {
        let instance1 = ResourceManager.shared
        let instance2 = ResourceManager.shared
        guard instance1 === instance2 else {
            fatalError("❌ 测试1失败: ResourceManager.shared不是同一个实例")
        }
        print("✅ 测试1通过: ResourceManager是真正的单例")
    }

    // MARK: - 测试2: URL 获取
    private static func testURLFetching(manager: ResourceManager) {
        // 不存在的资源应返回 nil
        let nonExistentURL = manager.url(forResource: "NonExistentResource_xyz", ofType: "png")
        guard nonExistentURL == nil else {
            fatalError("❌ 测试2失败: 不存在的资源应返回nil")
        }
        print("✅ 测试2通过: 不存在资源返回nil")

        // 带 bundle 参数调用不崩溃
        let _ = manager.url(forResource: "test", ofType: "txt", bundle: Bundle.main)
        print("✅ 测试2通过: bundle参数调用成功")
    }

    // MARK: - 测试3: 资源存在性检查
    private static func testResourceExists(manager: ResourceManager) {
        let uuid = UUID().uuidString
        let exists = manager.resourceExists(named: "DefinitelyNotReal_\(uuid)", bundle: nil)
        guard exists == false else {
            fatalError("❌ 测试3失败: 不存在的资源应返回false")
        }
        print("✅ 测试3通过: 不存在资源返回false")

        // 带 bundle 调用不崩溃
        let _ = manager.resourceExists(named: "test", bundle: Bundle.main)
        print("✅ 测试3通过: bundle参数调用成功")
    }

    // MARK: - 测试4: 字符串加载
    private static func testStringLoading(manager: ResourceManager) {
        let uuid = UUID().uuidString
        let nonExistent = manager.string(named: "NON_EXISTENT_KEY_\(uuid)", table: nil, bundle: nil)
        guard nonExistent == nil else {
            fatalError("❌ 测试4失败: 不存在的键应返回nil")
        }
        print("✅ 测试4通过: 不存在键返回nil")

        // 带 table 参数调用不崩溃
        let _ = manager.string(named: "test_key", table: "CustomTable", bundle: Bundle.main)
        print("✅ 测试4通过: table参数调用成功")
    }

    // MARK: - 测试5: 缓存机制
    private static func testCacheMechanism(manager: ResourceManager) {
        manager.clearCache()
        let initialStats = manager.cacheStats
        guard initialStats.entryCount == 0 else {
            fatalError("❌ 测试5失败: 清理后缓存应为空，实际有\(initialStats.entryCount)项")
        }

        // 加载不存在的资源不会导致异常
        let _ = manager.image(named: "TestCacheImage_\(UUID())")
        let _ = manager.data(named: "TestCacheData_\(UUID())")
        let _ = manager.color(named: "TestCacheColor_\(UUID())")

        print("✅ 测试5通过: 缓存机制无崩溃")
    }

    // MARK: - 测试6: 缓存清理
    private static func testCacheClear(manager: ResourceManager) {
        let _ = manager.color(named: "TestColorPreClear_\(UUID())")
        let _ = manager.font(named: "TestFontPreClear_\(UUID())", size: 12)

        manager.clearCache()
        let stats = manager.cacheStats
        guard stats.entryCount == 0 else {
            fatalError("❌ 测试6失败: 清理后缓存应为空，实际有\(stats.entryCount)项")
        }
        print("✅ 测试6通过: 缓存清理成功，条目数=0")
    }

    // MARK: - 测试7: 线程安全
    private static func testThreadSafety(manager: ResourceManager) {
        let group = DispatchGroup()
        let iterations = 200

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let _ = manager.image(named: "ConcurrentImage\(i)")
                let _ = manager.data(named: "ConcurrentData\(i)")
                let _ = manager.string(named: "ConcurrentString\(i)")
                let _ = manager.color(named: "ConcurrentColor\(i)")
                let _ = manager.font(named: "ConcurrentFont\(i)", size: CGFloat(i % 30 + 10))
                group.leave()
            }
        }

        group.wait()
        print("✅ 测试7通过: \(iterations)并发访问完成无崩溃")
    }

    // MARK: - 测试8: 颜色解析
    private static func testColorParsing(manager: ResourceManager) {
        let uuid = UUID().uuidString
        let nonExistent = manager.color(named: "NON_EXISTENT_COLOR_\(uuid)")
        guard nonExistent == nil else {
            fatalError("❌ 测试8失败: 不存在的颜色应返回nil")
        }
        print("✅ 测试8通过: 不存在颜色返回nil")

        // 带 bundle 调用不崩溃
        let _ = manager.color(named: "test_color", bundle: Bundle.main)
        print("✅ 测试8通过: bundle参数调用成功")
    }

    // MARK: - 测试9: 数据加载
    private static func testDataLoading(manager: ResourceManager) {
        let uuid = UUID().uuidString
        let nonExistent = manager.data(named: "NON_EXISTENT_DATA_\(uuid)")
        guard nonExistent == nil else {
            fatalError("❌ 测试9失败: 不存在的数据应返回nil")
        }
        print("✅ 测试9通过: 不存在数据返回nil")

        // 带 bundle 调用不崩溃
        let _ = manager.data(named: "test_data", bundle: Bundle.main)
        print("✅ 测试9通过: bundle参数调用成功")
    }

    // MARK: - 测试10: 字体加载
    private static func testFontLoading(manager: ResourceManager) {
        let uuid = UUID().uuidString
        let nonExistent = manager.font(named: "NON_EXISTENT_FONT_\(uuid)", size: 16)
        guard nonExistent == nil else {
            fatalError("❌ 测试10失败: 不存在的字体应返回nil")
        }
        print("✅ 测试10通过: 不存在字体返回nil")

        // 带 bundle 调用不崩溃
        let _ = manager.font(named: "test_font", size: 14, bundle: Bundle.main)
        print("✅ 测试10通过: bundle参数调用成功")
    }
}
