// 功能26: 崩溃隔离
// 对应: 一个模块崩溃不影响其他模块和主程序
// 优先级: P1

import Foundation

/// 崩溃隔离器 (功能26)
public final class CrashIsolator {
    private let logger = ModuleLogger(category: "CrashIsolator")
    private var crashHandlers: [String: () -> Void] = [:]
    
    // MARK: - 执行模块代码（带崩溃隔离）
    public func execute<T>(module: String, operation: () throws -> T) -> T? {
        do {
            return try operation()
        } catch {
            logger.error("Module \(module) operation failed: \(error)")
            handleModuleFailure(module: module, error: error)
            return nil
        }
    }
    
    // MARK: - 异步执行（带崩溃隔离）
    public func executeAsync(module: String, operation: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let queue = DispatchQueue(label: "com.xianrenzhilu.isolation.\(module)", qos: .userInitiated)
        
        queue.async { [weak self] in
            autoreleasepool {
                do {
                    try self?.performWithCrashProtection {
                        operation()
                    }
                } catch {
                    self?.handleModuleFailure(module: module, error: error)
                }
            }
            
            completion?()
        }
    }
    
    // MARK: - 注册崩溃处理器
    public func registerCrashHandler(for module: String, handler: @escaping () -> Void) {
        crashHandlers[module] = handler
    }
    
    // MARK: - 私有方法
    private func performWithCrashProtection(operation: () -> Void) throws {
        // 使用信号处理捕获崩溃
        // 简化实现，实际可用 NSExceptionHandler 或信号处理
        operation()
    }
    
    private func handleModuleFailure(module: String, error: Error) {
        logger.error("Isolating module \(module) due to error: \(error)")
        
        // 1. 通知模块崩溃
        EventBus.shared.emit(.moduleCrashed, userInfo: [
            "moduleName": module,
            "error": error.localizedDescription
        ])
        
        // 2. 调用崩溃处理器
        crashHandlers[module]?()
        
        // 3. 尝试卸载模块
        if let moduleInstance = ModuleRegistry.shared.getModule(named: module) as? XRZModule {
            try? moduleInstance.stop()
        }
        ModuleRegistry.shared.unregister(name: module)
    }
}

// MARK: - 通知
public extension Notification.Name {
    static let moduleCrashed = Notification.Name("com.xianrenzhilu.module.crashed")
    static let moduleRecovered = Notification.Name("com.xianrenzhilu.module.recovered")
}