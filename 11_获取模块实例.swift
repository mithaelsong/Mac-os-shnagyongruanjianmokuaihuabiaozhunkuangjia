// 功能11: 获取模块实例
// 对应: 通过模块名获取模块，供其他模块调用
// 优先级: P0

import Foundation

/// 模块获取器 (功能11)
/// 封装 ModuleRegistry，提供类型安全的获取方法
public final class ModuleResolver {
    public static let shared = ModuleResolver()
    
    private let registry = ModuleRegistry.shared
    private let logger = ModuleLogger(category: "ModuleResolver")
    
    private init() {}
    
    // MARK: - 获取模块 (类型安全)
    public func resolve<T>(_ type: T.Type, named name: String) -> T? {
        guard let module = registry.getModule(named: name) else {
            logger.warning("Module \(name) not found")
            return nil
        }
        
        guard let typed = module as? T else {
            logger.error("Module \(name) does not conform to \(String(describing: T.self))")
            return nil
        }
        
        return typed
    }
    
    // MARK: - 获取模块协议
    public func resolveProtocol(_ name: String) -> XRZModule? {
        return registry.getModule(named: name) as? XRZModule
    }
    
    // MARK: - 获取所有符合协议的模块
    public func resolveAll<T>(_ type: T.Type) -> [(name: String, module: T)] {
        return registry.getModules(conformingTo: type)
    }
    
    // MARK: - 检查模块是否存在且运行中
    public func isAvailable(_ name: String) -> Bool {
        guard registry.isLoaded(name: name) else { return false }
        guard let module = registry.getModule(named: name) as? XRZModule else { return false }
        
        // 可以扩展检查模块是否真正在运行
        return true
    }
    
    // MARK: - 获取模块服务
    public func getService<T>(from module: String, serviceName: String, type: T.Type) -> T? {
        guard let module = registry.getModule(named: module) as? XRZModule else {
            return nil
        }
        
        return module.services[serviceName] as? T
    }
}

// MARK: - 使用示例
/*
 // K线模块获取指标引擎
 let indicatorEngine = ModuleResolver.shared.resolve(
     IndicatorEngineProtocol.self,
     named: "IndicatorEngine"
 )
 
 // 获取所有数据源模块
 let dataSources = ModuleResolver.shared.resolveAll(DataSourceProtocol.self)
 
 // 检查模块是否可用
 if ModuleResolver.shared.isAvailable("WebSocketModule") {
     // 使用 WebSocket
 }
 */