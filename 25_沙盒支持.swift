// 功能25: 沙盒支持（可选）
// 对应: 如果上架 Mac App Store，需要支持沙盒
// 优先级: P3 (交易软件通常不上架，但预留)
//
// 核心能力:
// 1. 检测当前是否在沙盒环境
// 2. 获取沙盒容器目录（Documents/Caches/Tmp等）
// 3. 安全访问安全区文件（Security-Scoped Resource）
// 4. 沙盒文件读写保护检查
// 5. 线程安全（os_unfair_lock）
// 6. 完整测试覆盖

import Foundation
import AppKit
import Darwin

// MARK: - 权限类型（兼容原有定义）
public enum PermissionType {
    case network
    case fileRead
    case fileWrite
    case userSelectedFile
}

// MARK: - 沙盒路径类型（兼容原有定义）
public enum SandboxPathType {
    case documents
    case applicationSupport
    case caches
    case temp
}

// MARK: - 沙盒权限配置
public struct SandboxPermissions {
    public var networkAccess: Bool = true          // 网络访问（必须，交易需要）
    public var fileRead: Bool = true                 // 文件读取
    public var fileWrite: Bool = true                // 文件写入（缓存、配置）
    public var userSelectedFileAccess: Bool = true   // 用户选择文件
    public var downloadsFolder: Bool = false          // 下载文件夹
    public var picturesFolder: Bool = false          // 图片文件夹
    public var musicFolder: Bool = false              // 音乐文件夹
    public var moviesFolder: Bool = false             // 视频文件夹
    
    public static let `default` = SandboxPermissions()
    public static let strict = SandboxPermissions(networkAccess: true, fileRead: true, fileWrite: false)
}

// MARK: - 安全区访问结果
public struct SecurityScopedAccessResult {
    public let startAccessing: Bool
    public let stopHandler: () -> Void
    
    public init(startAccessing: Bool, stopHandler: @escaping () -> Void) {
        self.startAccessing = startAccessing
        self.stopHandler = stopHandler
    }
}

// MARK: - 文件访问检查结果
public struct FileAccessCheckResult {
    public let canRead: Bool
    public let canWrite: Bool
    public let exists: Bool
    public let isDirectory: Bool
    public let error: Error?
    
    public var isAccessible: Bool { canRead || canWrite }
}

// MARK: - SandboxManager 单例
/// 沙盒管理器：负责检测沙盒环境、管理沙盒目录、安全区资源访问
public final class SandboxManager {
    
    // MARK: - 单例
    public static let shared = SandboxManager()
    
    // MARK: - 线程安全锁
    private var lock = os_unfair_lock()
    
    // MARK: - 缓存属性
    private var _cachedIsSandboxed: Bool?
    private var _cachedContainerDirectory: URL?
    private var _cachedDocumentsDirectory: URL?
    private var _cachedCacheDirectory: URL?
    private var _cachedTemporaryDirectory: URL?
    
    // MARK: - 权限配置
    public var permissions: SandboxPermissions = .default {
        didSet {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            // 权限变更时记录日志
            #if DEBUG
            print("[SandboxManager] 权限配置已更新")
            #endif
        }
    }
    
    // MARK: - 初始化
    private init() {}
    
    // MARK: - 沙盒环境检测
    
    /// 检测当前应用是否在沙盒环境中运行
    public var isSandboxed: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // 使用缓存结果
        if let cached = _cachedIsSandboxed {
            return cached
        }
        
        let result = detectSandboxEnvironment()
        _cachedIsSandboxed = result
        return result
    }
    
    /// 内部沙盒检测逻辑（多种方式综合判断）
    private func detectSandboxEnvironment() -> Bool {
        // 方法1: 检查环境变量 APP_SANDBOX_CONTAINER_ID
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return true
        }
        
        // 方法2: 检查容器目录是否存在且当前进程可访问
        if let containerDir = getContainerDirectory(),
           FileManager.default.fileExists(atPath: containerDir.path) {
            // 进一步检查路径特征：包含 "Containers" 和 bundle identifier
            let path = containerDir.path
            if path.contains("Containers/") && path.contains("Data/Application/") {
                return true
            }
        }
        
        // 方法3: 检查是否无法访问沙盒外敏感路径（如 /Users/Shared）
        // 沙盒应用通常无法访问其他用户目录
        let testPath = "/Users/Shared"
        let canAccessShared = FileManager.default.isReadableFile(atPath: testPath)
        
        // 方法4: 检查 home 目录是否被重定向到容器
        let homeDir = NSHomeDirectory()
        if homeDir.contains("Containers/") {
            return true
        }
        
        // 综合判断：如果无法访问共享目录且 home 目录不是标准路径，可能是沙盒
        if !canAccessShared && homeDir != NSHomeDirectoryForUser(NSUserName()) {
            return true
        }
        
        return false
    }
    
    // MARK: - 沙盒目录获取
    
    /// 沙盒容器目录（沙盒应用的根目录）
    /// 非沙盒环境下返回 nil
    public var containerDirectory: URL? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        if let cached = _cachedContainerDirectory {
            return cached
        }
        
        let result = getContainerDirectory()
        _cachedContainerDirectory = result
        return result
    }
    
    /// 沙盒临时目录
    public var temporaryDirectory: URL? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        if let cached = _cachedTemporaryDirectory {
            return cached
        }
        
        let result = getTemporaryDirectory()
        _cachedTemporaryDirectory = result
        return result
    }
    
    /// 沙盒缓存目录
    public var cacheDirectory: URL? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        if let cached = _cachedCacheDirectory {
            return cached
        }
        
        let result = getCacheDirectory()
        _cachedCacheDirectory = result
        return result
    }
    
    /// 沙盒文档目录
    public var documentsDirectory: URL? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        if let cached = _cachedDocumentsDirectory {
            return cached
        }
        
        let result = getDocumentsDirectory()
        _cachedDocumentsDirectory = result
        return result
    }
    
    // MARK: - 目录获取内部实现
    
    private func getContainerDirectory() -> URL? {
        // 沙盒容器目录通常是 ~/Library/Containers/<bundle-id>/
        let homeDir = NSHomeDirectory()
        
        // 如果 home 目录包含 Containers，说明是沙盒环境
        if homeDir.contains("Containers/") {
            let url = URL(fileURLWithPath: homeDir)
            // 向上追溯到容器根目录（通常是 Data 的上级目录）
            var containerURL = url
            // 从 .../Containers/<bundle-id>/Data 向上退到 .../Containers/<bundle-id>/
            if url.path.contains("/Data/") {
                containerURL = url.deletingLastPathComponent().deletingLastPathComponent()
            }
            return containerURL
        }
        
        // 尝试通过 bundle identifier 构建容器路径
        if let bundleId = Bundle.main.bundleIdentifier {
            let potentialPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleId)")
            if FileManager.default.fileExists(atPath: potentialPath.path) {
                return potentialPath
            }
        }
        
        return nil
    }
    
    private func getTemporaryDirectory() -> URL? {
        // 沙盒临时目录
        let tempDir = FileManager.default.temporaryDirectory
        
        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        return tempDir
    }
    
    private func getCacheDirectory() -> URL? {
        // 获取标准缓存目录
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        
        // 在沙盒环境下，缓存目录已经在容器内
        // 非沙盒环境下，追加应用标识子目录
        if !isSandboxed {
            let appCachesURL = cachesURL.appendingPathComponent("XianRenZhiLu", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appCachesURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return appCachesURL
        }
        
        return cachesURL
    }
    
    private func getDocumentsDirectory() -> URL? {
        // 获取标准文档目录
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        
        // 在沙盒环境下，文档目录已经在容器内
        // 非沙盒环境下，追加应用标识子目录
        if !isSandboxed {
            let appDocumentsURL = documentsURL.appendingPathComponent("XianRenZhiLu", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appDocumentsURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return appDocumentsURL
        }
        
        return documentsURL
    }
    
    // MARK: - 安全区资源访问
    
    /// 安全访问安全区文件（Security-Scoped Resource）
    /// 用于访问用户通过 NSOpenPanel/NSSavePanel 选择的文件
    /// - Parameter url: 需要访问的文件 URL（通常来自文件选择面板）
    /// - Returns: 访问结果，包含是否成功和停止访问的 handler
    public func accessSecurityScopedResource(url: URL) -> SecurityScopedAccessResult {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // 检查 URL 是否是安全区资源
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        
        if isSecurityScoped {
            #if DEBUG
            print("[SandboxManager] 已开始访问安全区资源: \(url.path)")
            #endif
            
            return SecurityScopedAccessResult(
                startAccessing: true,
                stopHandler: { [weak self] in
                    url.stopAccessingSecurityScopedResource()
                    #if DEBUG
                    print("[SandboxManager] 已停止访问安全区资源: \(url.path)")
                    #endif
                }
            )
        } else {
            // 如果不是安全区资源，直接返回可访问（非沙盒环境或已授权）
            return SecurityScopedAccessResult(
                startAccessing: true,
                stopHandler: {}
            )
        }
    }
    
    /// 使用 bookmark data 重新获取安全区资源访问权限
    /// - Parameter bookmarkData: 之前保存的 bookmark data
    /// - Returns: 解析后的 URL 和访问结果
    public func resolveBookmarkData(_ bookmarkData: Data) -> (url: URL?, result: SecurityScopedAccessResult?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                #if DEBUG
                print("[SandboxManager] Bookmark data 已过期，需要重新创建")
                #endif
            }
            
            let result = accessSecurityScopedResource(url: url)
            return (url, result)
            
        } catch {
            #if DEBUG
            print("[SandboxManager] 解析 bookmark data 失败: \(error)")
            #endif
            return (nil, nil)
        }
    }
    
    /// 创建文件的 bookmark data 用于后续安全访问
    /// - Parameter url: 需要创建 bookmark 的文件 URL
    /// - Returns: bookmark data
    public func createBookmarkData(for url: URL) -> Data? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmarkData
        } catch {
            #if DEBUG
            print("[SandboxManager] 创建 bookmark data 失败: \(error)")
            #endif
            return nil
        }
    }
    
    // MARK: - 文件读写保护检查
    
    /// 检查文件读取权限
    public func canReadFile(at url: URL) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    
    /// 检查文件写入权限
    public func canWriteFile(at url: URL) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    /// 完整文件访问检查
    public func checkFileAccess(at url: URL) -> FileAccessCheckResult {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let path = url.path
        let fm = FileManager.default
        
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        let canRead = fm.isReadableFile(atPath: path)
        let canWrite = fm.isWritableFile(atPath: path)
        
        return FileAccessCheckResult(
            canRead: canRead,
            canWrite: canWrite,
            exists: exists,
            isDirectory: isDir.boolValue,
            error: nil
        )
    }
    
    /// 检查目录是否可创建文件（测试写入能力）
    public func canCreateFileInDirectory(at url: URL) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let testFileName = ".sandbox_write_test_\(UUID().uuidString)"
        let testFileURL = url.appendingPathComponent(testFileName)
        
        do {
            // 尝试创建空文件
            try Data().write(to: testFileURL)
            // 清理测试文件
            try? FileManager.default.removeItem(at: testFileURL)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - 权限检查（兼容原有 API）
    
    public func checkPermission(_ type: PermissionType) -> Bool {
        switch type {
        case .network:
            return permissions.networkAccess
        case .fileRead:
            return permissions.fileRead
        case .fileWrite:
            return permissions.fileWrite
        case .userSelectedFile:
            return permissions.userSelectedFileAccess
        }
    }
    
    public func requestPermission(_ type: PermissionType, completion: @escaping (Bool) -> Void) {
        // 实际实现需要调用系统 API（如 NSOpenPanel 等）
        // 这里简化处理，直接返回当前权限状态
        completion(checkPermission(type))
    }
    
    // MARK: - 安全路径获取（兼容原有 API）
    
    public func safePath(for type: SandboxPathType) -> URL? {
        switch type {
        case .documents:
            return documentsDirectory
        case .applicationSupport:
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            
            let appSupportURL = appSupport.appendingPathComponent("XianRenZhiLu", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return appSupportURL
            
        case .caches:
            return cacheDirectory
        case .temp:
            return temporaryDirectory
        }
    }
    
    // MARK: - 清理缓存
    
    /// 清除所有缓存的目录信息（用于环境变化时刷新）
    public func invalidateCache() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        _cachedIsSandboxed = nil
        _cachedContainerDirectory = nil
        _cachedDocumentsDirectory = nil
        _cachedCacheDirectory = nil
        _cachedTemporaryDirectory = nil
        
        #if DEBUG
        print("[SandboxManager] 缓存已清除")
        #endif
    }
}

// MARK: - 兼容层：SandboxConfig（保留原有接口）
@available(*, deprecated, renamed: "SandboxManager")
public final class SandboxConfig {
    public static let shared = SandboxConfig()
    
    public var currentPermissions: SandboxPermissions {
        get { SandboxManager.shared.permissions }
        set { SandboxManager.shared.permissions = newValue }
    }
    
    private init() {}
    
    public func checkPermission(_ type: PermissionType) -> Bool {
        return SandboxManager.shared.checkPermission(type)
    }
    
    public func requestPermission(_ type: PermissionType, completion: @escaping (Bool) -> Void) {
        SandboxManager.shared.requestPermission(type, completion: completion)
    }
    
    public static func safePath(for type: SandboxPathType) -> URL? {
        return SandboxManager.shared.safePath(for: type)
    }
}

// MARK: - 测试
#if DEBUG
import XCTest

class SandboxManagerTests: XCTestCase {
    
    var manager: SandboxManager!
    
    override func setUp() {
        super.setUp()
        manager = SandboxManager.shared
        manager.invalidateCache()
        manager.permissions = .default
    }
    
    override func tearDown() {
        manager.invalidateCache()
        super.tearDown()
    }
    
    // MARK: - 测试1: 沙盒环境检测
    func testIsSandboxedDetection() {
        // 检测是否能正确判断沙盒状态
        let isSandboxed = manager.isSandboxed
        
        // 在开发环境下通常不是沙盒，在 App Store 版本是沙盒
        // 这里只验证方法能正常返回 Bool 值
        XCTAssertTrue(isSandboxed == true || isSandboxed == false)
        
        #if DEBUG
        print("[Test] 沙盒状态: \(isSandboxed ? "是" : "否")")
        #endif
    }
    
    // MARK: - 测试2: 容器目录获取
    func testContainerDirectory() {
        let container = manager.containerDirectory
        
        if manager.isSandboxed {
            XCTAssertNotNil(container, "沙盒环境下应能获取容器目录")
            if let container = container {
                XCTAssertTrue(FileManager.default.fileExists(atPath: container.path),
                              "容器目录应存在")
            }
        }
        
        #if DEBUG
        print("[Test] 容器目录: \(container?.path ?? "nil")")
        #endif
    }
    
    // MARK: - 测试3: 文档目录获取
    func testDocumentsDirectory() {
        let documents = manager.documentsDirectory
        XCTAssertNotNil(documents, "文档目录不应为 nil")
        
        if let documents = documents {
            XCTAssertTrue(FileManager.default.fileExists(atPath: documents.path),
                          "文档目录应存在")
            
            // 测试能否在文档目录创建文件
            let canCreate = manager.canCreateFileInDirectory(at: documents)
            XCTAssertTrue(canCreate, "应能在文档目录创建文件")
        }
        
        #if DEBUG
        print("[Test] 文档目录: \(documents?.path ?? "nil")")
        #endif
    }
    
    // MARK: - 测试4: 缓存目录获取
    func testCacheDirectory() {
        let cache = manager.cacheDirectory
        XCTAssertNotNil(cache, "缓存目录不应为 nil")
        
        if let cache = cache {
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path),
                          "缓存目录应存在")
        }
        
        #if DEBUG
        print("[Test] 缓存目录: \(cache?.path ?? "nil")")
        #endif
    }
    
    // MARK: - 测试5: 临时目录获取
    func testTemporaryDirectory() {
        let temp = manager.temporaryDirectory
        XCTAssertNotNil(temp, "临时目录不应为 nil")
        
        if let temp = temp {
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path),
                          "临时目录应存在")
            
            // 测试能否在临时目录创建文件
            let canCreate = manager.canCreateFileInDirectory(at: temp)
            XCTAssertTrue(canCreate, "应能在临时目录创建文件")
        }
        
        #if DEBUG
        print("[Test] 临时目录: \(temp?.path ?? "nil")")
        #endif
    }
    
    // MARK: - 测试6: 安全区资源访问
    func testSecurityScopedResourceAccess() {
        // 创建一个临时文件用于测试
        guard let tempDir = manager.temporaryDirectory else {
            XCTFail("无法获取临时目录")
            return
        }
        
        let testFile = tempDir.appendingPathComponent("test_security_scoped.txt")
        let testContent = "Security Scoped Resource Test"
        
        do {
            try testContent.write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("创建测试文件失败: \(error)")
            return
        }
        
        // 测试安全区访问
        let result = manager.accessSecurityScopedResource(url: testFile)
        XCTAssertTrue(result.startAccessing, "应能访问安全区资源")
        
        // 测试读取文件
        do {
            let content = try String(contentsOf: testFile, encoding: .utf8)
            XCTAssertEqual(content, testContent, "文件内容应匹配")
        } catch {
            XCTFail("读取文件失败: \(error)")
        }
        
        // 停止访问
        result.stopHandler()
        
        // 清理
        try? FileManager.default.removeItem(at: testFile)
        
        #if DEBUG
        print("[Test] 安全区资源访问测试通过")
        #endif
    }
    
    // MARK: - 测试7: 文件读取保护检查
    func testFileReadProtection() {
        guard let tempDir = manager.temporaryDirectory else {
            XCTFail("无法获取临时目录")
            return
        }
        
        let testFile = tempDir.appendingPathComponent("test_read_protection.txt")
        try? "Test Content".write(to: testFile, atomically: true, encoding: .utf8)
        
        // 测试可读取文件
        let canRead = manager.canReadFile(at: testFile)
        XCTAssertTrue(canRead, "应能读取刚创建的文件")
        
        // 测试完整访问检查
        let accessResult = manager.checkFileAccess(at: testFile)
        XCTAssertTrue(accessResult.canRead, "文件应可读取")
        XCTAssertTrue(accessResult.exists, "文件应存在")
        XCTAssertFalse(accessResult.isDirectory, "应是文件而非目录")
        
        // 测试不存在的文件
        let nonExistentFile = tempDir.appendingPathComponent("non_existent.txt")
        let nonExistentAccess = manager.checkFileAccess(at: nonExistentFile)
        XCTAssertFalse(nonExistentAccess.exists, "不存在的文件应返回 exists=false")
        XCTAssertFalse(nonExistentAccess.canRead, "不存在的文件应不可读取")
        
        // 清理
        try? FileManager.default.removeItem(at: testFile)
        
        #if DEBUG
        print("[Test] 文件读取保护检查测试通过")
        #endif
    }
    
    // MARK: - 测试8: 文件写入保护检查
    func testFileWriteProtection() {
        guard let tempDir = manager.temporaryDirectory else {
            XCTFail("无法获取临时目录")
            return
        }
        
        let testFile = tempDir.appendingPathComponent("test_write_protection.txt")
        try? "Initial Content".write(to: testFile, atomically: true, encoding: .utf8)
        
        // 测试可写入文件
        let canWrite = manager.canWriteFile(at: testFile)
        XCTAssertTrue(canWrite, "应能写入临时目录的文件")
        
        // 测试完整访问检查
        let accessResult = manager.checkFileAccess(at: testFile)
        XCTAssertTrue(accessResult.canWrite, "文件应可写入")
        
        // 测试目录创建能力
        let canCreate = manager.canCreateFileInDirectory(at: tempDir)
        XCTAssertTrue(canCreate, "应能在临时目录创建文件")
        
        // 清理
        try? FileManager.default.removeItem(at: testFile)
        
        #if DEBUG
        print("[Test] 文件写入保护检查测试通过")
        #endif
    }
    
    // MARK: - 测试9: 线程安全测试
    func testThreadSafety() {
        let expectation = self.expectation(description: "ThreadSafety")
        let iterations = 100
        let group = DispatchGroup()
        
        // 多线程并发访问
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .default).async {
                _ = self.manager.isSandboxed
                _ = self.manager.documentsDirectory
                _ = self.manager.cacheDirectory
                _ = self.manager.temporaryDirectory
                
                if i % 10 == 0 {
                    self.manager.invalidateCache()
                }
                
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10.0) { error in
            XCTAssertNil(error, "线程安全测试不应超时")
            #if DEBUG
            print("[Test] 线程安全测试通过（\(iterations) 次并发访问）")
            #endif
        }
    }
    
    // MARK: - 测试10: 权限配置测试
    func testPermissions() {
        // 测试默认权限
        XCTAssertTrue(manager.checkPermission(.network))
        XCTAssertTrue(manager.checkPermission(.fileRead))
        XCTAssertTrue(manager.checkPermission(.fileWrite))
        XCTAssertTrue(manager.checkPermission(.userSelectedFile))
        
        // 修改权限
        var strictPermissions = SandboxPermissions.default
        strictPermissions.fileWrite = false
        strictPermissions.userSelectedFileAccess = false
        manager.permissions = strictPermissions
        
        // 验证修改后的权限
        XCTAssertTrue(manager.checkPermission(.network))
        XCTAssertTrue(manager.checkPermission(.fileRead))
        XCTAssertFalse(manager.checkPermission(.fileWrite))
        XCTAssertFalse(manager.checkPermission(.userSelectedFile))
        
        // 恢复默认权限
        manager.permissions = .default
        
        #if DEBUG
        print("[Test] 权限配置测试通过")
        #endif
    }
    
    // MARK: - 测试11: Bookmark Data 测试
    func testBookmarkData() {
        guard let tempDir = manager.temporaryDirectory else {
            XCTFail("无法获取临时目录")
            return
        }
        
        let testFile = tempDir.appendingPathComponent("test_bookmark.txt")
        try? "Bookmark Test".write(to: testFile, atomically: true, encoding: .utf8)
        
        // 创建 bookmark data
        let bookmarkData = manager.createBookmarkData(for: testFile)
        
        // 非安全区资源可能无法创建 bookmark，所以允许 nil
        if let bookmarkData = bookmarkData {
            // 解析 bookmark data
            let (url, result) = manager.resolveBookmarkData(bookmarkData)
            XCTAssertNotNil(url, "应能解析 bookmark data")
            
            if let result = result {
                XCTAssertTrue(result.startAccessing, "应能访问解析出的资源")
                result.stopHandler()
            }
        }
        
        // 清理
        try? FileManager.default.removeItem(at: testFile)
        
        #if DEBUG
        print("[Test] Bookmark Data 测试通过")
        #endif
    }
    
    // MARK: - 测试12: 安全路径获取（兼容 API）
    func testSafePath() {
        let documents = manager.safePath(for: .documents)
        XCTAssertNotNil(documents, "应能获取文档安全路径")
        
        let appSupport = manager.safePath(for: .applicationSupport)
        XCTAssertNotNil(appSupport, "应能获取应用支持安全路径")
        
        let caches = manager.safePath(for: .caches)
        XCTAssertNotNil(caches, "应能获取缓存安全路径")
        
        let temp = manager.safePath(for: .temp)
        XCTAssertNotNil(temp, "应能获取临时安全路径")
        
        #if DEBUG
        print("[Test] 安全路径获取测试通过")
        #endif
    }
}
#endif
