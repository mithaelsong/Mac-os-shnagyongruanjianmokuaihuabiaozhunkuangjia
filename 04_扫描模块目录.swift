// 功能4: 扫描模块目录
// 对应: 找到 PlugIns/ 下所有模块文件夹
// 优先级: P0

import Foundation

/// 扫描到的模块信息
public struct ScannedModule {
    public let path: URL
    public let name: String
    public let metadata: ModuleMetadata
    public let bundleURL: URL
    public let isValid: Bool
    public let validationError: String?
}

/// 模块扫描器 (功能4)
public final class ModuleScanner {
    private let logger = ModuleLogger(category: "ModuleScanner")
    
    // MARK: - 扫描
    public func scan(directory: URL) -> [ScannedModule] {
        logger.info("Scanning module directory: \(directory.path)")
        
        var results: [ScannedModule] = []
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            logger.warning("Failed to read directory: \(directory.path)")
            return []
        }
        
        for item in contents {
            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            
            if let scanned = scanModuleFolder(at: item) {
                results.append(scanned)
            }
        }
        
        // 按优先级排序
        let sorted = results.sorted { $0.metadata.priority < $1.metadata.priority }
        
        logger.info("Found \(sorted.count) valid modules out of \(contents.count) items")
        return sorted
    }
    
    // MARK: - 扫描单个模块文件夹
    private func scanModuleFolder(at path: URL) -> ScannedModule? {
        let moduleName = path.lastPathComponent
        let metadataURL = path.appendingPathComponent("ModuleMetadata.json")
        let bundleURL = path.appendingPathComponent("\(moduleName).bundle")
        
        // 检查 metadata 文件
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return ScannedModule(
                path: path,
                name: moduleName,
                metadata: ModuleMetadata(name: moduleName, version: "0.0", description: "", entryClass: ""),
                bundleURL: bundleURL,
                isValid: false,
                validationError: "Missing ModuleMetadata.json"
            )
        }
        
        // 解析 metadata
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ModuleMetadata.self, from: data) else {
            return ScannedModule(
                path: path,
                name: moduleName,
                metadata: ModuleMetadata(name: moduleName, version: "0.0", description: "", entryClass: ""),
                bundleURL: bundleURL,
                isValid: false,
                validationError: "Invalid ModuleMetadata.json"
            )
        }
        
        // 检查 bundle 文件
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return ScannedModule(
                path: path,
                name: moduleName,
                metadata: metadata,
                bundleURL: bundleURL,
                isValid: false,
                validationError: "Missing bundle file: \(moduleName).bundle"
            )
        }
        
        return ScannedModule(
            path: path,
            name: moduleName,
            metadata: metadata,
            bundleURL: bundleURL,
            isValid: true,
            validationError: nil
        )
    }
}