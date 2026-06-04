// 功能22: 模块私有资源
// 对应: 模块自己的资源放在自己的 .bundle 里
// 优先级: P1

import Foundation
import AppKit

/// 模块私有资源管理器 (功能22)
public final class ModuleResourceManager {
    private let moduleBundle: Bundle
    private let moduleName: String
    private var resourceCache: [String: Any] = [:]
    private let lock = NSLock()
    
    public init(moduleBundle: Bundle, moduleName: String) {
        self.moduleBundle = moduleBundle
        self.moduleName = moduleName
    }
    
    // MARK: - 获取模块私有资源
    public func getImage(named name: String) -> NSImage? {
        let cacheKey = "\(moduleName)_image_\(name)"
        
        // 检查缓存
        lock.lock()
        if let cached = resourceCache[cacheKey] as? NSImage {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        // 从模块 bundle 加载
        if let image = NSImage(named: name, bundle: moduleBundle) {
            cacheResource(image, for: cacheKey)
            return image
        }
        
        // 从模块 Resources 目录加载
        if let path = moduleBundle.path(forResource: name, ofType: nil, inDirectory: "Resources"),
           let image = NSImage(contentsOfFile: path) {
            cacheResource(image, for: cacheKey)
            return image
        }
        
        return nil
    }
    
    public func getLocalizedString(_ key: String) -> String {
        return NSLocalizedString(key, bundle: moduleBundle, comment: "")
    }
    
    public func getData(named name: String, type: String) -> Data? {
        let cacheKey = "\(moduleName)_data_\(name).\(type)"
        
        lock.lock()
        if let cached = resourceCache[cacheKey] as? Data {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        if let path = moduleBundle.path(forResource: name, ofType: type),
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

// MARK: - 模块资源协议
public protocol ModuleResourceProvider {
    func resourceManager() -> ModuleResourceManager
}