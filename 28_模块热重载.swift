// 功能28: 模块热重载（开发模式）
// 对应: 开发时修改模块代码，不用重启 App 就能看到效果
// 优先级: P2 (开发效率)

import Foundation

/// 热重载管理器 (功能28)
public final class HotReloadManager {
    private let fileWatcher: FileWatcher
    private let loader: DynamicModuleLoader
    private let logger = ModuleLogger(category: "HotReload")
    
    private var watchedModules: [String: URL] = [:]
    
    public init(loader: DynamicModuleLoader) {
        self.loader = loader
        self.fileWatcher = FileWatcher()
    }
    
    // MARK: - 开始监视模块
    public func watch(module: String, path: URL) {
        logger.info("Watching module \(module) at \(path.path)")
        
        watchedModules[module] = path
        
        fileWatcher.watch(path: path) { [weak self] in
            self?.reload(module: module)
        }
    }
    
    // MARK: - 停止监视
    public func unwatch(module: String) {
        watchedModules.removeValue(forKey: module)
        fileWatcher.unwatch(path: watchedModules[module])
    }
    
    // MARK: - 手动重载
    public func reload(module: String) {
        guard let path = watchedModules[module] else {
            logger.warning("Module \(module) not being watched")
            return
        }
        
        logger.info("Reloading module \(module)...")
        
        // 1. 卸载旧版本
        let unloader = ModuleUnloader(registry: ModuleRegistry.shared, eventBus: EventBus.shared)
        _ = unloader.forceUnload(name: module)
        
        // 2. 重新编译（如果是源码）
        if path.pathExtension == "swift" {
            compileAndLoad(module: module, sourcePath: path)
        } else {
            // 直接加载 bundle
            _ = loader.load(from: path)
        }
        
        logger.info("Module \(module) reloaded")
    }
    
    // MARK: - 编译并加载
    private func compileAndLoad(module: String, sourcePath: URL) {
        // 简化实现，实际应调用 swiftc 编译
        logger.info("Compiling \(module)...")
        
        // 模拟编译延迟
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logger.info("Compilation complete (mock)")
        }
    }
}

// MARK: - 文件监视器
private final class FileWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    
    func watch(path: URL, callback: @escaping () -> Void) {
        let descriptor = open(path.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue.global()
        )
        
        source.setEventHandler {
            callback()
        }
        
        source.setCancelHandler {
            close(descriptor)
        }
        
        source.resume()
        sources[path.path] = source
    }
    
    func unwatch(path: URL?) {
        guard let path = path else { return }
        sources.removeValue(forKey: path.path)?.cancel()
    }
}