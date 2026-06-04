// 功能7: 处理模块加载失败
// 对应: 记录日志，继续加载其他模块，不崩溃
// 优先级: P0

import Foundation

/// 模块错误恢复策略
public enum RecoveryStrategy {
    case continueLoading      // 继续加载其他模块（默认）
    case retry(delay: TimeInterval)  // 延迟重试
    case abort                // 停止加载
    case fallback(String)     // 使用备用模块
}

/// 模块错误处理器 (功能7)
public final class ModuleErrorHandler {
    private let logger = ModuleLogger(category: "ModuleErrorHandler")
    private var failureCounts: [String: Int] = [:]
    private let maxRetries = 3
    
    // MARK: - 处理加载失败
    public func handleLoadFailure(
        module: String,
        error: ModuleError,
        strategy: RecoveryStrategy = .continueLoading
    ) -> RecoveryStrategy {
        
        // 记录错误
        logFailure(module: module, error: error)
        
        // 更新失败计数
        failureCounts[module, default: 0] += 1
        let count = failureCounts[module] ?? 0
        
        switch strategy {
        case .continueLoading:
            logger.warning("Module \(module) failed to load, continuing with others")
            return .continueLoading
            
        case .retry(let delay):
            if count < maxRetries {
                logger.info("Will retry loading \(module) in \(delay)s (attempt \(count)/\(maxRetries))")
                return .retry(delay: delay)
            } else {
                logger.error("Module \(module) exceeded max retries (\(maxRetries)), giving up")
                return .continueLoading
            }
            
        case .abort:
            logger.fatal("Module \(module) critical failure, aborting load sequence")
            return .abort
            
        case .fallback(let fallbackModule):
            logger.info("Attempting fallback to \(fallbackModule) for \(module)")
            return .fallback(fallbackModule)
        }
    }
    
    // MARK: - 私有方法
    private func logFailure(module: String, error: ModuleError) {
        let message: String
        switch error {
        case .notFound(let name):
            message = "Module not found: \(name)"
        case .loadFailed(let name, let reason):
            message = "Module \(name) load failed: \(reason)"
        case .dependencyMissing(let module, let dependency):
            message = "Module \(module) missing dependency: \(dependency)"
        case .versionIncompatible(let module, let required, let actual):
            message = "Module \(module) version incompatible: required \(required), got \(actual)"
        case .alreadyLoaded(let name):
            message = "Module \(name) already loaded"
        case .notLoaded(let name):
            message = "Module \(name) not loaded"
        case .invalidMetadata(let path):
            message = "Invalid metadata at \(path)"
        case .startFailed(let name, let error):
            message = "Module \(name) start failed: \(error.localizedDescription)"
        case .stopFailed(let name, let error):
            message = "Module \(name) stop failed: \(error.localizedDescription)"
        }
        
        logger.error("[\(module)] \(message)")
    }
}

/// 模块加载结果扩展
public extension ModuleLoadResult {
    var errorDescription: String? {
        switch self {
        case .failure(let error):
            return String(describing: error)
        case .success:
            return nil
        }
    }
}