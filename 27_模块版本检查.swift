// 功能27: 模块版本检查
// 对应: 检查模块版本是否兼容当前框架
// 优先级: P1

import Foundation

/// 版本信息
public struct Version: Codable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    
    public init(_ version: String) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        self.major = parts.count > 0 ? parts[0] : 0
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }
    
    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
    public var stringValue: String {
        return "\(major).\(minor).\(patch)"
    }
    
    public static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    
    public static func == (lhs: Version, rhs: Version) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}

/// 版本兼容性检查器 (功能27)
public final class VersionChecker {
    private let logger = ModuleLogger(category: "VersionChecker")
    
    // MARK: - 检查兼容性
    public func checkCompatibility(
        moduleVersion: Version,
        frameworkVersion: Version,
        minRequired: Version? = nil
    ) -> CompatibilityResult {
        
        // 检查最低版本要求
        if let min = minRequired, moduleVersion < min {
            return .incompatible(
                reason: "Module version \(moduleVersion) < minimum required \(min)"
            )
        }
        
        // 主版本必须一致
        if moduleVersion.major != frameworkVersion.major {
            return .incompatible(
                reason: "Major version mismatch: module \(moduleVersion.major) vs framework \(frameworkVersion.major)"
            )
        }
        
        // 模块版本 <= 框架版本
        if moduleVersion > frameworkVersion {
            return .incompatible(
                reason: "Module version \(moduleVersion) > framework version \(frameworkVersion)"
            )
        }
        
        // 警告：次版本差异
        if moduleVersion.minor < frameworkVersion.minor {
            return .compatible(warning: "Minor version difference: module may lack new features")
        }
        
        return .compatible()
    }
    
    // MARK: - 检查依赖版本
    public func checkDependencyVersions(
        module: String,
        dependencies: [(name: String, requiredVersion: Version)]
    ) -> [DependencyCheckResult] {
        
        return dependencies.map { dep in
            guard let loadedModule = ModuleRegistry.shared.getModule(named: dep.name) else {
                return .missing(name: dep.name)
            }
            
            guard let metadata = ModuleRegistry.shared.getMetadata(named: dep.name) else {
                return .unknownVersion(name: dep.name)
            }
            
            let actualVersion = Version(metadata.version)
            if actualVersion < dep.requiredVersion {
                return .versionMismatch(
                    name: dep.name,
                    required: dep.requiredVersion,
                    actual: actualVersion
                )
            }
            
            return .ok(name: dep.name, version: actualVersion)
        }
    }
}

// MARK: - 兼容性结果
public enum CompatibilityResult {
    case compatible(warning: String? = nil)
    case incompatible(reason: String)
    
    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }
}

public enum DependencyCheckResult {
    case ok(name: String, version: Version)
    case missing(name: String)
    case unknownVersion(name: String)
    case versionMismatch(name: String, required: Version, actual: Version)
    
    public var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}