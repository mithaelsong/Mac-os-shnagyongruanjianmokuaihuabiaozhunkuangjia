// 功能29: 模块加载日志
// 对应: 输出每个模块的加载时间、成功/失败状态
// 优先级: P0

import Foundation

/// 模块加载日志条目
public struct ModuleLoadLogEntry: Codable {
    public let timestamp: Date
    public let moduleName: String
    public let version: String
    public let status: LoadStatus
    public let loadTime: TimeInterval
    public let errorMessage: String?
    public let dependencies: [String]
    
    public enum LoadStatus: String, Codable {
        case success
        case failure
        case skipped
        case retry
    }
}

/// 模块加载日志 (功能29)
public final class ModuleLoadLogger {
    public static let shared = ModuleLoadLogger()
    
    private var logs: [ModuleLoadLogEntry] = []
    private let lock = NSLock()
    private let logger = ModuleLogger(category: "ModuleLoadLog")
    
    private init() {}
    
    // MARK: - 记录加载事件
    public func logLoadSuccess(module: String, version: String, loadTime: TimeInterval, dependencies: [String]) {
        let entry = ModuleLoadLogEntry(
            timestamp: Date(),
            moduleName: module,
            version: version,
            status: .success,
            loadTime: loadTime,
            errorMessage: nil,
            dependencies: dependencies
        )
        
        append(entry)
        logger.info("✅ Module \(module) v\(version) loaded in \(String(format: "%.3f", loadTime))s")
    }
    
    public func logLoadFailure(module: String, version: String, error: String, dependencies: [String]) {
        let entry = ModuleLoadLogEntry(
            timestamp: Date(),
            moduleName: module,
            version: version,
            status: .failure,
            loadTime: 0,
            errorMessage: error,
            dependencies: dependencies
        )
        
        append(entry)
        logger.error("❌ Module \(module) v\(version) failed: \(error)")
    }
    
    public func logSkipped(module: String, reason: String) {
        let entry = ModuleLoadLogEntry(
            timestamp: Date(),
            moduleName: module,
            version: "",
            status: .skipped,
            loadTime: 0,
            errorMessage: reason,
            dependencies: []
        )
        
        append(entry)
        logger.info("⏭ Module \(module) skipped: \(reason)")
    }
    
    // MARK: - 查询日志
    public func getAllLogs() -> [ModuleLoadLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }
    
    public func getLogs(for module: String) -> [ModuleLoadLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return logs.filter { $0.moduleName == module }
    }
    
    public func getFailedLoads() -> [ModuleLoadLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return logs.filter { $0.status == .failure }
    }
    
    // MARK: - 统计
    public var stats: ModuleLoadStats {
        lock.lock()
        defer { lock.unlock() }
        
        let total = logs.count
        let success = logs.filter { $0.status == .success }.count
        let failed = logs.filter { $0.status == .failure }.count
        let avgTime = logs.filter { $0.status == .success }.map { $0.loadTime }.reduce(0, +) / Double(max(success, 1))
        
        return ModuleLoadStats(
            totalAttempts: total,
            successfulLoads: success,
            failedLoads: failed,
            averageLoadTime: avgTime
        )
    }
    
    // MARK: - 导出
    public func exportToFile() -> URL? {
        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let logDir = supportDir.appendingPathComponent("XianRenZhiLu/Logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        let fileURL = logDir.appendingPathComponent("module_load_log.json")
        
        lock.lock()
        let data = try? JSONEncoder().encode(logs)
        lock.unlock()
        
        try? data?.write(to: fileURL)
        return fileURL
    }
    
    // MARK: - 私有方法
    private func append(_ entry: ModuleLoadLogEntry) {
        lock.lock()
        logs.append(entry)
        lock.unlock()
    }
}

// MARK: - 统计结构
public struct ModuleLoadStats {
    public let totalAttempts: Int
    public let successfulLoads: Int
    public let failedLoads: Int
    public let averageLoadTime: TimeInterval
    
    public var successRate: Double {
        return Double(successfulLoads) / Double(max(totalAttempts, 1))
    }
}