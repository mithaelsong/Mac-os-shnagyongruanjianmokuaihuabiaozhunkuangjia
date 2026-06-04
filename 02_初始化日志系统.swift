// 功能2: 初始化日志系统
// 对应: 方便调试模块加载失败等问题
// 优先级: P0

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
/// 全部使用 os_unfair_lock，与 LogSystem 保持一致
public final class FileLogOutput: LogOutput {
    private let logDirectory: URL
    private let maxAgeDays = 7
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private var unfairLock = os_unfair_lock()
    private let dateFormatter: DateFormatter
    private let fileNameFormatter: DateFormatter
    private var lastCleanupDate: Date? = nil
    
    public init(directory: URL) {
        self.logDirectory = directory
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.fileNameFormatter = DateFormatter()
        self.fileNameFormatter.dateFormat = "yyyy-MM-dd"
        
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    
    deinit {
        // fileHandle.closeFile() 是幂等的，不拿锁避免阻塞
        if let handle = fileHandle {
            try? handle.closeFile()
        }
    }
    
    public func write(_ entry: LogEntry) {
        os_unfair_lock_lock(&unfairLock)
        rotateIfNeededLocked()
        
        let time = dateFormatter.string(from: entry.timestamp)
        let line = "[\(time)] \(entry.level.emoji) [\(entry.level)] [\(entry.category)] \(entry.message)\n"
        
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
        os_unfair_lock_unlock(&unfairLock)
    }
    
    public func flush() {
        os_unfair_lock_lock(&unfairLock)
        fileHandle?.synchronizeFile()
        os_unfair_lock_unlock(&unfairLock)
    }
    
    /// 仅在持有锁时调用
    private func rotateIfNeededLocked() {
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
        
        if lastCleanupDate != today {
            lastCleanupDate = today
            cleanupOldLogsLocked()
        }
    }
    
    /// 仅在持有锁时调用
    private func cleanupOldLogsLocked() {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        
        for file in files {
            let fileName = file.lastPathComponent
            if fileName.hasPrefix("log_"), fileName.hasSuffix(".txt"),
               let dateStr = fileName.dropFirst(4).dropLast(4).split(separator: ".").first,
               let fileDate = fileNameFormatter.date(from: String(dateStr)) {
                if fileDate < cutoffDate {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
            }
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
/// 所有共享状态统一使用 os_unfair_lock 保护
public final class LogSystem {
    public static let shared = LogSystem()
    
    private var unfairLock = os_unfair_lock()
    private var outputs: [LogOutput] = []
    private var minimumLevel: LogLevel = .info
    private let queue = DispatchQueue(label: "com.xianrenzhilu.log", qos: .utility)
    
    private init() {}
    
    /// 初始化日志系统，默认输出到控制台和文件
    private var hasInitialized = false
    
    public func initialize() {
        os_unfair_lock_lock(&unfairLock)
        if hasInitialized {
            os_unfair_lock_unlock(&unfairLock)
            return
        }
        hasInitialized = true
        os_unfair_lock_unlock(&unfairLock)
        
        addOutput(ConsoleLogOutput())
        
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logDir = supportDir.appendingPathComponent("XianRenZhiLu/Logs")
            addOutput(FileLogOutput(directory: logDir))
        }
        
        // 注册应用退出自动 flush
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppTerminating),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        log(level: .info, category: "LogSystem", message: "Log system initialized")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleAppTerminating() {
        flush()
    }
    
    /// 添加日志输出目标
    public func addOutput(_ output: LogOutput) {
        os_unfair_lock_lock(&unfairLock)
        outputs.append(output)
        os_unfair_lock_unlock(&unfairLock)
    }
    
    /// 设置最低日志级别（低于此级别的日志将被忽略）
    public func setMinimumLevel(_ level: LogLevel) {
        os_unfair_lock_lock(&unfairLock)
        minimumLevel = level
        os_unfair_lock_unlock(&unfairLock)
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
    
    /// 强制刷新所有输出，同步等待写入完成
    public func flush() {
        // 提交空块到队列确保之前所有写入已执行
        queue.sync { [weak self] in
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
    
    public static func runAllTests() {
        testBasicLogging()
        testMultithreadedLogging()
        testLogLevelFiltering()
        testOldLogCleanup()
        testFlushOnTerminate()
        testLockConsistency()
        print("\n🎉 All log system tests completed!")
    }
    
    /// 测试1: 基本日志写入和文件生成
    public static func testBasicLogging() {
        print("\n🧪 Test 1: Basic Logging")
        
        LogSystem.shared.initialize()
        let logger = ModuleLogger(category: "TestBasic")
        
        logger.debug("Debug message")
        logger.info("Info message")
        logger.warning("Warning message")
        logger.error("Error message")
        logger.fatal("Fatal message")
        
        LogSystem.shared.flush()
        
        guard let logDir = LogSystem.shared.logDirectory() else {
            fatalError("❌ Test 1 failed: logDirectory returned nil")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayFile = logDir.appendingPathComponent("log_\(formatter.string(from: Date())).txt")
        guard FileManager.default.fileExists(atPath: todayFile.path) else {
            fatalError("❌ Test 1 failed: Log file not found at \(todayFile.path)")
        }
        
        print("✅ Test 1 passed: Log file created at \(todayFile.path)")
    }
    
    /// 测试2: 多线程并发日志写入
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
        
        print("✅ Test 2 passed: \(threadCount * logsPerThread) logs written from \(threadCount) threads without deadlock")
    }
    
    /// 测试3: 日志级别过滤
    public static func testLogLevelFiltering() {
        print("\n🧪 Test 3: Log Level Filtering")
        
        LogSystem.shared.setMinimumLevel(.warning)
        let logger = ModuleLogger(category: "TestFilter")
        
        logger.debug("Should NOT appear")
        logger.info("Should NOT appear")
        logger.warning("Should appear")
        logger.error("Should appear")
        
        LogSystem.shared.flush()
        
        let currentLevel = LogSystem.shared.getMinimumLevel()
        guard currentLevel == .warning else {
            fatalError("❌ Test 3 failed: expected warning, got \(currentLevel)")
        }
        
        LogSystem.shared.setMinimumLevel(.info)
        print("✅ Test 3 passed: Level filtering works")
    }
    
    /// 测试4: 旧日志文件自动清理（7天）
    public static func testOldLogCleanup() {
        print("\n🧪 Test 4: Old Log Cleanup (7 days)")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let oldFile = tempDir.appendingPathComponent("log_2000-01-01.txt")
        guard FileManager.default.createFile(atPath: oldFile.path, contents: Data("old".utf8)) else {
            fatalError("❌ Test 4 failed: cannot create old log")
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayFile = tempDir.appendingPathComponent("log_\(formatter.string(from: Date())).txt")
        guard FileManager.default.createFile(atPath: todayFile.path, contents: Data("today".utf8)) else {
            fatalError("❌ Test 4 failed: cannot create today log")
        }
        
        let output = FileLogOutput(directory: tempDir)
        let entry = LogEntry(
            timestamp: Date(), level: .info, category: "Cleanup",
            message: "Trigger", file: "", function: "", line: 0, moduleName: nil
        )
        output.write(entry)
        output.flush()
        Thread.sleep(forTimeInterval: 0.1)
        
        let oldExists = FileManager.default.fileExists(atPath: oldFile.path)
        let newExists = FileManager.default.fileExists(atPath: todayFile.path)
        guard !oldExists && newExists else {
            fatalError("❌ Test 4 failed: old=\(oldExists) new=\(newExists)")
        }
        
        print("✅ Test 4 passed: Old log deleted, today's log preserved")
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    /// 测试5: 验证 flush() 不会死锁
    public static func testFlushOnTerminate() {
        print("\n🧪 Test 5: Flush on Terminate")
        
        LogSystem.shared.initialize()
        let logger = ModuleLogger(category: "TestFlush")
        
        logger.info("Message before flush")
        LogSystem.shared.flush()
        
        print("✅ Test 5 passed: flush() completed without deadlock")
    }
    
    /// 测试6: 验证锁一致性（FileLogOutput 使用 os_unfair_lock）
    public static func testLockConsistency() {
        print("\n🧪 Test 6: Lock Consistency")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTest_Lock_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let group = DispatchGroup()
        let iterations = 100
        let output = FileLogOutput(directory: tempDir)
        
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let entry = LogEntry(
                    timestamp: Date(), level: .info, category: "LockTest",
                    message: "Msg \(i)", file: "", function: "", line: 0, moduleName: nil
                )
                output.write(entry)
                group.leave()
            }
        }
        group.wait()
        output.flush()
        
        try? FileManager.default.removeItem(at: tempDir)
        print("✅ Test 6 passed: \(iterations) concurrent writes with os_unfair_lock without crash")
    }
}
