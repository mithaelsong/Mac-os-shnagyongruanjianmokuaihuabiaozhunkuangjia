// 功能14: 服务调用
// 对应: 模块 A 调用模块 B 的服务（通过协议，不直接 import）
// 优先级: P0

import Foundation

/// 服务注册表
public final class ServiceRegistry {
    public static let shared = ServiceRegistry()
    
    private var services: [String: Any] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - 注册服务
    public func register<T>(_ service: T, for protocolType: T.Type, named name: String? = nil) {
        let key = name ?? String(describing: protocolType)
        
        lock.lock()
        services[key] = service
        lock.unlock()
        
        LogSystem.shared.log(level: .info, category: "ServiceRegistry", 
                            message: "Registered service: \(key)")
    }
    
    // MARK: - 获取服务
    public func resolve<T>(_ type: T.Type, named name: String? = nil) -> T? {
        let key = name ?? String(describing: type)
        
        lock.lock()
        defer { lock.unlock() }
        
        return services[key] as? T
    }
    
    // MARK: - 注销服务
    public func unregister(named name: String) {
        lock.lock()
        services.removeValue(forKey: name)
        lock.unlock()
    }
}

/// 服务调用器 (功能14)
public final class ServiceInvoker {
    public static let shared = ServiceInvoker()
    
    private let registry = ServiceRegistry.shared
    private let logger = ModuleLogger(category: "ServiceInvoker")
    
    private init() {}
    
    // MARK: - 调用服务
    public func invoke<T, R>(
        _ protocolType: T.Type,
        named name: String? = nil,
        method: (T) -> R
    ) -> R? {
        guard let service = registry.resolve(protocolType, named: name) else {
            logger.warning("Service \(name ?? String(describing: protocolType)) not found")
            return nil
        }
        
        return method(service)
    }
    
    // MARK: - 异步调用
    public func invokeAsync<T, R>(
        _ protocolType: T.Type,
        named name: String? = nil,
        method: @escaping (T) -> R,
        completion: @escaping (R?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.invoke(protocolType, named: name, method: method)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

// MARK: - 使用示例
/*
 // 指标引擎定义协议
 public protocol IndicatorEngineProtocol {
     func calculateRSI(symbol: String, period: Int) -> [Double]
     func calculateMA(symbol: String, period: Int) -> [Double]
 }
 
 // 指标引擎模块注册服务
 class IndicatorEngineModule: XRZModule {
     func start() throws {
         let engine = IndicatorEngineImpl()
         ServiceRegistry.shared.register(engine, for: IndicatorEngineProtocol.self)
     }
 }
 
 // K线模块调用服务
 class KLineModule: XRZModule {
     func fetchIndicators() {
         let rsi = ServiceInvoker.shared.invoke(
             IndicatorEngineProtocol.self,
             method: { $0.calculateRSI(symbol: "BTC", period: 14) }
         )
     }
 }
 */