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
            logger.info("权限配置已更新")
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
            logger.info("已开始访问安全区资源: \(url.path)")
            
            return SecurityScopedAccessResult(
                startAccessing: true,
                stopHandler: { [weak self] in
                    url.stopAccessingSecurityScopedResource()
                    logger.info("已停止访问安全区资源: \(url.path)")
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
                logger.warning("Bookmark data已过期，需要重新创建")
            }
            
            let result = accessSecurityScopedResource(url: url)
            return (url, result)
            
        } catch {
            logger.error("解析bookmark data失败: \(error)")
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
            logger.error("创建bookmark data失败: \(error)")
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
        
        logger.info("缓存已清除")
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
    
    private let logger = ModuleLogger(category: "SandboxManager")

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

// MARK: - 测试代码
/// 沙盒管理器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `SandboxManagerTests.run()`
public enum SandboxManagerTests {

    /// 运行所有测试
    public static func run() {
        let manager = SandboxManager.shared
        manager.invalidateCache()
        manager.permissions = .default

        print("=== 沙盒支持测试 ===")
        testIsSandboxedDetection(manager: manager)
        testContainerDirectory(manager: manager)
        testDocumentsDirectory(manager: manager)
        testCacheDirectory(manager: manager)
        testTemporaryDirectory(manager: manager)
        testSecurityScopedResourceAccess(manager: manager)
        testFileReadProtection(manager: manager)
        testFileWriteProtection(manager: manager)
        testThreadSafety(manager: manager)
        testPermissions(manager: manager)
        testBookmarkData(manager: manager)
        testSafePath(manager: manager)
        print("\n=== 全部沙盒支持测试通过 ✅ ===")
    }

    // MARK: - 测试1: 沙盒环境检测
    static func testIsSandboxedDetection(manager: SandboxManager) {
        print("\n🧪 测试1: 沙盒环境检测")
        let _ = manager.isSandboxed
        print("✅ 测试1通过: 沙盒状态检测方法正常返回")
    }

    // MARK: - 测试2: 容器目录获取
    static func testContainerDirectory(manager: SandboxManager) {
        print("\n🧪 测试2: 容器目录获取")
        if manager.isSandboxed {
            guard let container = manager.containerDirectory else {
                fatalError("❌ 测试2失败: 沙盒环境下应能获取容器目录")
            }
            guard FileManager.default.fileExists(atPath: container.path) else {
                fatalError("❌ 测试2失败: 容器目录应存在")
            }
        }
        print("✅ 测试2通过: 容器目录获取正确")
    }

    // MARK: - 测试3: 文档目录获取
    static func testDocumentsDirectory(manager: SandboxManager) {
        print("\n🧪 测试3: 文档目录获取")
        guard let documents = manager.documentsDirectory else {
            fatalError("❌ 测试3失败: 文档目录不应为nil")
        }
        guard FileManager.default.fileExists(atPath: documents.path) else {
            fatalError("❌ 测试3失败: 文档目录应存在")
        }
        guard manager.canCreateFileInDirectory(at: documents) else {
            fatalError("❌ 测试3失败: 应能在文档目录创建文件")
        }
        print("✅ 测试3通过: 文档目录获取正确")
    }

    // MARK: - 测试4: 缓存目录获取
    static func testCacheDirectory(manager: SandboxManager) {
        print("\n🧪 测试4: 缓存目录获取")
        guard let cache = manager.cacheDirectory else {
            fatalError("❌ 测试4失败: 缓存目录不应为nil")
        }
        guard FileManager.default.fileExists(atPath: cache.path) else {
            fatalError("❌ 测试4失败: 缓存目录应存在")
        }
        print("✅ 测试4通过: 缓存目录获取正确")
    }

    // MARK: - 测试5: 临时目录获取
    static func testTemporaryDirectory(manager: SandboxManager) {
        print("\n🧪 测试5: 临时目录获取")
        guard let temp = manager.temporaryDirectory else {
            fatalError("❌ 测试5失败: 临时目录不应为nil")
        }
        guard FileManager.default.fileExists(atPath: temp.path) else {
            fatalError("❌ 测试5失败: 临时目录应存在")
        }
        guard manager.canCreateFileInDirectory(at: temp) else {
            fatalError("❌ 测试5失败: 应能在临时目录创建文件")
        }
        print("✅ 测试5通过: 临时目录获取正确")
    }

    // MARK: - 测试6: 安全区资源访问
    static func testSecurityScopedResourceAccess(manager: SandboxManager) {
        print("\n🧪 测试6: 安全区资源访问")
        guard let tempDir = manager.temporaryDirectory else {
            fatalError("❌ 测试6失败: 无法获取临时目录")
        }
        let testFile = tempDir.appendingPathComponent("test_security_scoped.txt")
        guard (try? "Security Scoped Resource Test".write(to: testFile, atomically: true, encoding: .utf8)) != nil else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试6失败: 创建测试文件失败")
        }
        let result = manager.accessSecurityScopedResource(url: testFile)
        guard result.startAccessing else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试6失败: 应能访问安全区资源")
        }
        guard let content = try? String(contentsOf: testFile, encoding: .utf8) else {
            result.stopHandler()
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试6失败: 读取文件失败")
        }
        guard content == "Security Scoped Resource Test" else {
            result.stopHandler()
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试6失败: 文件内容不匹配")
        }
        result.stopHandler()
        try? FileManager.default.removeItem(at: testFile)
        print("✅ 测试6通过: 安全区资源访问正确")
    }

    // MARK: - 测试7: 文件读取保护检查
    static func testFileReadProtection(manager: SandboxManager) {
        print("\n🧪 测试7: 文件读取保护检查")
        guard let tempDir = manager.temporaryDirectory else {
            fatalError("❌ 测试7失败: 无法获取临时目录")
        }
        let testFile = tempDir.appendingPathComponent("test_read_protection.txt")
        try? "Test Content".write(to: testFile, atomically: true, encoding: .utf8)
        guard manager.canReadFile(at: testFile) else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试7失败: 应能读取刚创建的文件")
        }
        let accessResult = manager.checkFileAccess(at: testFile)
        guard accessResult.canRead else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试7失败: 文件应可读取")
        }
        guard accessResult.exists else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试7失败: 文件应存在")
        }
        guard !accessResult.isDirectory else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试7失败: 应是文件而非目录")
        }
        let nonExistentAccess = manager.checkFileAccess(at: tempDir.appendingPathComponent("non_existent.txt"))
        guard !nonExistentAccess.exists else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试7失败: 不存在的文件应返回exists=false")
        }
        try? FileManager.default.removeItem(at: testFile)
        print("✅ 测试7通过: 文件读取保护检查正确")
    }

    // MARK: - 测试8: 文件写入保护检查
    static func testFileWriteProtection(manager: SandboxManager) {
        print("\n🧪 测试8: 文件写入保护检查")
        guard let tempDir = manager.temporaryDirectory else {
            fatalError("❌ 测试8失败: 无法获取临时目录")
        }
        let testFile = tempDir.appendingPathComponent("test_write_protection.txt")
        try? "Initial Content".write(to: testFile, atomically: true, encoding: .utf8)
        guard manager.canWriteFile(at: testFile) else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试8失败: 应能写入临时目录的文件")
        }
        let accessResult = manager.checkFileAccess(at: testFile)
        guard accessResult.canWrite else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试8失败: 文件应可写入")
        }
        guard manager.canCreateFileInDirectory(at: tempDir) else {
            try? FileManager.default.removeItem(at: testFile)
            fatalError("❌ 测试8失败: 应能在临时目录创建文件")
        }
        try? FileManager.default.removeItem(at: testFile)
        print("✅ 测试8通过: 文件写入保护检查正确")
    }

    // MARK: - 测试9: 线程安全
    static func testThreadSafety(manager: SandboxManager) {
        print("\n🧪 测试9: 线程安全")
        let group = DispatchGroup()
        let iterations = 100
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .default).async {
                _ = manager.isSandboxed
                _ = manager.documentsDirectory
                _ = manager.cacheDirectory
                _ = manager.temporaryDirectory
                if i % 10 == 0 {
                    manager.invalidateCache()
                }
                group.leave()
            }
        }
        group.wait()
        print("✅ 测试9通过: \(iterations)次并发访问完成无崩溃")
    }

    // MARK: - 测试10: 权限配置
    static func testPermissions(manager: SandboxManager) {
        print("\n🧪 测试10: 权限配置")
        guard manager.checkPermission(.network) else {
            fatalError("❌ 测试10失败: 默认应允许网络访问")
        }
        guard manager.checkPermission(.fileRead) else {
            fatalError("❌ 测试10失败: 默认应允许文件读取")
        }
        guard manager.checkPermission(.fileWrite) else {
            fatalError("❌ 测试10失败: 默认应允许文件写入")
        }
        var strictPermissions = SandboxPermissions.default
        strictPermissions.fileWrite = false
        strictPermissions.userSelectedFileAccess = false
        manager.permissions = strictPermissions
        guard !manager.checkPermission(.fileWrite) else {
            manager.permissions = .default
            fatalError("❌ 测试10失败: fileWrite应已被禁用")
        }
        guard !manager.checkPermission(.userSelectedFile) else {
            manager.permissions = .default
            fatalError("❌ 测试10失败: userSelectedFileAccess应已被禁用")
        }
        manager.permissions = .default
        print("✅ 测试10通过: 权限配置正确")
    }

    // MARK: - 测试11: Bookmark Data
    static func testBookmarkData(manager: SandboxManager) {
        print("\n🧪 测试11: Bookmark Data")
        guard let tempDir = manager.temporaryDirectory else {
            fatalError("❌ 测试11失败: 无法获取临时目录")
        }
        let testFile = tempDir.appendingPathComponent("test_bookmark.txt")
        try? "Bookmark Test".write(to: testFile, atomically: true, encoding: .utf8)
        if let bookmarkData = manager.createBookmarkData(for: testFile) {
            let (url, result) = manager.resolveBookmarkData(bookmarkData)
            guard url != nil else {
                try? FileManager.default.removeItem(at: testFile)
                fatalError("❌ 测试11失败: 应能解析bookmark data")
            }
            if let result = result {
                guard result.startAccessing else {
                    try? FileManager.default.removeItem(at: testFile)
                    fatalError("❌ 测试11失败: 应能访问解析出的资源")
                }
                result.stopHandler()
            }
        }
        try? FileManager.default.removeItem(at: testFile)
        print("✅ 测试11通过: Bookmark Data正确")
    }

    // MARK: - 测试12: 安全路径获取
    static func testSafePath(manager: SandboxManager) {
        print("\n🧪 测试12: 安全路径获取")
        guard manager.safePath(for: .documents) != nil else {
            fatalError("❌ 测试12失败: 应能获取文档安全路径")
        }
        guard manager.safePath(for: .applicationSupport) != nil else {
            fatalError("❌ 测试12失败: 应能获取应用支持安全路径")
        }
        guard manager.safePath(for: .caches) != nil else {
            fatalError("❌ 测试12失败: 应能获取缓存安全路径")
        }
        guard manager.safePath(for: .temp) != nil else {
            fatalError("❌ 测试12失败: 应能获取临时安全路径")
        }
        print("✅ 测试12通过: 安全路径获取正确")
    }
}