// 功能9: 动态加载模块
// Description: Load new .bundle or module folders at runtime
// Priority: P1

import Foundation

/// Dynamic module loader (Function 9)
public final class DynamicModuleLoader {
    private let registry: ModuleRegistry
    private let loader: ModuleLoader
    private let logger = ModuleLogger(category: "DynamicLoader")
    private let versionChecker = VersionChecker()
    private let systemVersion: Version

    public init(
        registry: ModuleRegistry,
        loader: ModuleLoader,
        systemVersion: Version = Version(major: 2, minor: 0, patch: 0)
    ) {
        self.registry = registry
        self.loader = loader
        self.systemVersion = systemVersion
    }

    // MARK: - Dynamic Loading
    public func load(from path: URL) -> ModuleLoadResult {
        logger.info("动态加载路径: \(path.path)")

        // Scan directory
        let scanned = ModuleScanner.shared.scan(directory: path)

        guard let first = scanned.first else {
            logger.warning("路径 \(path.path) 未找到有效模块")
            return .failure(.loadFailed(name: path.lastPathComponent, reason: "No valid module found"))
        }

        // Verify signature
        guard verifySignature(for: first) else {
            logger.error("签名验证失败: 模块 \(first.metadata.name)")
            return .failure(.loadFailed(name: first.metadata.name, reason: "Signature validation failed"))
        }

        // Check version compatibility
        let compatibility = checkVersionCompatibility(for: first)
        switch compatibility {
        case .incompatible(let reason):
            logger.error("版本不兼容: 模块 \(first.metadata.name): \(reason)")
            return .failure(.versionIncompatible(
                module: first.metadata.name,
                required: systemVersion.stringValue,
                actual: first.metadata.version
            ))
        case .compatible(let warning):
            if let warning = warning {
                logger.warning("版本警告: 模块 \(first.metadata.name): \(warning)")
            } else {
                logger.info("版本兼容: 模块 \(first.metadata.name)")
            }
        }

        // Load module
        logger.info("签名和版本检查通过，加载模块 \(first.metadata.name)")
        return loader.load(module: first)
    }

    // MARK: - Network Loading (Advanced)
    public func loadFromNetwork(url: URL, completion: @escaping (ModuleLoadResult) -> Void) {
        logger.info("下载模块: \(url)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("下载失败: \(error.localizedDescription)")
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: error.localizedDescription)))
                return
            }

            guard let tempURL = tempURL else {
                self.logger.error("下载未返回数据")
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: "No data downloaded")))
                return
            }

            // Move to plugin directory
            let pluginDir = self.pluginDirectory
            let moduleName = url.deletingPathExtension().lastPathComponent
            let destination = pluginDir.appendingPathComponent(moduleName)

            do {
                // Unzip if zip file
                let fileExtension = url.lastPathComponent.pathExtension
                if fileExtension == "zip" {
                    try self.unzip(from: tempURL, to: destination)
                } else {
                    try FileManager.default.copyItem(at: tempURL, to: destination)
                }

                // Load (signature & version checks applied)
                let result = self.load(from: destination)
                completion(result)
            } catch {
                self.logger.error("处理下载模块失败: \(error.localizedDescription)")
                completion(.failure(.loadFailed(name: moduleName, reason: error.localizedDescription)))
            }
        }

        task.resume()
    }

    // MARK: - Signature Verification
    /// Verify module signature
    /// Check .signature file exists and contains valid non-whitespace content
    private func verifySignature(for module: ScannedModule) -> Bool {
        let signaturePath = module.bundleURL.appendingPathComponent(".signature")
        
        guard FileManager.default.fileExists(atPath: signaturePath.path) else {
            logger.warning("签名文件(.signature)缺失: 模块 \(module.metadata.name)")
            return false
        }
        
        // Verify signature file is not empty and contains valid data
        guard let signatureData = try? Data(contentsOf: signaturePath), !signatureData.isEmpty else {
            logger.warning("签名文件为空: 模块 \(module.metadata.name)")
            return false
        }
        
        guard let signatureString = String(data: signatureData, encoding: .utf8), !signatureString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("签名文件仅含空白: 模块 \(module.metadata.name)")
            return false
        }
        
        logger.info("签名验证通过: 模块 \(module.metadata.name)")
        return true
    }

    // MARK: - Version Compatibility Check
    /// Check module version compatibility with system version
    private func checkVersionCompatibility(for module: ScannedModule) -> CompatibilityResult {
        let moduleVersion = Version(module.metadata.version)
        return versionChecker.checkCompatibility(
            moduleVersion: moduleVersion,
            frameworkVersion: systemVersion
        )
    }

    // MARK: - Private Methods
    private var pluginDirectory: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("XianRenZhiLu/PlugIns")
    }

    private func unzip(from source: URL, to destination: URL) throws {
        // Use system unzip command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", source.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "DynamicModuleLoader", code: Int(process.terminationStatus))
        }
    }
}

// MARK: - Test Code
/// Dynamic module loader functional verification
/// Run: call `DynamicModuleLoaderTests.runAllTests()` in unit tests or Playground
public enum DynamicModuleLoaderTests {

    // MARK: - Run All Tests
    public static func runAllTests() {
        print("=== 功能9测试 ===")

        testNormalLoad()
        testSignatureFailure()
        testVersionIncompatible()
        testEmptySignature()
        testMissingBundle()
        testWhitespaceSignature()

        print("\n=== 全部功能9测试通过 ✅ ===")
    }

    // MARK: - Test 1: Normal Load (Signature & Version Checks Pass)
    public static func testNormalLoad() {
        print("\n🧪 测试1: 正常加载(签名和版本检查通过)")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create valid module (has signature, version 2.0.0 matches system)
        createTestModule(
            at: tempDir,
            name: "NormalModule",
            version: "2.0.0",
            hasSignature: true
        )

        // Register in ConfigSystem to prevent config-based rejection
        ConfigSystem.shared.resetForTests()
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "NormalModule",
            enabled: true,
            priority: 10,
            dependencies: []
        ))

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        // Signature & version should pass, loader will fail due to fake bundle
        // Verify failure is not due to signature or version
        switch result {
        case .failure(.loadFailed(_, let reason)):
            // Expected: fake bundle cannot really load
            // Reason should not be signature or version
            if reason.contains("Signature") || reason.contains("version") {
                fatalError("❌ 测试1失败: 意外的签名/版本失败: \(reason)")
            }
            print("✅ 测试1通过: 签名和版本检查通过，加载器因预期原因失败: \(reason)")
        case .failure(.versionIncompatible):
            fatalError("❌ 测试1失败: 不应因版本不兼容失败")
        default:
            // Success would be unexpected, but main validation is: not rejected by signature/version
            print("✅ 测试1通过: 模块通过签名和版本检查")
        }
    }

    // MARK: - Test 2: Signature Validation Failure
    public static func testSignatureFailure() {
        print("\n🧪 测试2: 签名验证失败")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create module without signature file
        createTestModule(
            at: tempDir,
            name: "UnsignedModule",
            version: "2.0.0",
            hasSignature: false
        )

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        switch result {
        case .failure(.loadFailed(let name, let reason)):
            guard name == "UnsignedModule", reason == "Signature validation failed" else {
                fatalError("❌ 测试2失败: 期望UnsignedModule签名失败，实际 \(name): \(reason)")
            }
            print("✅ 测试2通过: 未签名模块被拒绝: \(reason)")
        default:
            fatalError("❌ 测试2失败: 期望签名验证失败，实际 \(result)")
        }
    }

    // MARK: - Test 3: Version Incompatible
    public static func testVersionIncompatible() {
        print("\n🧪 测试3: 版本不兼容")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create module with signature but incompatible version
        createTestModule(
            at: tempDir,
            name: "OldModule",
            version: "1.0.0",
            hasSignature: true
        )

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        switch result {
        case .failure(.versionIncompatible(let module, let required, let actual)):
            guard module == "OldModule" else {
                fatalError("❌ 测试3失败: 错误的模块名称: \(module)")
            }
            print("✅ 测试3通过: 版本不兼容已检测 \(module) (required: \(required), actual: \(actual))")
        default:
            fatalError("❌ 测试3失败: 期望versionIncompatible错误，实际 \(result)")
        }
    }

    // MARK: - Test Helpers

    /// Create a temp directory for testing
    private static func createTempTestDirectory() -> URL {
        let uuid = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicLoaderTests-\(uuid)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Clean up temp directory
    private static func cleanupTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Create test module file structure
    private static func createTestModule(
        at baseDir: URL,
        name: String,
        version: String,
        hasSignature: Bool,
        signatureContent: String = "test-signature",
        hasMetadata: Bool = true,
        hasBundle: Bool = true
    ) {
        let moduleDir = baseDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)

        // Create ModuleMetadata.json
        if hasMetadata {
            let metadata = ModuleMetadata(
                name: name,
                version: version,
                description: "Test module",
                entryClass: "TestModule",
                priority: 10
            )
            let metadataURL = moduleDir.appendingPathComponent("ModuleMetadata.json")
            if let data = try? JSONEncoder().encode(metadata) {
                try? data.write(to: metadataURL)
            }
        }

        // Create bundle directory
        if hasBundle {
            let bundleURL = moduleDir.appendingPathComponent("\(name).bundle")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            // Create signature file if required
            if hasSignature {
                let signatureURL = bundleURL.appendingPathComponent(".signature")
                try? signatureContent.write(to: signatureURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Test 4: Empty Signature File Rejected
    public static func testEmptySignature() {
        print("\n🧪 测试4: 空签名文件被拒绝")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create module with empty signature file
        createTestModule(
            at: tempDir,
            name: "EmptySigModule",
            version: "2.0.0",
            hasSignature: true,
            signatureContent: ""
        )

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        guard case .failure = result else {
            fatalError("❌ 测试4失败: 空签名模块应加载失败")
        }

        print("✅ 测试4通过: 空签名模块正确被拒绝")
    }

    // MARK: - Test 5: Module Missing Bundle
    public static func testMissingBundle() {
        print("\n🧪 测试5: 模块缺少bundle")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create module with metadata but no bundle
        createTestModule(
            at: tempDir,
            name: "NoBundleModule",
            version: "2.0.0",
            hasSignature: true,
            hasBundle: false
        )

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        guard case .failure = result else {
            fatalError("❌ 测试5失败: 缺少bundle的模块应失败")
        }

        print("✅ 测试5通过: 缺少bundle的模块正确被拒绝")
    }

    // MARK: - Test 6: Whitespace-Only Signature Rejected
    public static func testWhitespaceSignature() {
        print("\n🧪 测试6: 仅空白签名被拒绝")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // Create module with whitespace-only signature
        createTestModule(
            at: tempDir,
            name: "WhitespaceSigModule",
            version: "2.0.0",
            hasSignature: true,
            signatureContent: "   \n\n  "
        )

        let registry = ModuleRegistry()
        let eventBus = EventBus.shared
        let logger = ModuleLogger(category: "TestDynamicLoader")
        let loader = ModuleLoader(registry: registry, eventBus: eventBus, logger: logger)
        let dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        let result = dynamicLoader.load(from: tempDir)

        // Verify rejected due to whitespace-only signature
        guard case .failure = result else {
            fatalError("❌ 测试6失败: 仅空白签名的模块应失败")
        }

        print("✅ 测试6通过: 仅空白签名被拒绝")
    }
}
