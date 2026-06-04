// 功能9: 动态加载模块
// 对应: 运行时加载新的 .bundle 或模块文件夹
// 优先级: P1

import Foundation

/// 动态模块加载器 (功能9)
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

    // MARK: - 动态加载
    public func load(from path: URL) -> ModuleLoadResult {
        logger.info("Dynamic loading from: \(path.path)")

        // 扫描路径
        let scanner = ModuleScanner()
        let scanned = scanner.scan(directory: path)

        guard let first = scanned.first(where: { $0.isValid }) else {
            logger.warning("No valid module found at \(path.path)")
            return .failure(.loadFailed(name: path.lastPathComponent, reason: "No valid module found"))
        }

        // 验证签名
        guard verifySignature(for: first) else {
            logger.error("Signature validation failed for module: \(first.metadata.name)")
            return .failure(.loadFailed(name: first.metadata.name, reason: "Signature validation failed"))
        }

        // 检查版本兼容性
        let compatibility = checkVersionCompatibility(for: first)
        switch compatibility {
        case .incompatible(let reason):
            logger.error("Version incompatible for module \(first.metadata.name): \(reason)")
            return .failure(.versionIncompatible(
                module: first.metadata.name,
                required: systemVersion.stringValue,
                actual: first.metadata.version
            ))
        case .compatible(let warning):
            if let warning = warning {
                logger.warning("Version warning for module \(first.metadata.name): \(warning)")
            } else {
                logger.info("Version compatible for module \(first.metadata.name)")
            }
        }

        // 加载模块
        logger.info("Loading module \(first.metadata.name) after signature and version checks passed")
        return loader.load(module: first)
    }

    // MARK: - 从网络加载 (高级功能)
    public func loadFromNetwork(url: URL, completion: @escaping (ModuleLoadResult) -> Void) {
        logger.info("Downloading module from: \(url)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Download failed: \(error.localizedDescription)")
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: error.localizedDescription)))
                return
            }

            guard let tempURL = tempURL else {
                self.logger.error("Download returned no data")
                completion(.failure(.loadFailed(name: url.lastPathComponent, reason: "No data downloaded")))
                return
            }

            // 移动到插件目录
            let pluginDir = self.pluginDirectory
            let moduleName = url.deletingPathExtension().lastPathComponent
            let destination = pluginDir.appendingPathComponent(moduleName)

            do {
                // 解压 (如果是 zip)
                if url.pathExtension == "zip" {
                    try self.unzip(from: tempURL, to: destination)
                } else {
                    try FileManager.default.copyItem(at: tempURL, to: destination)
                }

                // 加载 (会经过签名和版本检查)
                let result = self.load(from: destination)
                completion(result)
            } catch {
                self.logger.error("Failed to process downloaded module: \(error.localizedDescription)")
                completion(.failure(.loadFailed(name: moduleName, reason: error.localizedDescription)))
            }
        }

        task.resume()
    }

    // MARK: - 签名验证
    /// 验证模块签名
    /// 简单验证：检查 bundle 内是否存在 .signature 文件
    private func verifySignature(for module: ScannedModule) -> Bool {
        let signaturePath = module.bundleURL.appendingPathComponent(".signature")
        guard FileManager.default.fileExists(atPath: signaturePath.path) else {
            logger.warning("Signature file (.signature) missing for module: \(module.metadata.name)")
            return false
        }
        logger.info("Signature file found for module: \(module.metadata.name)")
        return true
    }

    // MARK: - 版本兼容性检查
    /// 检查模块版本与系统版本的兼容性
    private func checkVersionCompatibility(for module: ScannedModule) -> CompatibilityResult {
        let moduleVersion = Version(module.metadata.version)
        return versionChecker.checkCompatibility(
            moduleVersion: moduleVersion,
            frameworkVersion: systemVersion
        )
    }

    // MARK: - 私有方法
    private var pluginDirectory: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("XianRenZhiLu/PlugIns")
    }

    private func unzip(from source: URL, to destination: URL) throws {
        // 使用系统 unzip 命令
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

// MARK: - 测试代码
/// 动态模块加载器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `DynamicModuleLoaderTests.runAllTests()`
public enum DynamicModuleLoaderTests {

    // MARK: - 运行所有测试
    public static func runAllTests() {
        print("=== DynamicModuleLoader Tests ===")

        testNormalLoad()
        testSignatureFailure()
        testVersionIncompatible()

        print("\n=== All DynamicModuleLoader Tests Passed ✅ ===")
    }

    // MARK: - 测试1: 正常加载（签名和版本检查通过）
    public static func testNormalLoad() {
        print("\n🧪 Test 1: Normal Load (signature & version checks pass)")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // 创建兼容的测试模块（有签名，版本 2.0.0 匹配系统版本 2.0.0）
        createTestModule(
            at: tempDir,
            name: "NormalModule",
            version: "2.0.0",
            hasSignature: true
        )

        // 注册模块到配置系统，确保 loader 不会因配置禁用而拒绝
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

        // 签名和版本检查应通过，但 loader 会因为 bundle 是假的而失败
        // 验证失败原因不是签名或版本问题
        switch result {
        case .failure(.loadFailed(_, let reason)):
            // 预期的失败：bundle 是假的，无法真正加载
            // 但理由不应是签名或版本问题
            if reason.contains("Signature") || reason.contains("version") {
                fatalError("❌ Test 1 failed: Unexpected signature/version failure: \(reason)")
            }
            print("✅ Test 1 passed: Signature and version checks passed, loader failed for expected reason: \(reason)")
        case .failure(.versionIncompatible):
            fatalError("❌ Test 1 failed: Should not fail with version incompatible")
        default:
            // 如果成功也是意外的，但主要验证点：没有因为签名或版本被拒绝
            print("✅ Test 1 passed: Module accepted by signature and version checks")
        }
    }

    // MARK: - 测试2: 签名验证失败
    public static func testSignatureFailure() {
        print("\n🧪 Test 2: Signature Validation Failure")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // 创建没有签名的测试模块
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
                fatalError("❌ Test 2 failed: Expected signature failure for UnsignedModule, got \(name): \(reason)")
            }
            print("✅ Test 2 passed: Unsigned module rejected: \(reason)")
        default:
            fatalError("❌ Test 2 failed: Expected signature validation failure, got \(result)")
        }
    }

    // MARK: - 测试3: 版本不兼容
    public static func testVersionIncompatible() {
        print("\n🧪 Test 3: Version Incompatible")

        let tempDir = createTempTestDirectory()
        defer { cleanupTempDirectory(tempDir) }

        // 创建有签名但版本不兼容的测试模块（主版本号不匹配）
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
                fatalError("❌ Test 3 failed: Wrong module name: \(module)")
            }
            print("✅ Test 3 passed: Version incompatible detected for \(module) (required: \(required), actual: \(actual))")
        default:
            fatalError("❌ Test 3 failed: Expected versionIncompatible error, got \(result)")
        }
    }

    // MARK: - 测试辅助方法

    /// 创建临时测试目录
    private static func createTempTestDirectory() -> URL {
        let uuid = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicLoaderTests-\(uuid)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// 清理临时目录
    private static func cleanupTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 创建测试模块文件结构
    private static func createTestModule(
        at baseDir: URL,
        name: String,
        version: String,
        hasSignature: Bool
    ) {
        let moduleDir = baseDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)

        // 创建 ModuleMetadata.json
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

        // 创建 bundle 目录
        let bundleURL = moduleDir.appendingPathComponent("\(name).bundle")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // 根据条件创建签名文件
        if hasSignature {
            let signatureURL = bundleURL.appendingPathComponent(".signature")
            try? "test-signature-data".write(to: signatureURL, atomically: true, encoding: .utf8)
        }
    }
}
