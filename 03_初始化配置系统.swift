// 功能3: 初始化配置系统
// 对应: 从Info.plist/JSON/UserDefaults加载模块配置，持久化到JSON
// 优先级: P0

import Foundation
import os

// MARK: - ConfigValue
/// 配置值枚举，支持5种数据类型
public enum ConfigValue: Codable, CustomStringConvertible, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case stringArray([String])
    
    private enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    private enum ValueType: String, Codable {
        case string, int, double, bool, stringArray
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .string:
            let value = try container.decode(String.self, forKey: .value)
            self = .string(value)
        case .int:
            let value = try container.decode(Int.self, forKey: .value)
            self = .int(value)
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            self = .double(value)
        case .bool:
            let value = try container.decode(Bool.self, forKey: .value)
            self = .bool(value)
        case .stringArray:
            let value = try container.decode([String].self, forKey: .value)
            self = .stringArray(value)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .stringArray(let v):
            try container.encode(ValueType.stringArray, forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }
    
    public var description: String {
        switch self {
        case .string(let v):  return v
        case .int(let v):     return String(v)
        case .double(let v):  return String(v)
        case .bool(let v):    return v ? "true" : "false"
        case .stringArray(let v): return "[" + v.joined(separator: ", ") + "]"
        }
    }
    
    /// 便捷访问：字符串值
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    
    /// 便捷访问：整数值
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
    
    /// 便捷访问：浮点值
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }
    
    /// 便捷访问：布尔值
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    
    /// 便捷访问：字符串数组
    public var stringArrayValue: [String]? {
        if case .stringArray(let v) = self { return v }
        return nil
    }
    
    /// 从 plist 原始值推断类型创建 ConfigValue
    static func fromPlistValue(_ value: Any) -> ConfigValue? {
        if let str = value as? String { return .string(str) }
        if let int = value as? Int { return .int(int) }
        if let double = value as? Double { return .double(double) }
        if let bool = value as? Bool { return .bool(bool) }
        if let arr = value as? [String] { return .stringArray(arr) }
        return nil
    }
}

// MARK: - ModuleConfig
/// 模块配置结构体，描述单个模块的完整配置
public struct ModuleConfig: Codable, Equatable {
    public var moduleName: String
    public var enabled: Bool
    public var priority: Int
    public var dependencies: [String]
    public var customSettings: [String: ConfigValue]
    
    public init(
        moduleName: String,
        enabled: Bool = true,
        priority: Int = 100,
        dependencies: [String] = [],
        customSettings: [String: ConfigValue] = [:]
    ) {
        self.moduleName = moduleName
        self.enabled = enabled
        self.priority = priority
        self.dependencies = dependencies
        self.customSettings = customSettings
    }
}

// MARK: - ConfigSystem
/// 全局配置系统（单例）
/// 管理所有模块的配置，支持 Info.plist 默认值、UserDefaults 用户覆盖、JSON 持久化
public final class ConfigSystem {
    
    public static let shared = ConfigSystem()
    
    /// 线程安全的配置存储
    private final class ConfigStorage: @unchecked Sendable {
        var modules: [String: ModuleConfig] = [:]
        var lock = os_unfair_lock()
        var needsSave = false
        var hasInitialized = false
    }
    
    private let storage = ConfigStorage()
    private let logger = ModuleLogger(category: "ConfigSystem")
    private let saveQueue = DispatchQueue(label: "com.xianrenzhilu.config.save", qos: .utility)
    private let saveLock = os_unfair_lock()
    private var pendingSaveWork: DispatchWorkItem?
    
    /// 配置文件路径：~/Library/Application Support/XianRenZhiLu/module_config.json
    public let configFileURL: URL
    
    private init() {
        self.configFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XianRenZhiLu/module_config.json")
    }
    
    // MARK: - 初始化
    
    /// 初始化配置系统
    /// 加载顺序：Info.plist → JSON 持久化文件 → UserDefaults（优先级递增）
    /// 幂等：首次调用执行完整加载，重复调用不重复加载
    public func initialize() {
        os_unfair_lock_lock(&storage.lock)
        if storage.hasInitialized {
            os_unfair_lock_unlock(&storage.lock)
            return
        }
        
        logger.info("Initializing configuration system")
        
        // 确保配置目录存在
        let configDir = configFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create config directory: \(error)")
        }
        
        // 1. 从 Info.plist 加载默认配置
        loadFromInfoPlistUnlocked()
        
        // 2. 从 JSON 文件加载持久化配置（覆盖默认值）
        loadFromDiskUnlocked()
        
        // 3. 从 UserDefaults 加载用户设置（覆盖持久化值）
        loadFromUserDefaultsUnlocked()
        
        // 4. 如果 JSON 文件不存在，立即持久化一次
        let firstRun = !FileManager.default.fileExists(atPath: configFileURL.path)
        let moduleCount = storage.modules.count
        storage.needsSave = firstRun
        storage.hasInitialized = true
        os_unfair_lock_unlock(&storage.lock)
        
        if firstRun {
            scheduleSave()
        }
        
        logger.info("Configuration system initialized with \(moduleCount) modules")
    }
    
    // MARK: - 公共查询 API
    
    /// 检查模块是否启用（默认 false）
    public func isModuleEnabled(_ name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]?.enabled ?? false
    }
    
    /// 获取模块优先级（默认 100）
    public func getModulePriority(_ name: String) -> Int {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]?.priority ?? 100
    }
    
    /// 获取模块依赖列表（默认空数组）
    public func getModuleDependencies(_ name: String) -> [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]?.dependencies ?? []
    }
    
    /// 获取模块自定义配置项
    public func getCustomSetting(_ module: String, _ key: String) -> ConfigValue? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[module]?.customSettings[key]
    }
    
    // MARK: - 公共修改 API
    
    /// 设置模块启用状态
    public func setModuleEnabled(_ name: String, _ enabled: Bool) {
        os_unfair_lock_lock(&storage.lock)
        
        if var config = storage.modules[name] {
            config.enabled = enabled
            storage.modules[name] = config
        } else {
            storage.modules[name] = ModuleConfig(moduleName: name, enabled: enabled)
        }
        
        storage.needsSave = true
        let moduleName = name  // 提取值类型，在锁外使用
        os_unfair_lock_unlock(&storage.lock)
        
        scheduleSave()
        UserDefaults.standard.set(enabled, forKey: "XRZModule.\(moduleName).enabled")
        logger.info("模块 \(moduleName) 启用状态设置为 \(enabled)")
    }
    
    /// 设置模块优先级
    public func setModulePriority(_ name: String, _ priority: Int) {
        os_unfair_lock_lock(&storage.lock)
        
        if var config = storage.modules[name] {
            config.priority = priority
            storage.modules[name] = config
        } else {
            storage.modules[name] = ModuleConfig(moduleName: name, priority: priority)
        }
        
        storage.needsSave = true
        let moduleName = name
        os_unfair_lock_unlock(&storage.lock)
        
        scheduleSave()
        UserDefaults.standard.set(priority, forKey: "XRZModule.\(moduleName).priority")
        logger.info("模块 \(moduleName) 优先级设置为 \(priority)")
    }
    
    /// 设置模块自定义配置项
    public func setCustomSetting(_ module: String, _ key: String, _ value: ConfigValue) {
        os_unfair_lock_lock(&storage.lock)
        
        if var config = storage.modules[module] {
            config.customSettings[key] = value
            storage.modules[module] = config
        } else {
            storage.modules[module] = ModuleConfig(moduleName: module, customSettings: [key: value])
        }
        
        storage.needsSave = true
        let moduleName = module
        os_unfair_lock_unlock(&storage.lock)
        
        scheduleSave()
        logger.info("模块 \(moduleName) 自定义配置 [\(key)] = \(value)")
    }
    
    /// 注册/更新完整模块配置
    public func registerModule(_ config: ModuleConfig) {
        os_unfair_lock_lock(&storage.lock)
        
        storage.modules[config.moduleName] = config
        storage.needsSave = true
        let moduleName = config.moduleName
        os_unfair_lock_unlock(&storage.lock)
        
        scheduleSave()
        logger.info("已注册模块 \(moduleName)")
    }
    
    // MARK: - 辅助查询
    
    /// 获取所有已注册模块名称（按字母序）
    public func allModuleNames() -> [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return Array(storage.modules.keys).sorted()
    }
    
    /// 获取完整模块配置
    public func getModuleConfig(_ name: String) -> ModuleConfig? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.modules[name]
    }
    
    // MARK: - 内部加载方法（调用者必须已持有 lock）
    
    @discardableResult
    private func loadFromInfoPlistUnlocked() -> Int {
        guard let infoDict = Bundle.main.infoDictionary?["XRZModules"] as? [[String: Any]] else {
            logger.warning("No XRZModules key found in Info.plist, using empty defaults")
            return 0
        }
        var loadedCount = 0
        for dict in infoDict {
            guard let name = dict["moduleName"] as? String else { continue }
            
            let enabled = dict["enabled"] as? Bool ?? true
            let priority = dict["priority"] as? Int ?? 100
            let dependencies = dict["dependencies"] as? [String] ?? []
            
            var customSettings: [String: ConfigValue] = [:]
            if let settingsDict = dict["customSettings"] as? [String: Any] {
                for (key, value) in settingsDict {
                    if let configValue = ConfigValue.fromPlistValue(value) {
                        customSettings[key] = configValue
                    }
                }
            }
            
            let config = ModuleConfig(
                moduleName: name,
                enabled: enabled,
                priority: priority,
                dependencies: dependencies,
                customSettings: customSettings
            )
            storage.modules[name] = config
            loadedCount += 1
        }
        
        logger.info("Loaded \(loadedCount) module defaults from Info.plist")
        return loadedCount
    }
    
    private func loadFromDiskUnlocked() {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            logger.info("No persisted config file found at \(configFileURL.path)")
            return
        }
        
        do {
            let data = try Data(contentsOf: configFileURL)
            let decoder = JSONDecoder()
            let persisted = try decoder.decode([String: ModuleConfig].self, from: data)
            
            for (name, config) in persisted {
                storage.modules[name] = config
            }
            
            logger.info("Loaded \(persisted.count) modules from persisted config")
        } catch {
            logger.error("Failed to load persisted config: \(error)")
        }
    }
    
    private func loadFromUserDefaultsUnlocked() {
        let names = storage.modules.keys  // 先取 keys，避免遍历时修改字典
        var updatedCount = 0
        
        for name in names {
            guard var config = storage.modules[name] else { continue }
            let prefix = "XRZModule.\(name)."
            var modified = false
            
            if let enabled = UserDefaults.standard.object(forKey: "\(prefix)enabled") as? Bool {
                config.enabled = enabled
                modified = true
            }
            if let priority = UserDefaults.standard.object(forKey: "\(prefix)priority") as? Int {
                config.priority = priority
                modified = true
            }
            
            if modified {
                storage.modules[name] = config
                updatedCount += 1
            }
        }
        
        logger.info("Applied UserDefaults overrides for \(updatedCount) modules")
    }
    
    // MARK: - 异步持久化
    
    /// 调度异步保存，合并多次修改为一次写入
    /// 调用者负责在锁内先设置 storage.needsSave = true
    /// 本方法只安排异步写入，不碰 storage（不需要调用者持有锁）
    private func scheduleSave() {
        os_unfair_lock_lock(&saveLock)
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            os_unfair_lock_lock(&self.storage.lock)
            guard self.storage.needsSave else {
                os_unfair_lock_unlock(&self.storage.lock)
                return
            }
            self.storage.needsSave = false
            let modulesToSave = self.storage.modules
            os_unfair_lock_unlock(&self.storage.lock)
            
            self.performSave(modulesToSave)
        }
        pendingSaveWork = work
        os_unfair_lock_unlock(&saveLock)
        
        saveQueue.async(execute: work)
    }
    
    /// 执行实际的磁盘写入（在后台队列）
    private func performSave(_ modules: [String: ModuleConfig]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(modules)
            try data.write(to: configFileURL, options: [.atomic])
        } catch {
            logger.error("Failed to save configuration: \(error)")
        }
    }
    
    // MARK: - 测试辅助
    
    /// 重置所有配置（仅用于测试）
    public func resetForTests() {
        // 先取消待处理的保存任务（在 storage.lock 之外，避免锁嵌套）
        os_unfair_lock_lock(&saveLock)
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        os_unfair_lock_unlock(&saveLock)
        
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        storage.modules.removeAll()
        storage.needsSave = false
        storage.hasInitialized = false
        try? FileManager.default.removeItem(at: configFileURL)
        
        // 清理所有以 XRZModule. 开头的 UserDefaults 键
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("XRZModule.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        
        logger.info("Configuration reset for tests")
    }
}

// MARK: - 测试代码
public final class ConfigSystemTests {
    
    /// 运行所有配置系统测试
    public static func runAllTests() {
        testConfigValueCodable()
        testModuleConfigCodable()
        testBasicAPI()
        testPersistence()
        testThreadSafety()
        testUserDefaultsOverride()
        print("\n=== 全部配置系统测试通过 ✅ ===")
    }
    
    // MARK: - 测试1: ConfigValue 编码解码
    public static func testConfigValueCodable() {
        print("\n🧪 测试1: ConfigValue编码解码")
        
        let originalValues: [ConfigValue] = [
            .string("https://api.example.com"),
            .int(42),
            .double(3.14159),
            .bool(true),
            .stringArray(["BTC", "ETH", "SOL"])
        ]
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(originalValues)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode([ConfigValue].self, from: data)
            
            guard decoded == originalValues else {
                fatalError("❌ 测试1失败: 解码值不匹配\n   Original: \(originalValues)\n   Decoded:  \(decoded)")
            }
            print("✅ 测试1通过: ConfigValue编码解码正确")
        } catch {
            fatalError("❌ 测试1失败，错误: \(error)")
        }
    }
    
    // MARK: - 测试2: ModuleConfig 编码解码
    public static func testModuleConfigCodable() {
        print("\n🧪 测试2: ModuleConfig编码解码")
        
        let original = ModuleConfig(
            moduleName: "TestModule",
            enabled: true,
            priority: 50,
            dependencies: ["Core", "Network"],
            customSettings: [
                "apiUrl": .string("https://api.example.com"),
                "retryCount": .int(3),
                "useCache": .bool(true)
            ]
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(original)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ModuleConfig.self, from: data)
            
            guard decoded == original else {
                fatalError("❌ 测试2失败: 解码配置不匹配\n   Original: \(original)\n   Decoded:  \(decoded)")
            }
            print("✅ 测试2通过: ModuleConfig编码解码正确")
        } catch {
            fatalError("❌ 测试2失败，错误: \(error)")
        }
    }
    
    // MARK: - 测试3: ConfigSystem 基本 API
    public static func testBasicAPI() {
        print("\n🧪 测试3: 基本API")
        
        // 重置环境
        ConfigSystem.shared.resetForTests()
        
        // 注册测试模块
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "TradeModule",
            enabled: true,
            priority: 10,
            dependencies: ["CoreModule", "DataModule"],
            customSettings: [
                "exchange": .string("Binance"),
                "timeout": .int(30),
                "useSSL": .bool(true),
                "symbols": .stringArray(["BTC", "ETH"])
            ]
        ))
        
        // 测试查询方法
        let enabled = ConfigSystem.shared.isModuleEnabled("TradeModule")
        let priority = ConfigSystem.shared.getModulePriority("TradeModule")
        let deps = ConfigSystem.shared.getModuleDependencies("TradeModule")
        let exchange = ConfigSystem.shared.getCustomSetting("TradeModule", "exchange")
        let timeout = ConfigSystem.shared.getCustomSetting("TradeModule", "timeout")
        let useSSL = ConfigSystem.shared.getCustomSetting("TradeModule", "useSSL")
        let symbols = ConfigSystem.shared.getCustomSetting("TradeModule", "symbols")
        
        guard enabled == true else { fatalError("❌ 测试3失败: enabled应为true") }
        guard priority == 10 else { fatalError("❌ 测试3失败: priority应为10，实际 \(priority)") }
        guard deps == ["CoreModule", "DataModule"] else { fatalError("❌ 测试3失败: 依赖不匹配: \(deps)") }
        guard exchange?.stringValue == "Binance" else { fatalError("❌ 测试3失败: exchange应为Binance") }
        guard timeout?.intValue == 30 else { fatalError("❌ 测试3失败: timeout应为30") }
        guard useSSL?.boolValue == true else { fatalError("❌ 测试3失败: useSSL应为true") }
        guard symbols?.stringArrayValue == ["BTC", "ETH"] else { fatalError("❌ 测试3失败: symbols不匹配: \(symbols?.stringArrayValue ?? [])") }
        
        // 测试未知模块默认值
        let unknownEnabled = ConfigSystem.shared.isModuleEnabled("UnknownModule")
        let unknownPriority = ConfigSystem.shared.getModulePriority("UnknownModule")
        let unknownDeps = ConfigSystem.shared.getModuleDependencies("UnknownModule")
        let unknownSetting = ConfigSystem.shared.getCustomSetting("UnknownModule", "key")
        
        guard unknownEnabled == false else { fatalError("❌ 测试3失败: 未知模块应为禁用") }
        guard unknownPriority == 100 else { fatalError("❌ 测试3失败: 未知priority应为100，实际 \(unknownPriority)") }
        guard unknownDeps.isEmpty else { fatalError("❌ 测试3失败: 未知deps应为空，实际 \(unknownDeps)") }
        guard unknownSetting == nil else { fatalError("❌ 测试3失败: 未知设置应为nil") }
        
        // 测试 setModuleEnabled
        ConfigSystem.shared.setModuleEnabled("TradeModule", false)
        let disabled = ConfigSystem.shared.isModuleEnabled("TradeModule")
        guard disabled == false else { fatalError("❌ 测试3失败: setModuleEnabled失败") }
        
        // 测试 allModuleNames
        let names = ConfigSystem.shared.allModuleNames()
        guard names == ["TradeModule"] else { fatalError("❌ 测试3失败: allModuleNames不匹配: \(names)") }
        
        // 测试 getModuleConfig
        guard let config = ConfigSystem.shared.getModuleConfig("TradeModule") else {
            fatalError("❌ 测试3失败: getModuleConfig返回nil")
        }
        guard config.moduleName == "TradeModule" else { fatalError("❌ 测试3失败: getModuleConfig名称不匹配") }
        guard config.enabled == false else { fatalError("❌ 测试3失败: getModuleConfig enabled不匹配") }
        
        print("✅ 测试3通过: 所有API方法工作正常")
    }
    
    // MARK: - 测试4: 持久化到 JSON 文件
    public static func testPersistence() {
        print("\n🧪 测试4: 持久化到JSON")
        
        ConfigSystem.shared.resetForTests()
        
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "PersistModule",
            enabled: true,
            priority: 5,
            dependencies: ["Base"],
            customSettings: ["key": .string("value")]
        ))
        
        ConfigSystem.shared.setModuleEnabled("PersistModule", false)
        ConfigSystem.shared.setModulePriority("PersistModule", 99)
        ConfigSystem.shared.setCustomSetting("PersistModule", "newKey", .int(123))
        
        // 等待异步保存完成
        Thread.sleep(forTimeInterval: 0.5)
        
        // 验证文件存在
        let configFile = ConfigSystem.shared.configFileURL
        let exists = FileManager.default.fileExists(atPath: configFile.path)
        
        guard exists else {
            fatalError("❌ 测试4失败: 配置文件未找到于 \(configFile.path)")
        }
        
        // 验证文件内容可读
        do {
            let data = try Data(contentsOf: configFile)
            let decoded = try JSONDecoder().decode([String: ModuleConfig].self, from: data)
            
            guard let config = decoded["PersistModule"] else {
                fatalError("❌ 测试4失败: PersistModule未在JSON中找到")
            }
            
            guard config.enabled == false else { fatalError("❌ 测试4失败: 持久化enabled不匹配") }
            guard config.priority == 99 else { fatalError("❌ 测试4失败: 持久化priority不匹配") }
            guard config.dependencies == ["Base"] else { fatalError("❌ 测试4失败: 持久化deps不匹配") }
            guard config.customSettings["key"]?.stringValue == "value" else { fatalError("❌ 测试4失败: 持久化customSetting key不匹配") }
            guard config.customSettings["newKey"]?.intValue == 123 else { fatalError("❌ 测试4失败: 持久化customSetting newKey不匹配") }
            
            print("✅ 测试4通过: 配置已持久化并在JSON中验证")
        } catch {
            fatalError("❌ 测试4失败，读取/解析JSON: \(error)")
        }
    }
    
    // MARK: - 测试5: 线程安全
    public static func testThreadSafety() {
        print("\n🧪 测试5: 线程安全(os_unfair_lock)")
        
        ConfigSystem.shared.resetForTests()
        
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "ThreadModule",
            enabled: true,
            priority: 0
        ))
        
        let group = DispatchGroup()
        let threadCount = 50
        let operationsPerThread = 20
        
        for i in 0..<threadCount {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<operationsPerThread {
                    let enable = (i + j) % 2 == 0
                    ConfigSystem.shared.setModuleEnabled("ThreadModule", enable)
                    _ = ConfigSystem.shared.isModuleEnabled("ThreadModule")
                    _ = ConfigSystem.shared.getModulePriority("ThreadModule")
                    ConfigSystem.shared.setCustomSetting("ThreadModule", "counter", .int(i * 100 + j))
                }
                group.leave()
            }
        }
        
        group.wait()
        
        print("✅ 测试5通过: \(threadCount * operationsPerThread) concurrent operations completed without crash")
    }
    
    // MARK: - 测试6: UserDefaults 覆盖
    public static func testUserDefaultsOverride() {
        print("\n🧪 测试6: UserDefaults覆盖")
        
        ConfigSystem.shared.resetForTests()
        
        // 先注册模块
        ConfigSystem.shared.registerModule(ModuleConfig(
            moduleName: "OverrideModule",
            enabled: true,
            priority: 10
        ))
        
        // 直接设置 UserDefaults
        UserDefaults.standard.set(false, forKey: "XRZModule.OverrideModule.enabled")
        UserDefaults.standard.set(77, forKey: "XRZModule.OverrideModule.priority")
        
        // 重新初始化（会重新加载 UserDefaults）
        ConfigSystem.shared.initialize()
        
        let enabled = ConfigSystem.shared.isModuleEnabled("OverrideModule")
        let priority = ConfigSystem.shared.getModulePriority("OverrideModule")
        
        guard enabled == false else { fatalError("❌ 测试6失败: UserDefaults覆盖enabled失败，实际 \(enabled)") }
        guard priority == 77 else { fatalError("❌ 测试6失败: UserDefaults覆盖priority失败，实际 \(priority)") }
        
        print("✅ 测试6通过: UserDefaults覆盖正确应用")
        
        // 清理
        UserDefaults.standard.removeObject(forKey: "XRZModule.OverrideModule.enabled")
        UserDefaults.standard.removeObject(forKey: "XRZModule.OverrideModule.priority")
    }
}
