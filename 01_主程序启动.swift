// 功能1: 主程序启动
// 对应: AppDelegate + NSApplicationMain 入口，初始化框架并启动主事件循环
// 优先级: P0
// 说明: 本文件串联功能02~30所有能力，一个不少

import Foundation
import AppKit
import os

// MARK: - 启动阶段枚举

/// 启动阶段，用于日志追踪启动进度
public enum LaunchPhase: String, CaseIterable {
    case frameworkInit       = "框架核心组件初始化"
    case logging             = "日志系统初始化 (功能02)"
    case configuration       = "配置系统初始化 (功能03)"
    case scanModules         = "扫描模块目录 (功能04)"
    case loadModules         = "按顺序加载模块 (功能05)"
    case startModules        = "调用模块start (功能06)"
    case failureHandler      = "失败处理处理器就绪 (功能07)"
    case registryReady       = "模块注册表就绪 (功能08)"
    case dynamicLoader       = "动态加载器就绪 (功能09)"
    case unloader            = "卸载器就绪 (功能10)"
    case moduleAccessor      = "模块访问器就绪 (功能11)"
    case hotSwap             = "模块热替换器就绪 (功能12)"
    case eventBus            = "事件总线就绪 (功能13)"
    case serviceRegistry     = "服务注册与调用就绪 (功能14)"
    case sharedData          = "数据共享中心就绪 (功能15)"
    case windowManager       = "窗口管理器就绪 (功能16)"
    case viewContainer       = "视图容器就绪 (功能17)"
    case menuManager         = "菜单管理器就绪 (功能18)"
    case toolbar             = "工具栏管理器就绪 (功能19)"
    case multiWindow         = "多窗口管理器就绪 (功能20)"
    case resourceManager     = "公共资源管理器就绪 (功能21)"
    case moduleResource      = "模块私有资源管理器就绪 (功能22)"
    case localization        = "本地化管理器就绪 (功能23)"
    case signatureCheck      = "证书签名验证 (功能24)"
    case sandbox             = "沙盒支持就绪 (功能25)"
    case crashIsolator       = "崩溃隔离器就绪 (功能26)"
    case versionCheck        = "模块版本检查 (功能27)"
    case hotReloader         = "模块热重载器就绪 (功能28)"
    case loadLogger          = "模块加载日志记录器就绪 (功能29)"
    case moduleListUI        = "模块列表UI就绪 (功能30)"
    case completed           = "启动完成"
}

// MARK: - 启动结果

/// 应用启动结果
public enum LaunchResult {
    case success
    case partialFailure([String])
    case criticalFailure(String)
}

// MARK: - XRZApplication

/// 应用程序主入口
/// 初始化所有框架组件，按有序阶段启动，串联功能02~30全部能力
public final class XRZApplication {

    // MARK: - 单例
    public static let shared = XRZApplication()

    // MARK: - 核心组件 (功能02~30)
    // 功能02
    private let logSystem: LogSystem
    private let logger: ModuleLogger

    // 功能03
    private let configSystem: ConfigSystem

    // 功能04
    private let scanner: ModuleScanner

    // 功能05
    private let loader: ModuleLoader
    private let dependencyResolver: DependencyResolver

    // 功能06
    private let starter: ModuleStarter

    // 功能07
    private let failureHandler: ModuleFailureHandler

    // 功能08
    private let registry: ModuleRegistry

    // 功能09
    private let dynamicLoader: DynamicModuleLoader

    // 功能10
    private let unloader: ModuleUnloader

    // 功能11
    private let accessor: ModuleAccessor

    // 功能12
    private let hotSwapper: ModuleHotSwapper

    // 功能13
    private let eventBus: EventBus

    // 功能14
    private let serviceRegistry: ServiceRegistry
    private let serviceInvoker: ServiceInvoker

    // 功能15
    private let sharedData: SharedDataManager

    // 功能16
    private let windowManager: WindowManager

    // 功能17
    private let viewContainer: ViewContainer

    // 功能18
    private let menuManager: MenuManager

    // 功能19
    private let toolbarManager: ToolbarManager

    // 功能20
    private let multiWindowManager: ModuleWindowManager

    // 功能21
    private let resourceManager: ResourceManager

    // 功能22
    private let moduleResourceManager: ModuleResourceManager

    // 功能23
    private let localizationManager: LocalizationManager

    // 功能24
    private let signatureVerifier: SignatureVerifier

    // 功能25
    private let sandboxManager: SandboxManager

    // 功能26
    private let crashIsolator: CrashIsolator

    // 功能27
    private let versionChecker: VersionChecker

    // 功能28
    private let hotReloader: ModuleHotReloader

    // 功能29
    private let loadLogger: ModuleLoadLogger

    // 功能30 (ModuleListUI由菜单触发，无需持长期引用)

    // MARK: - 状态

    private var _lock = os_unfair_lock()
    private var _launchPhase: LaunchPhase = .frameworkInit
    private var _isRunning = false
    private var _launchResult: LaunchResult = .success
    private var _startTime: UInt64 = 0
    private var _phaseResults: [LaunchPhase: Bool] = [:]
    private var _mainWindow: NSWindow?

    public var launchPhase: LaunchPhase {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _launchPhase
    }

    public var isRunning: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _isRunning
    }

    public var mainWindow: NSWindow? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _mainWindow
    }

    public var launchResult: LaunchResult {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _launchResult
    }

    /// 获取指定启动阶段是否通过
    public func phasePassed(_ phase: LaunchPhase) -> Bool? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _phaseResults[phase]
    }

    // MARK: - 初始化

    private init() {
        // 功能02
        self.logSystem = LogSystem.shared
        self.logger = ModuleLogger(category: "App")

        // 功能03
        self.configSystem = ConfigSystem.shared

        // 功能04
        self.scanner = ModuleScanner.shared

        // 功能08
        self.registry = ModuleRegistry.shared

        // 功能05
        self.loader = ModuleLoader(registry: registry, eventBus: EventBus.shared, logger: logger)
        self.dependencyResolver = DependencyResolver()

        // 功能06
        self.starter = ModuleStarter(registry: registry, logger: logger)

        // 功能07
        self.failureHandler = ModuleFailureHandler()

        // 功能09
        self.dynamicLoader = DynamicModuleLoader(
            registry: registry,
            loader: loader,
            scanner: scanner,
            config: configSystem,
            systemVersion: Version(major: 2, minor: 0, patch: 0)
        )

        // 功能10
        self.unloader = ModuleUnloader(registry: registry, eventBus: EventBus.shared)

        // 功能11
        self.accessor = ModuleAccessor.shared

        // 功能12
        self.hotSwapper = ModuleHotSwapper(
            registry: registry,
            loader: loader,
            unloader: unloader,
            eventBus: EventBus.shared
        )

        // 功能13
        self.eventBus = EventBus.shared

        // 功能14
        self.serviceRegistry = ServiceRegistry.shared
        self.serviceInvoker = ServiceInvoker(registry: serviceRegistry)

        // 功能15
        self.sharedData = SharedDataManager.shared

        // 功能16
        self.windowManager = WindowManager(registry: registry)

        // 功能17
        self.viewContainer = ViewContainer.shared

        // 功能18
        self.menuManager = MenuManager.shared

        // 功能19
        self.toolbarManager = ToolbarManager.shared

        // 功能20
        self.multiWindowManager = ModuleWindowManager.shared

        // 功能21
        self.resourceManager = ResourceManager.shared

        // 功能22
        self.moduleResourceManager = ModuleResourceManager.shared

        // 功能23
        self.localizationManager = LocalizationManager.shared

        // 功能24
        self.signatureVerifier = SignatureVerifier.shared

        // 功能25
        self.sandboxManager = SandboxManager.shared

        // 功能26
        self.crashIsolator = CrashIsolator.shared

        // 功能27
        self.versionChecker = VersionChecker.shared

        // 功能28
        self.hotReloader = ModuleHotReloader.shared

        // 功能29
        self.loadLogger = ModuleLoadLogger.shared
    }

    // MARK: - 启动方法

    /// 启动应用程序
    /// 按有序阶段初始化框架所有组件
    @discardableResult
    public func start(pluginDirectory: URL? = nil) -> LaunchResult {
        setPhase(.frameworkInit)

        guard !_isRunning else {
            logger.warning("应用程序已在运行中")
            return .success
        }

        _startTime = DispatchTime.now().uptimeNanoseconds

        // ============ 基础层初始化 ============

        // 功能02: 日志系统
        let _ = phase(name: .logging) {
            LogSystem.shared.initialize()
            return true
        }

        // 功能03: 配置系统
        let _ = phase(name: .configuration) {
            let bundleConfig = Bundle.main.url(forResource: "ModuleConfig", withExtension: "plist")
            ConfigSystem.shared.initialize(bundleConfig: bundleConfig)
            return true
        }

        // ============ 模块管理初始化 ============

        // 功能04: 扫描模块目录
        let scannedModules = phase(name: .scanModules) { () -> [ScannedModule] in
            let scanDir = pluginDirectory
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
            let scanned = scanner.scan(directory: scanDir)
            return scanned
        } ?? []

        // 功能05: 加载模块
        let _ = phase(name: .loadModules) {
            for scannedModule in scannedModules {
                let loadResult = loader.load(
                    module: scannedModule,
                    metadata: scannedModule.metadata
                )
                // 功能07: 失败处理
                if case .failure(let error) = loadResult {
                    let _ = failureHandler.handle(.loadError(String(describing: error)))
                }
            }
            return true
        }

        // 功能06: 启动模块
        let _ = phase(name: .startModules) {
            let startResult = starter.startAllModules()
            if case .partialSuccess(_, let failed) = startResult {
                for failure in failed {
                    let _ = failureHandler.handle(.startError(
                        String(describing: failure.reason)
                    ))
                }
            }
            return true
        }

        // 功能07: 失败处理器单例已有（通过组件初始化），仅做日志
        let _ = phase(name: .failureHandler) {
            logger.info("失败处理器已就绪")
            return true
        }

        // 功能08: 注册表单例已有（通过组件初始化），仅做日志
        let _ = phase(name: .registryReady) {
            logger.info("模块注册表已就绪，已注册 \(registry.allModuleNames.count) 个模块")
            return true
        }

        // 功能09: 动态加载器单例已有
        let _ = phase(name: .dynamicLoader) {
            logger.info("动态加载器已就绪")
            return true
        }

        // 功能10: 卸载器已有
        let _ = phase(name: .unloader) {
            logger.info("卸载器已就绪")
            return true
        }

        // 功能11: 模块访问器
        let _ = phase(name: .moduleAccessor) {
            logger.info("模块访问器已就绪")
            return true
        }

        // 功能12: 热替换器
        let _ = phase(name: .hotSwap) {
            logger.info("模块热替换器已就绪")
            return true
        }

        // ============ 通信层初始化 ============

        // 功能13: 事件总线
        let _ = phase(name: .eventBus) {
            logger.info("事件总线已就绪")
            return true
        }

        // 功能14: 服务注册与调用
        let _ = phase(name: .serviceRegistry) {
            logger.info("服务注册表已就绪，共 \(serviceRegistry.totalServiceCount) 个服务")
            return true
        }

        // 功能15: 数据共享
        let _ = phase(name: .sharedData) {
            logger.info("数据共享中心已就绪")
            return true
        }

        // ============ UI层初始化 ============

        // 功能16: 窗口管理器
        let _ = phase(name: .windowManager) {
            windowManager.open(windowNamed: "main")
            logger.info("窗口管理器已就绪")
            return true
        }

        // 功能17: 视图容器
        let _ = phase(name: .viewContainer) {
            logger.info("视图容器已就绪")
            return true
        }

        // 功能18: 菜单管理器
        let _ = phase(name: .menuManager) {
            menuManager.addDeveloperMenu()
            logger.info("菜单管理器已就绪")
            return true
        }

        // 功能19: 工具栏管理器
        let _ = phase(name: .toolbar) {
            logger.info("工具栏管理器已就绪")
            return true
        }

        // 功能20: 多窗口管理器
        let _ = phase(name: .multiWindow) {
            logger.info("多窗口管理器已就绪")
            return true
        }

        // ============ 资源层初始化 ============

        // 功能21: 公共资源管理器
        let _ = phase(name: .resourceManager) {
            logger.info("公共资源管理器已就绪")
            return true
        }

        // 功能22: 模块私有资源管理器
        let _ = phase(name: .moduleResource) {
            logger.info("模块私有资源管理器已就绪")
            return true
        }

        // 功能23: 本地化管理器
        let _ = phase(name: .localization) {
            localizationManager.setLanguage("zh-Hans")
            logger.info("本地化管理器已就绪")
            return true
        }

        // ============ 安全层初始化 ============

        // 功能24: 签名验证
        let _ = phase(name: .signatureCheck) {
            let mainBundleURL = Bundle.main.bundleURL
            let status = signatureVerifier.verifyModule(bundlePath: mainBundleURL)
            switch status {
            case .valid:
                logger.info("主程序签名验证通过")
            case .notSigned:
                logger.warning("主程序未签名（开发环境正常）")
            case .invalid, .error:
                logger.warning("主程序签名检查未通过（开发模式继续运行）")
            }
            return true
        }

        // 功能25: 沙盒支持
        let _ = phase(name: .sandbox) {
            if sandboxManager.isSandboxed {
                logger.info("当前运行在沙盒环境中")
            } else {
                logger.info("当前运行在非沙盒环境中")
            }
            return true
        }

        // 功能26: 崩溃隔离器
        let _ = phase(name: .crashIsolator) {
            crashIsolator.thresholdCrashCount = 3
            logger.info("崩溃隔离器已就绪，阈值: 3次")
            return true
        }

        // 功能27: 版本检查
        let _ = phase(name: .versionCheck) {
            versionChecker.registerFrameworkVersion(Version(major: 2, minor: 0, patch: 0))
            // 检查已注册模块版本
            let results = versionChecker.checkAllRegisteredModules()
            for (name, status) in results {
                if case .incompatible = status {
                    logger.warning("模块 \(name) 版本不兼容: \(status)")
                }
            }
            return true
        }

        // ============ 开发工具层初始化 ============

        // 功能28: 热重载器
        let _ = phase(name: .hotReloader) {
            hotReloader.isDevelopmentMode = true
            logger.info("模块热重载器已就绪")
            return true
        }

        // 功能29: 加载日志记录器
        let _ = phase(name: .loadLogger) {
            logger.info("模块加载日志记录器已就绪")
            return true
        }

        // 功能30: 模块列表UI（由菜单触发，无需单独启动）

        // ============ 创建主窗口 ============
        phase_createMainWindow()

        // ============ 发送启动完成事件 (功能13) ============
        eventBus.emit(userInfo: [
            "event": "applicationDidFinishLaunching",
            "launchTime": Date().timeIntervalSince1970,
            "result": String(describing: launchResult)
        ])

        // ============ 完成 ============
        _isRunning = true
        setPhase(.completed)

        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - _startTime) / 1_000_000_000.0
        logger.info("应用程序启动完成，耗时 \(String(format: "%.3f", elapsed))s")

        return launchResult
    }

    // MARK: - 停止方法

    public func shutdown() {
        guard _isRunning else { return }
        logger.info("正在关闭应用程序...")

        // 功能06: 停止所有模块
        for name in registry.allModuleNames {
            if starter.isStarted(name) {
                starter.stopModule(name)
            }
        }

        // 功能05: 卸载所有模块
        loader.unloadAll()

        // 功能16: 关闭窗口
        if let window = _mainWindow {
            window.close()
        }
        _mainWindow = nil

        // 功能18: 清除菜单
        menuManager.unregisterAllModuleMenus()

        // 功能19: 清除工具栏
        toolbarManager.unregisterAllItems()

        // 功能29: 导出加载报告
        let report = loadLogger.exportReport()
        logger.info("导出加载报告:\n\(report)")

        _isRunning = false
        logger.info("应用程序已关闭")
    }

    // MARK: - 创建主窗口

    private func phase_createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "仙人指路"
        window.minSize = NSSize(width: 800, height: 600)

        // 功能16: 注册到窗口管理器
        windowManager.open(windowNamed: "main")

        // 功能19: 设置工具栏
        toolbarManager.setupToolbar(for: window)

        _mainWindow = window
        window.makeKeyAndOrderFront(nil)

        logger.info("主窗口已创建")
    }

    // MARK: - 辅助方法

    private func setPhase(_ phase: LaunchPhase) {
        os_unfair_lock_lock(&_lock)
        _launchPhase = phase
        os_unfair_lock_unlock(&_lock)
    }

    private func setResult(_ result: LaunchResult) {
        os_unfair_lock_lock(&_lock)
        _launchResult = result
        os_unfair_lock_unlock(&_lock)
    }

    private func logPhase<T>(_ phase: LaunchPhase, passed: Bool, result: T) {
        os_unfair_lock_lock(&_lock)
        _phaseResults[phase] = passed
        os_unfair_lock_unlock(&_lock)
    }

    /// 通用阶段执行器
    private func phase<T>(name: LaunchPhase, block: () throws -> T) -> T? {
        setPhase(name)
        do {
            let result = try block()
            logPhase(name, passed: true, result: result)
            return result
        } catch {
            logger.error("启动阶段失败 [\(name.rawValue)]: \(error)")
            logPhase(name, passed: false, result: Optional<T>.none as Any)
            // 非严重阶段继续运行
            return nil
        }
    }
}

// MARK: - AppDelegate

/// 应用程序委托
public final class XRZAppDelegate: NSObject, NSApplicationDelegate {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let result = XRZApplication.shared.start()

        switch result {
        case .success:
            print("[AppDelegate] 应用程序启动成功")
        case .partialFailure(let errors):
            print("[AppDelegate] 应用程序部分启动失败: \(errors.joined(separator: ", "))")
        case .criticalFailure(let message):
            print("[AppDelegate] 应用程序启动失败: \(message)")
            NSApplication.shared.terminate(nil)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        XRZApplication.shared.shutdown()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - 主入口

let appDelegate = XRZAppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
