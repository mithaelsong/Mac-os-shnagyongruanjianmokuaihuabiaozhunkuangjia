import Foundation
import os

// MARK: - 热重载记录

/// 单次热重载记录
public struct ReloadRecord: CustomStringConvertible, Sendable {
    public let moduleName: String
    public let timestamp: Date
    public let success: Bool
    public let error: String?
    
    public var description: String {
        let fmt = ISO8601DateFormatter()
        let time = fmt.string(from: timestamp)
        let status = success ? "✅" : "❌"
        return "\(status) [\(time)] \(moduleName)" + (error != nil ? " — \(error!)" : "")
    }
}

// MARK: - 代理协议

/// 热重载代理：由宿主提供实际加载/卸载能力
public protocol ModuleHotReloaderDelegate: AnyObject, Sendable {
    /// 执行模块重载，返回是否成功
    func performHotReload(moduleName: String) -> Bool
    /// 可选：编译模块，返回编译产物路径
    func compileModule(moduleName: String, sourceDirectory: URL) -> URL?
}

// 提供默认实现
extension ModuleHotReloaderDelegate {
    public func compileModule(moduleName: String, sourceDirectory: URL) -> URL? {
        return nil
    }
}

// MARK: - 模块热重载器

/// 模块热重载管理器（功能28）
/// 开发模式下监视模块文件变化，自动或手动触发重载
public final class ModuleHotReloader {
    
    // MARK: - 单例
    
    public static let shared = ModuleHotReloader()
    
    // MARK: - 属性
    
    /// 是否开启自动重载（文件变化时自动触发）
    public var autoReload: Bool = true
    
    /// 开发模式开关（非开发模式时所有操作返回 false）
    public var isDevelopmentMode: Bool = true
    
    /// 代理对象，提供实际加载/卸载能力
    public weak var delegate: ModuleHotReloaderDelegate?
    
    /// 当前正在监视的模块名列表
    public var watchedModules: [String] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return Array(_watchedModules.keys)
    }
    
    /// 热重载历史记录
    public var reloadHistory: [ReloadRecord] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _history
    }
    
    // MARK: - 私有状态
    
    private var _watchedModules: [String: URL] = [:]
    private var _sources: [String: DispatchSourceFileSystemObject] = [:]
    private var _history: [ReloadRecord] = []
    private var _lock: os_unfair_lock = .init()
    
    // MARK: - 初始化
    
    private init() {}
    
    // MARK: - 监视控制
    
    /// 开始监视指定模块的目录变化
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - directoryURL: 模块所在目录
    /// - Returns: 是否成功开始监视
    @discardableResult
    public func startWatching(moduleName: String, directoryURL: URL) -> Bool {
        guard isDevelopmentMode else {
            log("热重载仅在开发模式可用")
            return false
        }
        
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        
        guard _sources[moduleName] == nil else {
            log("模块 \(moduleName) 已在监视中")
            return false
        }
        
        let path = directoryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log("无法打开目录进行监视: \(path)")
            return false
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.autoReload {
                _ = self.hotReload(moduleName: moduleName)
            } else {
                self.log("检测到 \(moduleName) 文件变化，自动重载已关闭")
            }
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        _sources[moduleName] = source
        _watchedModules[moduleName] = directoryURL
        log("开始监视模块 \(moduleName): \(path)")
        return true
    }
    
    /// 停止监视指定模块
    /// - Parameter moduleName: 模块名称
    /// - Returns: 是否成功停止
    @discardableResult
    public func stopWatching(moduleName: String) -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        
        guard let source = _sources.removeValue(forKey: moduleName) else {
            log("模块 \(moduleName) 未在监视中")
            return false
        }
        
        source.cancel()
        _watchedModules.removeValue(forKey: moduleName)
        log("停止监视模块 \(moduleName)")
        return true
    }
    
    /// 停止所有监视
    public func stopAllWatching() {
        os_unfair_lock_lock(&_lock)
        let modules = Array(_watchedModules.keys)
        os_unfair_lock_unlock(&_lock)
        
        for module in modules {
            stopWatching(moduleName: module)
        }
    }
    
    // MARK: - 热重载
    
    /// 手动热重载指定模块
    /// - Parameter moduleName: 模块名称
    /// - Returns: 重载是否成功
    @discardableResult
    public func hotReload(moduleName: String) -> Bool {
        guard isDevelopmentMode else {
            log("热重载仅在开发模式可用")
            record(moduleName: moduleName, success: false, error: "非开发模式")
            return false
        }
        
        os_unfair_lock_lock(&_lock)
        let hasWatched = _watchedModules[moduleName] != nil
        os_unfair_lock_unlock(&_lock)
        
        guard hasWatched || delegate != nil else {
            log("模块 \(moduleName) 未在监视中且未设置代理")
            record(moduleName: moduleName, success: false, error: "模块未在监视中")
            return false
        }
        
        log("正在热重载模块 \(moduleName)...")
        
        var success = false
        var errorMsg: String? = nil
        
        if let delegate = delegate {
            if let sourceDir = _watchedModules[moduleName] {
                _ = delegate.compileModule(moduleName: moduleName, sourceDirectory: sourceDir)
            }
            success = delegate.performHotReload(moduleName: moduleName)
            if !success {
                errorMsg = "代理重载失败"
            }
        } else {
            success = performDefaultReload(moduleName: moduleName)
            if !success {
                errorMsg = "默认重载流程失败"
            }
        }
        
        record(moduleName: moduleName, success: success, error: errorMsg)
        log("模块 \(moduleName) 热重载\(success ? "成功" : "失败")")
        return success
    }
    
    // MARK: - 历史管理
    
    /// 清空热重载历史
    public func clearHistory() {
        os_unfair_lock_lock(&_lock)
        _history.removeAll()
        os_unfair_lock_unlock(&_lock)
    }
    
    // MARK: - 私有方法
    
    private func record(moduleName: String, success: Bool, error: String? = nil) {
        let record = ReloadRecord(
            moduleName: moduleName,
            timestamp: Date(),
            success: success,
            error: error
        )
        os_unfair_lock_lock(&_lock)
        _history.append(record)
        os_unfair_lock_unlock(&_lock)
    }
    
    /// 默认重载流程（兼容项目已有架构）
    private func performDefaultReload(moduleName: String) -> Bool {
        // 默认重载流程：由delegate提供实际能力
        return false
    }
    
    private func log(_ message: String) {
        print("[ModuleHotReloader] \(message)")
    }
}

// MARK: - 测试代码
/// 模块热重载器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ModuleHotReloaderTests.run()`
public enum ModuleHotReloaderTests {

    /// 运行所有测试
    public static func run() {
        let reloader = ModuleHotReloader.shared
        let delegate = TestHotReloadDelegate()
        reloader.delegate = delegate
        reloader.isDevelopmentMode = true
        reloader.autoReload = true
        reloader.clearHistory()
        reloader.stopAllWatching()

        print("=== 模块热重载测试 ===")
        testHotReloadSuccess(reloader: reloader, delegate: delegate)
        testHotReloadFailure(reloader: reloader, delegate: delegate)
        testStartWatching(reloader: reloader)
        testStopWatching(reloader: reloader)
        testHistoryRecords(reloader: reloader, delegate: delegate)
        testAutoReloadProperty(reloader: reloader)
        testClearHistory(reloader: reloader, delegate: delegate)
        print("\n=== 全部模块热重载测试通过 ✅ ===")
    }

    // MARK: - 测试1: 热重载成功
    static func testHotReloadSuccess(reloader: ModuleHotReloader, delegate: TestHotReloadDelegate) {
        print("\n🧪 测试1: 热重载成功")
        delegate.shouldSucceed = true
        delegate.reloadCount = 0
        let result = reloader.hotReload(moduleName: "SuccessModule")
        guard result == true else { fatalError("❌ 测试1失败: 热重载应返回成功") }
        guard delegate.reloadCount == 1 else { fatalError("❌ 测试1失败: 代理应被调用一次") }
        print("✅ 测试1通过: 热重载成功")
    }

    // MARK: - 测试2: 热重载失败
    static func testHotReloadFailure(reloader: ModuleHotReloader, delegate: TestHotReloadDelegate) {
        print("\n🧪 测试2: 热重载失败")
        delegate.shouldSucceed = false
        let result = reloader.hotReload(moduleName: "FailModule")
        guard result == false else { fatalError("❌ 测试2失败: 热重载应返回失败") }
        let history = reloader.reloadHistory
        guard history.last?.success == false else { fatalError("❌ 测试2失败: 历史记录应标记失败") }
        guard history.last?.error != nil else { fatalError("❌ 测试2失败: 失败记录应包含错误信息") }
        print("✅ 测试2通过: 热重载失败")
    }

    // MARK: - 测试3: 开始监视
    static func testStartWatching(reloader: ModuleHotReloader) {
        print("\n🧪 测试3: 开始监视")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let result = reloader.startWatching(moduleName: "WatchModule", directoryURL: tempDir)
        guard result == true else { try? FileManager.default.removeItem(at: tempDir); fatalError("❌ 测试3失败: 开始监视应成功") }
        guard reloader.watchedModules.contains("WatchModule") else { try? FileManager.default.removeItem(at: tempDir); fatalError("❌ 测试3失败: watchedModules应包含WatchModule") }
        reloader.stopWatching(moduleName: "WatchModule")
        try? FileManager.default.removeItem(at: tempDir)
        print("✅ 测试3通过: 开始监视正确")
    }

    // MARK: - 测试4: 停止监视
    static func testStopWatching(reloader: ModuleHotReloader) {
        print("\n🧪 测试4: 停止监视")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        reloader.startWatching(moduleName: "StopModule", directoryURL: tempDir)
        let result = reloader.stopWatching(moduleName: "StopModule")
        guard result == true else { try? FileManager.default.removeItem(at: tempDir); fatalError("❌ 测试4失败: 停止监视应成功") }
        guard !reloader.watchedModules.contains("StopModule") else { try? FileManager.default.removeItem(at: tempDir); fatalError("❌ 测试4失败: watchedModules不应包含StopModule") }
        try? FileManager.default.removeItem(at: tempDir)
        print("✅ 测试4通过: 停止监视正确")
    }

    // MARK: - 测试5: 历史记录
    static func testHistoryRecords(reloader: ModuleHotReloader, delegate: TestHotReloadDelegate) {
        print("\n🧪 测试5: 历史记录")
        let countBefore = reloader.reloadHistory.count
        delegate.shouldSucceed = true
        _ = reloader.hotReload(moduleName: "HistoryModule")
        let history = reloader.reloadHistory
        guard history.count == countBefore + 1 else { fatalError("❌ 测试5失败: 历史记录应增加一条") }
        guard history.last?.moduleName == "HistoryModule" else { fatalError("❌ 测试5失败: 模块名应正确") }
        guard history.last?.success == true else { fatalError("❌ 测试5失败: 成功记录应标记成功") }
        print("✅ 测试5通过: 历史记录正确")
    }

    // MARK: - 测试6: 自动重载属性
    static func testAutoReloadProperty(reloader: ModuleHotReloader) {
        print("\n🧪 测试6: 自动重载属性")
        reloader.autoReload = false
        guard reloader.autoReload == false else { fatalError("❌ 测试6失败: autoReload应可设置为false") }
        reloader.autoReload = true
        guard reloader.autoReload == true else { fatalError("❌ 测试6失败: autoReload应可设置为true") }
        print("✅ 测试6通过: 自动重载属性正确")
    }

    // MARK: - 测试7: 清空历史
    static func testClearHistory(reloader: ModuleHotReloader, delegate: TestHotReloadDelegate) {
        print("\n🧪 测试7: 清空历史")
        _ = reloader.hotReload(moduleName: "ClearModule")
        reloader.clearHistory()
        guard reloader.reloadHistory.isEmpty else { fatalError("❌ 测试7失败: 历史记录应被清空") }
        print("✅ 测试7通过: 清空历史正确")
    }
}

/// 测试替身代理
public class TestHotReloadDelegate: ModuleHotReloaderDelegate {
    public var shouldSucceed: Bool = true
    public var reloadCount: Int = 0
    public var compileCount: Int = 0

    public init() {}

    public func performHotReload(moduleName: String) -> Bool {
        reloadCount += 1
        return shouldSucceed
    }

    public func compileModule(moduleName: String, sourceDirectory: URL) -> URL? {
        compileCount += 1
        return nil
    }
}f
