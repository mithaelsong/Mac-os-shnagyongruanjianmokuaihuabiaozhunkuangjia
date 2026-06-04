// 功能9: 动态加载模块
// 对应: 运行时加载新的 .bundle 或模块文件夹
// 优先级: P1

import Foundation

/// 动态模块加载器 (功能9)
public final class DynamicModuleLoader {
    private let registry: ModuleRegistry
    private let loader: ModuleLoader
    private let logger = ModuleLogger(category: "DynamicLoader")
    
    public init(registry: ModuleRegistry, loader: ModuleLoader) {
        self.registry = registry
        self.loader = loader
    }
    
    // MARK: - 动态加载
    public func load(from path: URL) -> ModuleLoadResult {
        logger.info("Dynamic loading from: \(path.path)")
        
        // 扫描路径
        let scanner = ModuleScanner()
        let scanned = scanner.scan(directory: path)
        
        guard let first = scanned.first(where: { $0.isValid }) else {
            return .failure(.loadFailed(name: path.lastPathComponent, reason: "No valid module found"))
        }
        
        // 加载模块
        return loader.load(module: first)
    }
    
    // MARK: - 从网络加载 (高级功能)
    public func loadFromNetwork(url: URL, completion: @escaping (ModuleLoadResult) -> Void) {
        logger.info("Downloading module from: \(url)")
        
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            if let error = error {
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: error.localizedDescription)))
                return
            }
            
            guard let tempURL = tempURL else {
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: "No data downloaded")))
                return
            }
            
            // 移动到插件目录
            let pluginDir = self.pluginDirectory
            let moduleName = url.deletingPathExtension().lastPathComponent
            let destination = pluginDir.appendingPathComponent(moduleName)
            
            do {
                // 解压 (如果是 zip)
                if url.pathExtension == "zip" {
                    try self.unzip(from: tempURL, to: destination)
                } else {
                    try FileManager.default.copyItem(at: tempURL, to: destination)
                }
                
                // 加载
                let result = self.load(from: destination)
                completion(result)
            } catch {
                completion(.failure(.loadFailed(name: moduleName, reason: error.localizedDescription)))
            }
        }
        
        task.resume()
    }
    
    // MARK: - 私有方法
    private var pluginDirectory: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("XianRenZhiLu/PlugIns")
    }
    
    private func unzip(from source: URL, to destination: URL) throws {
        // 使用系统 unzip 命令
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", source.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw NSError(domain: "DynamicModuleLoader", code: Int(process.terminationStatus))
        }
    }
}