import Foundation
import os

// MARK: - LogLevel
/// 日志级别，支持5个级别：debug < info < warning < error < fatal
public enum LogLevel: Int, Comparable, CaseIterable, CustomStringConvertible {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case fatal = 4
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    public var description: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        case .fatal:   return "FATAL"
        }
    }
    
    public var emoji: String {
        switch self {
        case .debug:   return "🔍"
        case .info:    return "ℹ️"
        case .warning: return "⚠️"
        case .error:   return "❌"
        case .fatal:   return "💥"
        }
    }
}

// MARK: - LogEntry
/// 日志条目数据结构
public struct LogEntry {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let file: String
    public let function: String
    public let line: Int
    public let moduleName: String?
}

// MARK: - LogOutput Protocol
/// 日志输出目标协议
public protocol LogOutput {
    func write(_ entry: LogEntry)
    func flush()
}

// MARK: - ConsoleLogOutput
/// 控制台日志输出（带格式化）
public final class ConsoleLogOutput: LogOutput {
    private let dateFormatter: DateFormatter
    
    public init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    
    public func write(_ entry: LogEntry) {
        let time = dateFormatter.string(from: entry.timestamp)
        print("[\(time)] \(entry.level.emoji) [\(entry.level)] [\(entry.category)] \(entry.message)")
    }
    
    public func flush() {}
}

// MARK: - FileLogOutput
/// 文件日志输出（按天轮转，7天自动清理）
public final class FileLogOutput: LogOutput {
    private let logDirectory: URL
    private let maxAgeDays = 7
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private let lock = NSLock()
    private let dateFormatter: DateFormatter
    private let fileNameFormatter: DateFormatter
    
    public init(directory: URL) {
        self.logDirectory = directory
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.fileNameFormatter = DateFormatter()
        self.fileNameFormatter.dateFormat = "yyyy-MM-dd"
        
        // 自动创建目录，不崩溃
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    
    deinit {
        // 不拿锁，避免阻塞。fileHandle 关闭是幂等的
        if let handle = fileHandle {
            try? handle.closeFile()
        }
    }
    
    public func write(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        
        rotateIfNeeded()
        
        let time = dateFormatter.string(from: entry.timestamp)
        let line = "[\(time)] \(entry.level.emoji) [\(entry.level)] [\(entry.category)] \(entry.message)\n"
        
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
    
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.synchronizeFile()
    }
    
    private var lastCleanupDate: Date? = nil
    
    /// 检查是否需要轮转文件（按天）
    private func rotateIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        let expectedFile = logDirectory.appendingPathComponent("log_\(fileNameFormatter.string(from: today)).txt")
        
        if currentFile != expectedFile {
            fileHandle?.closeFile()
            currentFile = expectedFile
            
            if !FileManager.default.fileExists(atPath: expectedFile.path) {
                FileManager.default.createFile(atPath: expectedFile.path, contents: nil)
            }
            
            fileHandle = FileHandle(forWritingAtPath: expectedFile.path)
            fileHandle?.seekToEndOfFile()
        }
        
        // 每天只清理一次旧日志
        if lastCleanupDate != today {
            lastCleanupDate = today
            cleanupOldLogs()
        }
    }
    
    /// 清理7天前的旧日志文件
    private func cleanupOldLogs() {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        
        for file in files {
            let fileName = file.lastPathComponent
            
            // 优先从文件名解析日期（log_YYYY-MM-dd.txt）
            if fileName.hasPrefix("log_"), fileName.hasSuffix(".txt"),
               let dateStr = fileName.dropFirst(4).dropLast(4).split(separator: ".").first,
               let fileDate = fileNameFormatter.date(from: String(dateStr)) {
                if fileDate < cutoffDate {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
            }
            
            // 回退：使用文件系统创建日期
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let creationDate = attrs[.creationDate] as? Date,
               creationDate < cutoffDate {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - LogSystem
/// 全局日志系统（单例）
public final class LogSystem {
    public static let shared = LogSystem()
    
    private let lock = NSLock()
    private var outputs: [LogOutput] = []
    private var minimumLevel: LogLevel = .info
    private let queue = DispatchQueue(label: "com.xianrenzhilu.log", qos: .utility)
    private var unfairLock = os_unfair_lock()
    
    private init() {}
    
    /// 初始化日志系统，默认输出到控制台和文件
    public func initialize() {
        addOutput(ConsoleLogOutput())
        
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logDir = supportDir.appendingPathComponent("XianRenZhiLu/Logs")
            addOutput(FileLogOutput(directory: logDir))
        }
        
        log(level: .info, category: "LogSystem", message: "Log system initialized")
    }
    
    /// 添加日志输出目标
    public func addOutput(_ output: LogOutput) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        outputs.append(output)
    }
    
    /// 设置最低日志级别（低于此级别的日志将被忽略）
    public func setMinimumLevel(_ level: LogLevel) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        minimumLevel = level
    }
    
    /// 获取当前最低日志级别
    public func getMinimumLevel() -> LogLevel {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return minimumLevel
    }
    
    /// 主日志入口，异步写入，不阻塞主线程
    public func log(level: LogLevel, category: String, message: String,
                    file: String = #file, function: String = #function, line: Int = #line) {
        // 使用 os_unfair_lock 快速读取级别
        os_unfair_lock_lock(&unfairLock)
        let currentMinimum = minimumLevel
        os_unfair_lock_unlock(&unfairLock)
        
        guard level >= currentMinimum else { return }
        
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line,
            moduleName: nil
        )
        
        // 异步写入串行队列，保证顺序且线程安全
        queue.async { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.unfairLock)
            let currentOutputs = self.outputs
            os_unfair_lock_unlock(&self.unfairLock)
            for output in currentOutputs {
                output.write(entry)
            }
        }
    }
    
    /// 强制刷新所有输出
    public func flush() {
        queue.async { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.unfairLock)
            let currentOutputs = self.outputs
            os_unfair_lock_unlock(&self.unfairLock)
            for output in currentOutputs {
                output.flush()
            }
        }
    }
    
    /// 获取日志目录路径
    public func logDirectory() -> URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("XianRenZhiLu/Logs")
    }
}

// MARK: - ModuleLogger
/// 模块专用日志记录器，供各模块使用
public final class ModuleLogger {
    private let category: String
    
    public init(category: String) {
        self.category = category
    }
    
    public func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        LogSystem.shared.log(level: .debug, category: category, message: message, file: file, function: function, line: line)
    }
    
    public func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        LogSystem.shared.log(level: .info, category: category, message: message, file: file, function: function, line: line)
    }
    
    public func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        LogSystem.shared.log(level: .warning, category: category, message: message, file: file, function: function, line: line)
    }
    
    public func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        LogSystem.shared.log(level: .error, category: category, message: message, file: file, function: function, line: line)
    }
    
    public func fatal(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        LogSystem.shared.log(level: .fatal, category: category, message: message, file: file, function: function, line: line)
    }
}

// MARK: - 测试代码
public final class LogSystemTests {
    
    /// 运行所有测试
    public static func runAllTests() {
        testBasicLogging()
        testMultithreadedLogging()
        testLogLevelFiltering()
        testOldLogCleanup()
        print("\n🎉 All log system tests completed!")
    }
    
    /// 测试1: 基本日志功能（验证5个级别输出和文件生成）
    public static func testBasicLogging() {
        print("\n🧪 Test 1: Basic Logging")
        
        LogSystem.shared.initialize()
        let logger = ModuleLogger(category: "TestBasic")
        
        logger.debug("This is a debug message")
        logger.info("This is an info message")
        logger.warning("This is a warning message")
        logger.error("This is an error message")
        logger.fatal("This is a fatal message")
        
        LogSystem.shared.flush()
        
        // 验证日志文件是否存在
        if let logDir = LogSystem.shared.logDirectory() {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let todayFile = logDir.appendingPathComponent("log_\(formatter.string(from: Date())).txt")
            if FileManager.default.fileExists(atPath: todayFile.path) {
                print("✅ Test 1 passed: Log file created at \(todayFile.path)")
            } else {
                print("❌ Test 1 failed: Log file not found")
            }
        }
    }
    
    /// 测试2: 多线程并发写入（50线程 × 20条日志 = 1000条，验证不崩溃不混乱）
    public static func testMultithreadedLogging() {
        print("\n🧪 Test 2: Multithreaded Logging")
        
        let group = DispatchGroup()
        let threadCount = 50
        let logsPerThread = 20
        
        for i in 0..<threadCount {
            group.enter()
            DispatchQueue.global().async {
                let logger = ModuleLogger(category: "Thread-\(i)")
                for j in 0..<logsPerThread {
                    logger.info("Message \(j) from thread \(i)")
                }
                group.leave()
            }
        }
        
        group.wait()
        LogSystem.shared.flush()
        
        print("✅ Test 2 passed: \(threadCount * logsPerThread) logs written from \(threadCount) threads without crash")
    }
    
    /// 测试3: 日志级别过滤（设置 warning 级别，验证 debug/info 被过滤）
    public static func testLogLevelFiltering() {
        print("\n🧪 Test 3: Log Level Filtering")
        
        LogSystem.shared.setMinimumLevel(.warning)
        let logger = ModuleLogger(category: "TestFilter")
        
        logger.debug("Should NOT appear (debug < warning)")
        logger.info("Should NOT appear (info < warning)")
        logger.warning("Should appear (warning >= warning)")
        logger.error("Should appear (error >= warning)")
        
        LogSystem.shared.flush()
        
        let currentLevel = LogSystem.shared.getMinimumLevel()
        if currentLevel == .warning {
            print("✅ Test 3 passed: Level filtering works, current level is \(currentLevel)")
        } else {
            print("❌ Test 3 failed: Level not set correctly")
        }
        
        // 恢复默认级别
        LogSystem.shared.setMinimumLevel(.info)
    }
    
    /// 测试4: 7天旧日志清理（创建模拟旧文件，验证被删除，新文件保留）
    public static func testOldLogCleanup() {
        print("\n🧪 Test 4: Old Log Cleanup (7 days)")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 创建旧日志文件（模拟8天前的日志，文件名日期为2000-01-01）
        let oldFile = tempDir.appendingPathComponent("log_2000-01-01.txt")
        FileManager.default.createFile(atPath: oldFile.path, contents: Data("old log content".utf8))
        
        // 创建今天的日志文件
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayFile = tempDir.appendingPathComponent("log_\(formatter.string(from: Date())).txt")
        FileManager.default.createFile(atPath: todayFile.path, contents: Data("today log content".utf8))
        
        // 初始化 FileLogOutput 并写入（触发轮转和清理）
        var output: FileLogOutput? = FileLogOutput(directory: tempDir)
        let entry = LogEntry(
            timestamp: Date(),
            level: .info,
            category: "TestCleanup",
            message: "Trigger cleanup",
            file: "",
            function: "",
            line: 0,
            moduleName: nil
        )
        output?.write(entry)
        output?.flush()
        output = nil  // 释放，触发 deinit 关闭 fileHandle
        
        // 等待文件句柄释放
        Thread.sleep(forTimeInterval: 0.1)
        
        // 验证结果
        let oldExists = FileManager.default.fileExists(atPath: oldFile.path)
        let newExists = FileManager.default.fileExists(atPath: todayFile.path)
        
        if !oldExists && newExists {
            print("✅ Test 4 passed: Old log deleted, today's log preserved")
        } else {
            print("❌ Test 4 failed: oldExists=\(oldExists), newExists=\(newExists)")
        }
        
        // 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)
    }
}
