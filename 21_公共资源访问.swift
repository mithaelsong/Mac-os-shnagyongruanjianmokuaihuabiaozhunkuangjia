// 功能21: 公共资源访问
// 对应: 模块可以访问 Resources/ 下的图片、字体等
// 优先级: P1

import Foundation
import AppKit

/// 资源管理器 (功能21)
public final class ResourceManager {
    public static let shared = ResourceManager()
    
    private var resourceCache: [String: Any] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - 获取公共资源
    public func getImage(named name: String) -> NSImage? {
        // 1. 检查缓存
        lock.lock()
        if let cached = resourceCache[name] as? NSImage {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        // 2. 从主 bundle 加载
        if let image = NSImage(named: name) {
            cacheResource(image, for: name)
            return image
        }
        
        // 3. 从 Resources 目录加载
        if let path = Bundle.main.path(forResource: name, ofType: nil),
           let image = NSImage(contentsOfFile: path) {
            cacheResource(image, for: name)
            return image
        }
        
        return nil
    }
    
    public func getFont(named name: String, size: CGFloat) -> NSFont? {
        let cacheKey = "\(name)_\(size)"
        
        lock.lock()
        if let cached = resourceCache[cacheKey] as? NSFont {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        // 尝试加载自定义字体
        if let font = NSFont(name: name, size: size) {
            cacheResource(font, for: cacheKey)
            return font
        }
        
        return nil
    }
    
    public func getData(named name: String, type: String) -> Data? {
        let cacheKey = "\(name).\(type)"
        
        lock.lock()
        if let cached = resourceCache[cacheKey] as? Data {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        if let path = Bundle.main.path(forResource: name, ofType: type),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            cacheResource(data, for: cacheKey)
            return data
        }
        
        return nil
    }
    
    // MARK: - 缓存
    private func cacheResource(_ resource: Any, for key: String) {
        lock.lock()
        resourceCache[key] = resource
        lock.unlock()
    }
    
    public func clearCache() {
        lock.lock()
        resourceCache.removeAll()
        lock.unlock()
    }
}

// MARK: - 资源路径常量
public extension ResourceManager {
    enum ResourcePaths {
        public static let images = "Resources/Images"
        public static let fonts = "Resources/Fonts"
        public static let data = "Resources/Data"
    }
}