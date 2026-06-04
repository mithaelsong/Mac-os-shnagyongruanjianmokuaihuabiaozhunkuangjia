// 功能4: 扫描模块目录
// 对应: 找到 PlugIns/ 下所有模块文件夹，只返回有效模块
// 优先级: P0

import Foundation

/// 扫描到的有效模块信息
/// metadata 在有效模块时一定存在（扫描器只在确认可用后才构建此结构）
public struct ScannedModule {
    public let path: URL
    public let name: String
    public let metadata: ModuleMetadata
    public let bundleURL: URL
}

/// 模块扫描器 (功能4)
/// 单例：全局唯一扫描器实例
/// 职责：扫描指定目录下的模块文件夹，验证 metadata.json 和 bundle 文件完整性
/// 只返回有效模块，无效模块静默跳过（日志记录原因）
public final class ModuleScanner {
    
    public static let shared = ModuleScanner()
    private let logger = ModuleLogger(category: "ModuleScanner")
    
    private init() {}
    
    // MARK: - 扫描
    
    /// 扫描指定目录下的所有模块文件夹
    /// - Parameter directory: PlugIns/ 目录路径
    /// - Returns: 有效模块列表，按 priority 升序排列。目录不存在/不可读返回空数组
    public func scan(directory: URL) -> [ScannedModule] {
        logger.info("Scanning module directory: \(directory.path)")
        
        var results: [ScannedModule] = []
        var totalItemCount = 0
        
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
            totalItemCount += 1
            
            if let scanned = scanSingleModule(at: item) {
                results.append(scanned)
                logger.info("  [OK] \(scanned.name) v\(scanned.metadata.version)")
            }
        }
        
        // 按优先级升序排列（优先级数字越小越先加载）
        let sorted = results.sorted { $0.metadata.priority < $1.metadata.priority }
        
        logger.info("Scan complete: \(sorted.count) valid out of \(totalItemCount) module folders")
        return sorted
    }
    
    // MARK: - 扫描单个模块文件夹
    
    /// 验证并解析单个模块文件夹
    /// - Parameter path: 模块文件夹路径
    /// - Returns: 有效模块信息。无效（缺少 metadata/bundle/配置错误）返回 nil
    private func scanSingleModule(at path: URL) -> ScannedModule? {
        let moduleName = path.lastPathComponent
        let metadataURL = path.appendingPathComponent("ModuleMetadata.json")
        let bundleURL = path.appendingPathComponent("\(moduleName).bundle")
        
        // 1. 检查 metadata 文件是否存在
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            logger.warning("  [SKIP] \(moduleName): missing ModuleMetadata.json")
            return nil
        }
        
        // 2. 解析 metadata JSON
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            logger.warning("  [SKIP] \(moduleName): cannot read ModuleMetadata.json (\(error.localizedDescription))")
            return nil
        }
        
        let metadata: ModuleMetadata
        do {
            metadata = try JSONDecoder().decode(ModuleMetadata.self, from: data)
        } catch {
            logger.warning("  [SKIP] \(moduleName): invalid ModuleMetadata.json (\(error.localizedDescription))")
            return nil
        }
        
        // 3. 检查 bundle 文件是否存在
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            logger.warning("  [SKIP] \(moduleName): missing \(moduleName).bundle")
            return nil
        }
        
        return ScannedModule(
            path: path,
            name: moduleName,
            metadata: metadata,
            bundleURL: bundleURL
        )
    }
}

// MARK: - 测试代码

public final class ModuleScannerTests {
    
    public static func runAllTests() {
        testScanValidModule()
        testScanInvalidDirectory()
        testScanEmptyDirectory()
        testScanMissingMetadata()
        testScanInvalidMetadata()
        testScanMissingBundle()
        testScanMultipleModules()
        testPrioritySorting()
        print("\n🎉 All ModuleScanner tests completed!")
    }
    
    /// 测试1: 扫描有效模块
    public static func testScanValidModule() {
        print("\n🧪 Test 1: Scan Valid Module")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let moduleDir = tempDir.appendingPathComponent("TestModule")
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        
        // 创建 metadata
        let metadata = ModuleMetadata(name: "TestModule", version: "1.0", description: "Test", entryClass: "TestEntry")
        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            fatalError("❌ Test 1 failed: cannot encode metadata")
        }
        let metadataURL = moduleDir.appendingPathComponent("ModuleMetadata.json")
        do {
            try metadataData.write(to: metadataURL)
        } catch {
            fatalError("❌ Test 1 failed: cannot write metadata: \(error)")
        }
        
        // 创建 bundle（随便创建一个空文件占位）
        let bundleURL = moduleDir.appendingPathComponent("TestModule.bundle")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.count == 1 else {
            fatalError("❌ Test 1 failed: expected 1 module, got \(results.count)")
        }
        guard results[0].name == "TestModule" else {
            fatalError("❌ Test 1 failed: expected name 'TestModule', got '\(results[0].name)'")
        }
        guard results[0].metadata.version == "1.0" else {
            fatalError("❌ Test 1 failed: expected version 1.0, got \(results[0].metadata.version)")
        }
        
        print("✅ Test 1 passed: Valid module scanned correctly")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试2: 扫描不存在的目录
    public static func testScanInvalidDirectory() {
        print("\n🧪 Test 2: Scan Invalid Directory")
        
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NONEXISTENT_\(UUID().uuidString)")
        
        let results = ModuleScanner.shared.scan(directory: nonexistent)
        
        guard results.isEmpty else {
            fatalError("❌ Test 2 failed: expected empty results for nonexistent dir, got \(results.count)")
        }
        
        print("✅ Test 2 passed: Nonexistent directory returns empty array")
    }
    
    /// 测试3: 扫描空目录
    public static func testScanEmptyDirectory() {
        print("\n🧪 Test 3: Scan Empty Directory")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.isEmpty else {
            fatalError("❌ Test 3 failed: expected empty results for empty dir, got \(results.count)")
        }
        
        print("✅ Test 3 passed: Empty directory returns empty array")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试4: 扫描缺少 metadata 的模块
    public static func testScanMissingMetadata() {
        print("\n🧪 Test 4: Scan Module with Missing Metadata")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let moduleDir = tempDir.appendingPathComponent("NoMetadataModule")
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        
        let bundleURL = moduleDir.appendingPathComponent("NoMetadataModule.bundle")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.isEmpty else {
            fatalError("❌ Test 4 failed: expected empty results for module without metadata, got \(results.count)")
        }
        
        print("✅ Test 4 passed: Module without metadata skipped correctly")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试5: 扫描 metadata 损坏的模块
    public static func testScanInvalidMetadata() {
        print("\n🧪 Test 5: Scan Module with Invalid Metadata")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let moduleDir = tempDir.appendingPathComponent("BadMetadataModule")
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        
        // 写入无效 JSON
        let metadataURL = moduleDir.appendingPathComponent("ModuleMetadata.json")
        guard let badData = "{{{ invalid json ".data(using: .utf8) else {
            fatalError("❌ Test 5 failed: cannot create bad json data")
        }
        do {
            try badData.write(to: metadataURL)
        } catch {
            fatalError("❌ Test 5 failed: cannot write bad metadata: \(error)")
        }
        
        let bundleURL = moduleDir.appendingPathComponent("BadMetadataModule.bundle")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.isEmpty else {
            fatalError("❌ Test 5 failed: expected empty results for module with bad metadata, got \(results.count)")
        }
        
        print("✅ Test 5 passed: Module with invalid metadata skipped correctly")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试6: 扫描缺少 bundle 的模块
    public static func testScanMissingBundle() {
        print("\n🧪 Test 6: Scan Module with Missing Bundle")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let moduleDir = tempDir.appendingPathComponent("NoBundleModule")
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        
        // 有 metadata 但没有 bundle
        let metadata = ModuleMetadata(name: "NoBundleModule", version: "1.0", description: "", entryClass: "")
        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            fatalError("❌ Test 6 failed: cannot encode metadata")
        }
        let metadataURL = moduleDir.appendingPathComponent("ModuleMetadata.json")
        do {
            try metadataData.write(to: metadataURL)
        } catch {
            fatalError("❌ Test 6 failed: cannot write metadata: \(error)")
        }
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.isEmpty else {
            fatalError("❌ Test 6 failed: expected empty results for module without bundle, got \(results.count)")
        }
        
        print("✅ Test 6 passed: Module without bundle skipped correctly")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试7: 扫描多模块混合场景
    public static func testScanMultipleModules() {
        print("\n🧪 Test 7: Scan Multiple Modules (Mixed Valid/Invalid)")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 创建4个模块：2个有效 + 2个无效
        let moduleConfigs: [(name: String, hasMetadata: Bool, validMetadata: Bool, hasBundle: Bool)] = [
            ("ValidA", true, true, true),
            ("InvalidNoMeta", false, false, true),
            ("ValidB", true, true, true),
            ("InvalidNoBundle", true, true, false),
        ]
        
        for config in moduleConfigs {
            let moduleDir = tempDir.appendingPathComponent(config.name)
            try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
            
            if config.hasMetadata {
                let metadataURL = moduleDir.appendingPathComponent("ModuleMetadata.json")
                if config.validMetadata {
                    let metadata = ModuleMetadata(name: config.name, version: "2.0", description: "", entryClass: "")
                    guard let data = try? JSONEncoder().encode(metadata) else {
                        fatalError("❌ Test 7 failed: cannot encode metadata for \(config.name)")
                    }
                    do {
                        try data.write(to: metadataURL)
                    } catch {
                        fatalError("❌ Test 7 failed: cannot write metadata for \(config.name): \(error)")
                    }
                } else {
                    guard let badData = "bad json".data(using: .utf8) else {
                        fatalError("❌ Test 7 failed: cannot create bad json data")
                    }
                    do {
                        try badData.write(to: metadataURL)
                    } catch {
                        fatalError("❌ Test 7 failed: cannot write bad metadata: \(error)")
                    }
                }
            }
            
            if config.hasBundle {
                let bundleURL = moduleDir.appendingPathComponent("\(config.name).bundle")
                try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            }
        }
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.count == 2 else {
            fatalError("❌ Test 7 failed: expected 2 valid modules, got \(results.count)")
        }
        
        let names = results.map { $0.name }
        guard Set(names) == Set(["ValidA", "ValidB"]) else {
            fatalError("❌ Test 7 failed: expected [ValidA, ValidB], got \(names)")
        }
        guard names.count == 2 else {
            fatalError("❌ Test 7 failed: expected 2 modules, got \(names.count)")
        }
        
        print("✅ Test 7 passed: Mixed scan returns only 2 valid modules")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试8: 优先级排序
    public static func testPrioritySorting() {
        print("\n🧪 Test 8: Priority Sorting")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 创建3个模块，不同优先级
        let priorities = [("ModuleC", 100), ("ModuleA", 10), ("ModuleB", 50)]
        
        for (name, priority) in priorities {
            let moduleDir = tempDir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
            
            let metadata = ModuleMetadata(name: name, version: "1.0", description: "", entryClass: "", priority: priority)
            guard let data = try? JSONEncoder().encode(metadata) else {
                fatalError("❌ Test 8 failed: cannot encode metadata for \(name)")
            }
            do {
                try data.write(to: moduleDir.appendingPathComponent("ModuleMetadata.json"))
            } catch {
                fatalError("❌ Test 8 failed: cannot write metadata for \(name): \(error)")
            }
            
            let bundleURL = moduleDir.appendingPathComponent("\(name).bundle")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        }
        
        let results = ModuleScanner.shared.scan(directory: tempDir)
        
        guard results.count == 3 else {
            fatalError("❌ Test 8 failed: expected 3 modules, got \(results.count)")
        }
        
        let orderedNames = results.map(\.name)
        guard orderedNames == ["ModuleA", "ModuleB", "ModuleC"] else {
            fatalError("❌ Test 8 failed: expected [ModuleA, ModuleB, ModuleC] (priority order), got \(orderedNames)")
        }
        
        let prioritiesResult = results.map(\.metadata.priority)
        guard prioritiesResult == [10, 50, 100] else {
            fatalError("❌ Test 8 failed: priorities not sorted: \(prioritiesResult)")
        }
        
        print("✅ Test 8 passed: Modules sorted by priority correctly")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
}
