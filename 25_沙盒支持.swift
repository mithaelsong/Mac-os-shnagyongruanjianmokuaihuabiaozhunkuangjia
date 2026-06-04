// 功能25: 沙盒支持（可选）
// 对应: 如果上架 Mac App Store，需要支持沙盒
// 优先级: P3 (交易软件通常不上架，但预留)

import Foundation

/// 沙盒配置 (功能25)
public final class SandboxConfig {
    public static let shared = SandboxConfig()
    
    // MARK: - 沙盒权限
    public struct Permissions {
        public var networkAccess: Bool = true      // 网络访问（必须，交易需要）
        public var fileRead: Bool = true            // 文件读取
        public var fileWrite: Bool = true           // 文件写入（缓存、配置）
        public var userSelectedFileAccess: Bool = true  // 用户选择文件
        public var downloadsFolder: Bool = false    // 下载文件夹
        public var picturesFolder: Bool = false     // 图片文件夹
        public var musicFolder: Bool = false        // 音乐文件夹
        public var moviesFolder: Bool = false       // 视频文件夹
        
        public static let `default` = Permissions()
        public static let strict = Permissions(networkAccess: true, fileRead: true, fileWrite: false)
    }
    
    public var currentPermissions: Permissions = .default
    
    private init() {}
    
    // MARK: - 检查权限
    public func checkPermission(_ type: PermissionType) -> Bool {
        switch type {
        case .network: return currentPermissions.networkAccess
        case .fileRead: return currentPermissions.fileRead
        case .fileWrite: return currentPermissions.fileWrite
        case .userSelectedFile: return currentPermissions.userSelectedFileAccess
        }
    }
    
    // MARK: - 申请权限
    public func requestPermission(_ type: PermissionType, completion: @escaping (Bool) -> Void) {
        // 实际实现需要调用系统 API
        // 这里简化处理
        completion(true)
    }
}

public enum PermissionType {
    case network
    case fileRead
    case fileWrite
    case userSelectedFile
}

// MARK: - 沙盒路径
public extension SandboxConfig {
    /// 获取沙盒内安全路径
    static func safePath(for type: SandboxPathType) -> URL? {
        switch type {
        case .documents:
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        case .applicationSupport:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("XianRenZhiLu")
        case .caches:
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("XianRenZhiLu")
        case .temp:
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("XianRenZhiLu")
        }
    }
}

public enum SandboxPathType {
    case documents
    case applicationSupport
    case caches
    case temp
}