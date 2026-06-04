// 功能1: 主程序启动
// 对应: AppDelegate 或 @main 入口
// 优先级: P0 (最基础)

import Foundation
import AppKit

/// 应用程序主入口
/// 负责初始化框架并启动主事件循环
public final class XRZApplication {
    
    // MARK: - 单例
    public static let shared = XRZApplication()
    
    // MARK: - 核心组件
    private let moduleLoader: ModuleLoader
    private let moduleRegistry: ModuleRegistry
    private let eventBus: EventBus
    private let logger: ModuleLogger
    
    // MARK: - 状态
    private var isRunning = false
    private var mainWindow: NSWindow?
    
    // MARK: - 初始化
    private init() {
        self.logger = ModuleLogger(category: "App")
        self.eventBus = EventBus.shared
        self.moduleRegistry = ModuleRegistry.shared
        self.moduleLoader = ModuleLoader(
            registry: moduleRegistry,
            eventBus: eventBus,
            logger: logger
        )
    }
    
    // MARK: - 启动应用
    public func start() {
        guard !isRunning else {
            logger.warning("Application already running")
            return
        }
        
        logger.info("=== XianRenZhiLu Starting ===")
        
        // 1. 初始化日志系统 (功能2)
        initializeLogging()
        
        // 2. 初始化配置系统 (功能3)
        initializeConfiguration()
        
        // 3. 扫描并加载模块 (功能4,5,6)
        loadModules()
        
        // 4. 创建主窗口 (功能16)
        createMainWindow()
        
        isRunning = true
        logger.info("=== Application Started ===")
        
        // 发送启动完成事件
        eventBus.emit(ModuleEvent.applicationDidFinishLaunching)
    }
    
    // MARK: - 停止应用
    public func shutdown() {
        guard isRunning else { return }
        
        logger.info("=== Shutting Down ===")
        
        // 卸载所有模块
        moduleLoader.unloadAllModules()
        
        // 清理资源
        mainWindow?.close()
        mainWindow = nil
        
        isRunning = false
        logger.info("=== Shutdown Complete ===")
    }
    
    // MARK: - 私有方法
    private func initializeLogging() {
        // 委托给功能2实现
        LogSystem.shared.initialize()
    }
    
    private func initializeConfiguration() {
        // 委托给功能3实现
        ConfigSystem.shared.initialize()
    }
    
    private func loadModules() {
        let pluginPath = Bundle.main.bundlePath + "/Contents/PlugIns"
        moduleLoader.scanAndLoad(from: pluginPath)
    }
    
    private func createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "仙人指路"
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window
    }
}

// MARK: - AppDelegate (传统入口)
public final class XRZAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        XRZApplication.shared.start()
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        XRZApplication.shared.shutdown()
    }
}

// MARK: - @main 入口 (SwiftUI 风格)
@main
public struct XianRenZhiLuApp: App {
    @NSApplicationDelegateAdaptor(XRZAppDelegate.self) var appDelegate
    
    public init() {}
    
    public var body: some Scene {
        WindowGroup {
            EmptyView() // 实际窗口由 XRZApplication 管理
        }
    }
}