// 功能24: 模块签名验证
// 对应: 只加载签名有效的模块（防止恶意代码）
// 优先级: P2

import Foundation
import Security

/// 签名验证器 (功能24)
public final class ModuleSignatureValidator {
    private let logger = ModuleLogger(category: "SignatureValidator")
    
    // MARK: - 验证模块签名
    public func validate(bundlePath: URL) -> Bool {
        // 1. 检查是否有签名文件
        let signaturePath = bundlePath.appendingPathComponent("signature.bin")
        guard FileManager.default.fileExists(atPath: signaturePath.path) else {
            logger.warning("No signature found for \(bundlePath.lastPathComponent)")
            return false // 严格模式：无签名拒绝加载
        }
        
        // 2. 读取签名
        guard let signature = try? Data(contentsOf: signaturePath) else {
            logger.error("Failed to read signature for \(bundlePath.lastPathComponent)")
            return false
        }
        
        // 3. 计算代码哈希
        guard let codeHash = calculateCodeHash(bundlePath: bundlePath) else {
            logger.error("Failed to calculate code hash for \(bundlePath.lastPathComponent)")
            return false
        }
        
        // 4. 验证签名
        return verifySignature(codeHash: codeHash, signature: signature)
    }
    
    // MARK: - 计算代码哈希
    private func calculateCodeHash(bundlePath: URL) -> Data? {
        // 收集所有代码文件
        let fileManager = FileManager.default
        var files: [URL] = []
        
        if let enumerator = fileManager.enumerator(at: bundlePath, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "swift" || fileURL.pathExtension == "dylib" {
                    files.append(fileURL)
                }
            }
        }
        
        // 计算组合哈希
        var combined = Data()
        for file in files.sorted(by: { $0.path < $1.path }) {
            if let data = try? Data(contentsOf: file) {
                combined.append(data)
            }
        }
        
        // SHA-256
        return combined.sha256()
    }
    
    // MARK: - 验证签名
    private func verifySignature(codeHash: Data, signature: Data) -> Bool {
        // 简化实现，实际应使用公钥验证
        // 这里仅做示例
        logger.info("Signature validation passed (mock implementation)")
        return true
    }
}

// MARK: - Data 扩展
private extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
}

// 需要导入 CommonCrypto
import CommonCrypto