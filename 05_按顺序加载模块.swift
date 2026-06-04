// 功能5: 按顺序加载模块
// 对应: 先加载核心框架模块，再加载业务模块
// 优先级: P0

import Foundation

/// 模块加载器 (功能5 + 功能6 + 功能7)
public final class ModuleLoader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger: ModuleLogger
    private let scanner = ModuleScanner()
    
    public init(registry: ModuleRegistry, eventBus: EventBus, logger: ModuleLogger) {
        self.registry = registry
        self.eventBus = eventBus
        self.logger = logger
    }
    
    // MARK: - 扫描并加载
    public func scanAndLoad(from directory: String) {
        let url = URL(fileURLWithPath: directory)
        let scanned = scanner.scan(directory: url)
        
        // 过滤无效模块
        let valid = scanned.filter { $0.isValid }
        
        // 按优先级排序（数字小的先加载）
        let sorted = valid.sorted { $0.metadata.priority < $1.metadata.priority }
        
        logger.info("Loading \(sorted.count) modules...")
        
        // 加载核心模块（优先级 < 50）
        let coreModules = sorted.filter { $0.metadata.priority < 50 }
        logger.info("Loading \(coreModules.count) core modules...")
        loadModules(coreModules)
        
        // 加载业务模块（优先级 >= 50）
        let businessModules = sorted.filter { $0.metadata.priority >= 50 }
        logger.info("Loading \(businessModules.count) business modules...")
        loadModules(businessModules)
    }
    
    // MARK: - 加载单个模块
    @discardableResult
    public func load(module: ScannedModule) -> ModuleLoadResult {
        let name = module.metadata.name
        
        // 检查是否已加载
        if registry.isLoaded(name: name) {
            return .failure(.alreadyLoaded(name: name))
        }
        
        // 检查配置是否启用
        guard ConfigSystem.shared.isModuleEnabled(name) else {
            logger.info("Module \(name) is disabled in config, skipping")
            return .failure(.loadFailed(name: name, reason: "Disabled in config"))
        }
        
        // 检查依赖
        let dependencies = ConfigSystem.shared.getModuleDependencies(name)
        for dep in dependencies {
            if !registry.isLoaded(name: dep) {
                logger.error("Module \(name) depends on \(dep) which is not loaded")
                return .failure(.dependencyMissing(module: name, dependency: dep))
            }
        }
        
        // 记录开始时间
        let startTime = Date()
        
        do {
            // 加载 bundle
            guard let bundle = Bundle(url: module.bundleURL) else {
                return .failure(.loadFailed(name: name, reason: "Failed to load bundle"))
            }
            
            // 获取入口类
            let className = module.metadata.entryClass
            guard let moduleClass = bundle.classNamed(className) as? XRZModule.Type else {
                return .failure(.loadFailed(name: name, reason: "Entry class \(className) not found or doesn't conform to XRZModule"))
            }
            
            // 实例化
            let instance = moduleClass.init()
            
            // 调用 start()
            try instance.start()
            
            // 注册到注册表
            registry.register(module: instance, name: name)
            
            let loadTime = Date().timeIntervalSince(startTime)
            logger.info("Module \(name) loaded in \(String(format: "%.3f", loadTime))s")
            
            // 发送事件
            eventBus.emit(.moduleDidLoad, userInfo: [
                "moduleName": name,
                "moduleVersion": module.metadata.version,
                "loadTime": loadTime
            ])
            
            return .success(metadata: module.metadata)
            
        } catch {
            logger.error("Failed to load module \(name): \(error)")
            
            // 发送失败事件
            eventBus.emit(.moduleLoadFailed, userInfo: [
                "moduleName": name,
                "error": error.localizedDescription
            ])
            
            return .failure(.startFailed(name: name, error: error))
        }
    }
    
    // MARK: - 卸载模块
    public func unload(name: String) {
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.warning("Module \(name) not found in registry")
            return
        }
        
        do {
            try module.stop()
            registry.unregister(name: name)
            
            logger.info("Module \(name) unloaded")
            eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        } catch {
            logger.error("Failed to stop module \(name): \(error)")
        }
    }
    
    // MARK: - 卸载所有
    public func unloadAllModules() {
        let allModules = registry.allModuleNames
        for name in allModules {
            unload(name: name)
        }
    }
    
    // MARK: - 私有方法
    private func loadModules(_ modules: [ScannedModule]) {
        for module in modules {
            let result = load(module: module)
            if !result.isSuccess {
                // 功能7: 加载失败不崩溃，继续加载其他
                logger.warning("Continuing to load remaining modules...")
            }
        }
    }
}