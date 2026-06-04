import Foundation

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
        #if canImport(仙人指路)
        let unloader = ModuleUnloader(registry: ModuleRegistry.shared, eventBus: EventBus.shared)
        let unloadResult = unloader.forceUnload(name: moduleName)
        log("卸载模块 \(moduleName): \(unloadResult ? "成功" : "失败")")
        #endif
        return true
    }
    
    private func log(_ message: String) {
        #if DEBUG
        print("[ModuleHotReloader] \(message)")
        #endif
    }
}

// MARK: - 测试

#if DEBUG
/// 测试替身代理
class TestHotReloadDelegate: ModuleHotReloaderDelegate {
    var shouldSucceed: Bool = true
    var reloadCount: Int = 0
    var compileCount: Int = 0
    
    func performHotReload(moduleName: String) -> Bool {
        reloadCount += 1
        return shouldSucceed
    }
    
    func compileModule(moduleName: String, sourceDirectory: URL) -> URL? {
        compileCount += 1
        return nil
    }
}

/// 模块热重载器测试套件
class ModuleHotReloaderTests {
    private var reloader: ModuleHotReloader!
    private var delegate: TestHotReloadDelegate!
    
    init() {
        reloader = ModuleHotReloader.shared
        delegate = TestHotReloadDelegate()
        reloader.delegate = delegate
        reloader.isDevelopmentMode = true
        reloader.autoReload = true
        reloader.clearHistory()
        reloader.stopAllWatching()
    }
    
    /// 运行全部测试
    func runAllTests() {
        testHotReloadSuccess()
        testHotReloadFailure()
        testStartWatching()
        testStopWatching()
        testHistoryRecords()
        testAutoReloadProperty()
        testClearHistory()
        print("✅ 模块热重载测试全部通过")
    }
    
    // 测试1: 热重载成功
    private func testHotReloadSuccess() {
        delegate.shouldSucceed = true
        delegate.reloadCount = 0
        let result = reloader.hotReload(moduleName: "SuccessModule")
        assert(result == true, "热重载应返回成功")
        assert(delegate.reloadCount == 1, "代理应被调用一次")
    }
    
    // 测试2: 热重载失败
    private func testHotReloadFailure() {
        delegate.shouldSucceed = false
        let result = reloader.hotReload(moduleName: "FailModule")
        assert(result == false, "热重载应返回失败")
        let history = reloader.reloadHistory
        assert(history.last?.success == false, "历史记录应标记失败")
        assert(history.last?.error != nil, "失败记录应包含错误信息")
    }
    
    // 测试3: 开始监视
    private func testStartWatching() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let result = reloader.startWatching(moduleName: "WatchModule", directoryURL: tempDir)
        assert(result == true, "开始监视应成功")
        assert(reloader.watchedModules.contains("WatchModule"), "watchedModules 应包含 WatchModule")
        
        reloader.stopWatching(moduleName: "WatchModule")
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // 测试4: 停止监视
    private func testStopWatching() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        reloader.startWatching(moduleName: "StopModule", directoryURL: tempDir)
        let result = reloader.stopWatching(moduleName: "StopModule")
        assert(result == true, "停止监视应成功")
        assert(!reloader.watchedModules.contains("StopModule"), "watchedModules 不应包含 StopModule")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // 测试5: 历史记录
    private func testHistoryRecords() {
        let countBefore = reloader.reloadHistory.count
        delegate.shouldSucceed = true
        _ = reloader.hotReload(moduleName: "HistoryModule")
        let history = reloader.reloadHistory
        assert(history.count == countBefore + 1, "历史记录应增加一条")
        assert(history.last?.moduleName == "HistoryModule", "模块名应正确")
        assert(history.last?.success == true, "成功记录应标记成功")
    }
    
    // 测试6: 自动重载属性
    private func testAutoReloadProperty() {
        reloader.autoReload = false
        assert(reloader.autoReload == false, "autoReload 应可设置为 false")
        reloader.autoReload = true
        assert(reloader.autoReload == true, "autoReload 应可设置为 true")
    }
    
    // 测试7: 清空历史
    private func testClearHistory() {
        _ = reloader.hotReload(moduleName: "ClearModule")
        reloader.clearHistory()
        assert(reloader.reloadHistory.isEmpty, "历史记录应被清空")
    }
}
#endif
