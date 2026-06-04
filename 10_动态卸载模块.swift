// 功能10: 动态卸载模块
// 对应: 运行时卸载模块，释放资源
// 优先级: P1

import Foundation

/// 模块卸载器 (功能10)
public final class ModuleUnloader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger = ModuleLogger(category: "ModuleUnloader")
    
    public init(registry: ModuleRegistry, eventBus: EventBus) {
        self.registry = registry
        self.eventBus = eventBus
    }
    
    // MARK: - 卸载模块
    public func unload(name: String) -> Bool {
        logger.info("Unloading module: \(name)")
        
        // 1. 获取模块实例
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.warning("Module \(name) not found or not conforming to XRZModule")
            return false
        }
        
        // 2. 检查是否有其他模块依赖它
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            logger.warning("Module \(name) has dependents: \(dependents), cannot unload")
            return false
        }
        
        // 3. 调用 stop()
        do {
            try module.stop()
        } catch {
            logger.error("Module \(name) stop() failed: \(error)")
            // 继续卸载，但记录错误
        }
        
        // 4. 从注册表移除
        registry.unregister(name: name)
        
        // 5. 发送事件
        eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        
        logger.info("Module \(name) unloaded successfully")
        return true
    }
    
    // MARK: - 强制卸载 (即使有依赖)
    public func forceUnload(name: String) -> Bool {
        logger.warning("Force unloading module: \(name)")
        
        // 先卸载依赖它的模块
        let dependents = findDependents(of: name)
        for dependent in dependents {
            logger.info("Unloading dependent module first: \(dependent)")
            _ = unload(name: dependent)
        }
        
        // 再卸载目标模块
        return unload(name: name)
    }
    
    // MARK: - 私有方法
    private func findDependents(of moduleName: String) -> [String] {
        var dependents: [String] = []
        
        for name in registry.allModuleNames {
            if let metadata = registry.getMetadata(named: name) {
                if metadata.dependencies.contains(moduleName) {
                    dependents.append(name)
                }
            }
        }
        
        return dependents
    }
}

// MARK: - 模块资源释放协议
public protocol ModuleResourceReleasable {
    func releaseResources()
}

// MARK: - 模块卸载通知
public extension Notification.Name {
    static let moduleWillUnload = Notification.Name("com.xianrenzhilu.module.willUnload")
}