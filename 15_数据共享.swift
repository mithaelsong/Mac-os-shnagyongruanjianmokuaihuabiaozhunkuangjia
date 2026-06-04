// 功能15: 数据共享
// 对应: 模块间共享数据（如用户登录状态、市场数据）
// 优先级: P1

import Foundation

/// 数据共享中心 (功能15)
/// 线程安全的模块间数据共享
public final class DataHub {
    public static let shared = DataHub()
    
    private var storage: [String: Any] = [:]
    private let lock = NSLock()
    private let logger = ModuleLogger(category: "DataHub")
    
    // MARK: - 数据作用域
    public enum Scope {
        case global      // 全局共享
        case module(String)  // 模块私有
        case session     // 会话级别
    }
    
    private init() {}
    
    // MARK: - 存储数据
    public func set(_ value: Any, for key: String, scope: Scope = .global) {
        let scopedKey = makeKey(key, scope: scope)
        
        lock.lock()
        storage[scopedKey] = value
        lock.unlock()
        
        // 广播数据变化
        EventBus.shared.emit(.dataEvent, userInfo: [
            "key": key,
            "scope": String(describing: scope),
            "action": "set"
        ])
    }
    
    // MARK: - 获取数据
    public func get<T>(_ key: String, scope: Scope = .global, type: T.Type) -> T? {
        let scopedKey = makeKey(key, scope: scope)
        
        lock.lock()
        defer { lock.unlock() }
        
        return storage[scopedKey] as? T
    }
    
    // MARK: - 删除数据
    public func remove(_ key: String, scope: Scope = .global) {
        let scopedKey = makeKey(key, scope: scope)
        
        lock.lock()
        storage.removeValue(forKey: scopedKey)
        lock.unlock()
    }
    
    // MARK: - 监听数据变化
    @discardableResult
    public func observe(_ key: String, scope: Scope = .global,
                        callback: @escaping (Any?) -> Void) -> String {
        return EventBus.shared.on(.dataEvent) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let eventKey = userInfo["key"] as? String,
                  eventKey == key else { return }
            
            let scopedKey = self?.makeKey(key, scope: scope)
            self?.lock.lock()
            let value = self?.storage[scopedKey ?? key]
            self?.lock.unlock()
            
            callback(value)
        }
    }
    
    // MARK: - 私有方法
    private func makeKey(_ key: String, scope: Scope) -> String {
        switch scope {
        case .global:
            return "global.\(key)"
        case .module(let name):
            return "module.\(name).\(key)"
        case .session:
            return "session.\(key)"
        }
    }
}

// MARK: - 常用数据键
public extension DataHub {
    enum DataKeys {
        // 市场数据
        public static let currentSymbol = "market.currentSymbol"
        public static let currentTimeframe = "market.currentTimeframe"
        public static let lastPrice = "market.lastPrice"
        
        // 用户状态
        public static let isLoggedIn = "user.isLoggedIn"
        public static let userPreferences = "user.preferences"
        
        // 系统状态
        public static let isOnline = "system.isOnline"
        public static let activeModules = "system.activeModules"
    }
}