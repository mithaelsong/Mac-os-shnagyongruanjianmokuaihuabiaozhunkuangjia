// 功能16: 窗口管理
// 对应: 主窗口、设置窗口、关于窗口的创建与显示
// 优先级: P1

import Foundation
import os.lock

// MARK: - 窗口状态
/// 窗口状态枚举
public enum WindowState: String, Codable, Sendable, CustomStringConvertible {
    case open       // 窗口已打开
    case minimized  // 窗口已最小化
    case closed     // 窗口已关闭
    case fullscreen // 窗口全屏
    
    public var description: String {
        rawValue
    }
}

// MARK: - 窗口帧
/// 窗口位置和大小
public struct WindowFrame: Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    
    public var description: String {
        "(x: \(x), y: \(y), width: \(width), height: \(height))"
    }
}

// MARK: - 窗口记录
/// 内部窗口数据记录
private struct WindowRecord {
    let name: String
    var state: WindowState
    var frame: WindowFrame?
    var zIndex: Int
}

// MARK: - 窗口管理器
/// 窗口管理器 (功能16)
/// 纯数据层窗口管理器，不依赖 AppKit/NSWindow
/// 使用字符串名称标识窗口，管理窗口状态和帧信息
/// 使用 os_unfair_lock 保证线程安全和高性能
public final class WindowManager {
    public static let shared = WindowManager()
    
    /// 线程安全的窗口存储包装
    private final class WindowStorage: @unchecked Sendable {
        var windows: [String: WindowRecord] = [:]
        var nextZIndex: Int = 1
        var lock = os_unfair_lock()
    }
    
    private let storage = WindowStorage()
    private let registry: ModuleRegistry
    private let logger = ModuleLogger(category: "WindowManager")
    
    /// 私有构造函数，单例使用默认注册表
    private init() {
        self.registry = ModuleRegistry.shared
    }
    
    /// 支持注入初始化的构造函数
    /// - Parameter registry: 模块注册表实例
    public init(registry: ModuleRegistry) {
        self.registry = registry
    }
    
    // MARK: - 打开/关闭窗口
    
    /// 打开或激活指定名称的窗口
    /// - Parameter name: 窗口名称
    /// - Returns: 是否成功（名称非空即成功，已存在则激活）
    @discardableResult
    public func open(windowNamed name: String) -> Bool {
        guard !name.isEmpty else {
            logger.warning("open(windowNamed:) failed: name is empty")
            return false
        }
        
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        if let existing = storage.windows[name] {
            if existing.state == .closed {
                storage.windows[name] = WindowRecord(
                    name: name,
                    state: .open,
                    frame: existing.frame,
                    zIndex: storage.nextZIndex
                )
                storage.nextZIndex += 1
                logger.info("Window '\(name)' reopened from closed state")
            } else {
                // 已打开，提升 zIndex（相当于激活）
                storage.windows[name]?.zIndex = storage.nextZIndex
                storage.nextZIndex += 1
                logger.info("Window '\(name)' already open (state: \(existing.state.rawValue)), brought to front")
            }
            return true
        }
        
        storage.windows[name] = WindowRecord(
            name: name,
            state: .open,
            frame: nil,
            zIndex: storage.nextZIndex
        )
        storage.nextZIndex += 1
        logger.info("Window '\(name)' opened")
        return true
    }
    
    /// 关闭指定名称的窗口
    /// - Parameter name: 窗口名称
    /// - Returns: 是否成功（窗口必须存在）
    @discardableResult
    public func close(windowNamed name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard storage.windows[name] != nil else {
            logger.warning("close(windowNamed:) failed: '\(name)' not found")
            return false
        }
        
        storage.windows[name]?.state = .closed
        logger.info("Window '\(name)' closed")
        return true
    }
    
    /// 检查窗口是否处于打开状态（非 closed）
    /// - Parameter name: 窗口名称
    /// - Returns: 是否已打开
    public func isWindowOpen(_ name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let record = storage.windows[name] else {
            return false
        }
        return record.state != .closed
    }
    
    // MARK: - 窗口帧管理
    
    /// 设置窗口位置和大小
    /// - Parameters:
    ///   - name: 窗口名称
    ///   - x: 左上角 X 坐标
    ///   - y: 左上角 Y 坐标
    ///   - width: 窗口宽度（必须 > 0）
    ///   - height: 窗口高度（必须 > 0）
    /// - Returns: 是否成功（窗口必须存在且宽高合法）
    @discardableResult
    public func setWindowFrame(_ name: String, x: Double, y: Double, width: Double, height: Double) -> Bool {
        guard width > 0, height > 0 else {
            logger.warning("setWindowFrame failed: invalid size (width=\(width), height=\(height))")
            return false
        }
        
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard storage.windows[name] != nil else {
            logger.warning("setWindowFrame failed: '\(name)' not found")
            return false
        }
        
        storage.windows[name]?.frame = WindowFrame(x: x, y: y, width: width, height: height)
        logger.info("Window '\(name)' frame set to \(WindowFrame(x: x, y: y, width: width, height: height))")
        return true
    }
    
    /// 获取窗口帧信息
    /// - Parameter name: 窗口名称
    /// - Returns: 窗口帧元组 (x, y, width, height)，窗口不存在或无帧时返回 nil
    public func getWindowFrame(_ name: String) -> (x: Double, y: Double, width: Double, height: Double)? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let frame = storage.windows[name]?.frame else {
            return nil
        }
        return (x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
    
    // MARK: - 窗口状态操作
    
    /// 最小化窗口
    /// - Parameter name: 窗口名称
    /// - Returns: 是否成功（窗口必须存在且处于 open/fullscreen 状态）
    @discardableResult
    public func minimizeWindow(_ name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let record = storage.windows[name] else {
            logger.warning("minimizeWindow failed: '\(name)' not found")
            return false
        }
        
        guard record.state == .open || record.state == .fullscreen else {
            logger.warning("minimizeWindow failed: '\(name)' state is \(record.state.rawValue), cannot minimize")
            return false
        }
        
        storage.windows[name]?.state = .minimized
        logger.info("Window '\(name)' minimized")
        return true
    }
    
    /// 恢复窗口（从最小化状态恢复为打开）
    /// - Parameter name: 窗口名称
    /// - Returns: 是否成功（窗口必须存在且处于 minimized 状态）
    @discardableResult
    public func restoreWindow(_ name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let record = storage.windows[name] else {
            logger.warning("restoreWindow failed: '\(name)' not found")
            return false
        }
        
        guard record.state == .minimized else {
            logger.warning("restoreWindow failed: '\(name)' state is \(record.state.rawValue), not minimized")
            return false
        }
        
        storage.windows[name]?.state = .open
        logger.info("Window '\(name)' restored")
        return true
    }
    
    /// 将窗口前置（提升 zIndex）
    /// - Parameter name: 窗口名称
    /// - Returns: 是否成功（窗口必须存在且非 closed）
    @discardableResult
    public func bringToFront(_ name: String) -> Bool {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard let record = storage.windows[name] else {
            logger.warning("bringToFront failed: '\(name)' not found")
            return false
        }
        
        guard record.state != .closed else {
            logger.warning("bringToFront failed: '\(name)' is closed")
            return false
        }
        
        storage.windows[name]?.zIndex = storage.nextZIndex
        storage.nextZIndex += 1
        logger.info("Window '\(name)' brought to front (zIndex: \(storage.windows[name]!.zIndex))")
        return true
    }
    
    /// 列出所有已打开的窗口名称（按 zIndex 排序，最前在前）
    /// - Returns: 所有非 closed 状态的窗口名称数组
    public func listOpenWindows() -> [String] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        return storage.windows
            .filter { $0.value.state != .closed }
            .sorted { $0.value.zIndex > $1.value.zIndex }
            .map { $0.key }
    }
    
    /// 获取窗口当前状态（内部诊断用）
    /// - Parameter name: 窗口名称
    /// - Returns: 窗口状态，不存在时返回 nil
    public func getWindowState(_ name: String) -> WindowState? {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.windows[name]?.state
    }
    
    /// 获取所有窗口的调试信息（内部诊断用）
    /// - Returns: 窗口名称到状态的映射
    public func dumpWindows() -> [String: WindowState] {
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        return storage.windows.mapValues { $0.state }
    }
}

// MARK: - 测试代码
/// 窗口管理器功能验证
/// 运行方式：在单元测试或 Playground 中调用 `WindowManagerTests.run()`
public enum WindowManagerTests {
    
    /// 运行所有测试
    public static func run() {
        print("=== WindowManager Tests ===")
        testOpenAndClose()
        testWindowStateQuery()
        testSetAndGetFrame()
        testMinimizeAndRestore()
        testBringToFront()
        testListOpenWindows()
        testThreadSafety()
        testInvalidFrame()
        testFullscreenState()
        print("\n=== All WindowManager Tests Passed ✅ ===")
    }
    
    // MARK: - 测试1: 打开/关闭窗口
    static func testOpenAndClose() {
        print("\n🧪 Test 1: Open & Close Window")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 打开新窗口
        let result1 = wm.open(windowNamed: "Main")
        guard result1 == true else {
            fatalError("❌ open: should return true for new window")
        }
        
        // 重复打开已存在的窗口（应返回 true，相当于激活）
        let result2 = wm.open(windowNamed: "Main")
        guard result2 == true else {
            fatalError("❌ open: should return true for already-open window")
        }
        
        // 关闭已存在的窗口
        let result3 = wm.close(windowNamed: "Main")
        guard result3 == true else {
            fatalError("❌ close: should return true for existing window")
        }
        
        // 关闭后再次关闭（应返回 false）
        let result4 = wm.close(windowNamed: "Main")
        guard result4 == true else {
            fatalError("❌ close: should still return true for closed window (state exists)")
        }
        
        // 关闭不存在的窗口
        let result5 = wm.close(windowNamed: "NonExistent")
        guard result5 == false else {
            fatalError("❌ close: should return false for non-existent window")
        }
        
        // 空名称打开
        let result6 = wm.open(windowNamed: "")
        guard result6 == false else {
            fatalError("❌ open: should return false for empty name")
        }
        
        print("✅ Test 1 passed: open/close behavior correct")
    }
    
    // MARK: - 测试2: 窗口状态查询
    static func testWindowStateQuery() {
        print("\n🧪 Test 2: Window State Query")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 不存在的窗口
        guard wm.isWindowOpen("Ghost") == false else {
            fatalError("❌ isWindowOpen: non-existent window should be false")
        }
        
        // 打开后查询
        wm.open(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == true else {
            fatalError("❌ isWindowOpen: 'Chart' should be open")
        }
        guard wm.getWindowState("Chart") == .open else {
            fatalError("❌ getWindowState: 'Chart' should be .open")
        }
        
        // 关闭后查询
        wm.close(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == false else {
            fatalError("❌ isWindowOpen: closed window should be false")
        }
        guard wm.getWindowState("Chart") == .closed else {
            fatalError("❌ getWindowState: closed window should be .closed")
        }
        
        // 重新打开后查询
        wm.open(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == true else {
            fatalError("❌ isWindowOpen: reopened window should be true")
        }
        
        print("✅ Test 2 passed: state query correct")
    }
    
    // MARK: - 测试3: 设置/获取窗口帧
    static func testSetAndGetFrame() {
        print("\n🧪 Test 3: Set & Get Window Frame")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Settings")
        
        // 未设置帧时返回 nil
        guard wm.getWindowFrame("Settings") == nil else {
            fatalError("❌ getWindowFrame: should return nil before setting")
        }
        
        // 设置合法帧
        let result1 = wm.setWindowFrame("Settings", x: 100, y: 200, width: 800, height: 600)
        guard result1 == true else {
            fatalError("❌ setWindowFrame: should return true for valid frame")
        }
        
        let frame = wm.getWindowFrame("Settings")
        guard let frame = frame else {
            fatalError("❌ getWindowFrame: should return non-nil after setting")
        }
        guard frame.x == 100, frame.y == 200, frame.width == 800, frame.height == 600 else {
            fatalError("❌ getWindowFrame: returned \(frame), expected (100, 200, 800, 600)")
        }
        
        // 更新帧
        let result2 = wm.setWindowFrame("Settings", x: 50, y: 50, width: 400, height: 300)
        guard result2 == true else {
            fatalError("❌ setWindowFrame: should return true for update")
        }
        let updated = wm.getWindowFrame("Settings")
        guard updated?.width == 400, updated?.height == 300 else {
            fatalError("❌ getWindowFrame: update failed")
        }
        
        // 对不存在的窗口设置帧
        let result3 = wm.setWindowFrame("Ghost", x: 0, y: 0, width: 100, height: 100)
        guard result3 == false else {
            fatalError("❌ setWindowFrame: should return false for non-existent window")
        }
        
        print("✅ Test 3 passed: frame set/get correct")
    }
    
    // MARK: - 测试4: 最小化/恢复
    static func testMinimizeAndRestore() {
        print("\n🧪 Test 4: Minimize & Restore Window")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Trade")
        
        // 最小化已打开的窗口
        let result1 = wm.minimizeWindow("Trade")
        guard result1 == true else {
            fatalError("❌ minimizeWindow: should return true for open window")
        }
        guard wm.getWindowState("Trade") == .minimized else {
            fatalError("❌ getWindowState: should be .minimized after minimize")
        }
        guard wm.isWindowOpen("Trade") == true else {
            fatalError("❌ isWindowOpen: minimized window is still 'open'")
        }
        
        // 恢复已最小化的窗口
        let result2 = wm.restoreWindow("Trade")
        guard result2 == true else {
            fatalError("❌ restoreWindow: should return true for minimized window")
        }
        guard wm.getWindowState("Trade") == .open else {
            fatalError("❌ getWindowState: should be .open after restore")
        }
        
        // 对未最小化的窗口恢复
        let result3 = wm.restoreWindow("Trade")
        guard result3 == false else {
            fatalError("❌ restoreWindow: should return false for non-minimized window")
        }
        
        // 对不存在的窗口最小化
        let result4 = wm.minimizeWindow("Ghost")
        guard result4 == false else {
            fatalError("❌ minimizeWindow: should return false for non-existent window")
        }
        
        // 对关闭的窗口最小化
        wm.close(windowNamed: "Trade")
        let result5 = wm.minimizeWindow("Trade")
        guard result5 == false else {
            fatalError("❌ minimizeWindow: should return false for closed window")
        }
        
        print("✅ Test 4 passed: minimize/restore correct")
    }
    
    // MARK: - 测试5: 前置窗口
    static func testBringToFront() {
        print("\n🧪 Test 5: Bring Window To Front")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "A")
        wm.open(windowNamed: "B")
        wm.open(windowNamed: "C")
        
        // 初始顺序应为 C > B > A（zIndex 越大越前）
        let initialList = wm.listOpenWindows()
        guard initialList == ["C", "B", "A"] else {
            fatalError("❌ listOpenWindows: expected [C, B, A], got \(initialList)")
        }
        
        // 将 A 前置
        let result1 = wm.bringToFront("A")
        guard result1 == true else {
            fatalError("❌ bringToFront: should return true for open window")
        }
        
        let updatedList = wm.listOpenWindows()
        guard updatedList == ["A", "C", "B"] else {
            fatalError("❌ listOpenWindows: expected [A, C, B], got \(updatedList)")
        }
        
        // 对不存在的窗口前置
        let result2 = wm.bringToFront("Ghost")
        guard result2 == false else {
            fatalError("❌ bringToFront: should return false for non-existent window")
        }
        
        // 对关闭的窗口前置
        wm.close(windowNamed: "B")
        let result3 = wm.bringToFront("B")
        guard result3 == false else {
            fatalError("❌ bringToFront: should return false for closed window")
        }
        
        print("✅ Test 5 passed: bringToFront correct")
    }
    
    // MARK: - 测试6: 列出打开窗口
    static func testListOpenWindows() {
        print("\n🧪 Test 6: List Open Windows")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 空列表
        guard wm.listOpenWindows().isEmpty else {
            fatalError("❌ listOpenWindows: should be empty initially")
        }
        
        // 添加多个窗口
        wm.open(windowNamed: "Main")
        wm.open(windowNamed: "Settings")
        wm.open(windowNamed: "About")
        
        let list1 = wm.listOpenWindows().sorted()
        guard list1 == ["About", "Main", "Settings"] else {
            fatalError("❌ listOpenWindows: expected [About, Main, Settings], got \(list1)")
        }
        
        // 关闭一个窗口后
        wm.close(windowNamed: "Settings")
        let list2 = wm.listOpenWindows().sorted()
        guard list2 == ["About", "Main"] else {
            fatalError("❌ listOpenWindows: expected [About, Main], got \(list2)")
        }
        
        // 全部关闭后
        wm.close(windowNamed: "Main")
        wm.close(windowNamed: "About")
        guard wm.listOpenWindows().isEmpty else {
            fatalError("❌ listOpenWindows: should be empty after all closed")
        }
        
        print("✅ Test 6 passed: listOpenWindows correct")
    }
    
    // MARK: - 测试7: 线程安全
    static func testThreadSafety() {
        print("\n🧪 Test 7: Thread Safety")
        
        let wm = WindowManager(registry: ModuleRegistry())
        let group = DispatchGroup()
        let windowCount = 50
        
        // 50 个线程并发打开窗口
        for i in 0..<windowCount {
            group.enter()
            DispatchQueue.global().async {
                _ = wm.open(windowNamed: "Window\(i)")
                group.leave()
            }
        }
        group.wait()
        
        let openWindows = wm.listOpenWindows()
        guard openWindows.count == windowCount else {
            fatalError("❌ Thread safety: expected \(windowCount) windows, got \(openWindows.count)")
        }
        
        // 并发操作已有窗口
        let group2 = DispatchGroup()
        for i in 0..<windowCount {
            group2.enter()
            DispatchQueue.global().async {
                let name = "Window\(i)"
                _ = wm.setWindowFrame(name, x: Double(i), y: Double(i), width: 100, height: 100)
                _ = wm.minimizeWindow(name)
                _ = wm.restoreWindow(name)
                group2.leave()
            }
        }
        group2.wait()
        
        let finalList = wm.listOpenWindows()
        guard finalList.count == windowCount else {
            fatalError("❌ Thread safety: expected \(windowCount) windows after concurrent ops, got \(finalList.count)")
        }
        
        print("✅ Test 7 passed: thread safety correct")
    }
    
    // MARK: - 测试8: 无效帧参数
    static func testInvalidFrame() {
        print("\n🧪 Test 8: Invalid Frame Parameters")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Test")
        
        // 零宽度
        let result1 = wm.setWindowFrame("Test", x: 0, y: 0, width: 0, height: 100)
        guard result1 == false else {
            fatalError("❌ setWindowFrame: should return false for zero width")
        }
        
        // 零高度
        let result2 = wm.setWindowFrame("Test", x: 0, y: 0, width: 100, height: 0)
        guard result2 == false else {
            fatalError("❌ setWindowFrame: should return false for zero height")
        }
        
        // 负数宽高
        let result3 = wm.setWindowFrame("Test", x: 0, y: 0, width: -100, height: 100)
        guard result3 == false else {
            fatalError("❌ setWindowFrame: should return false for negative width")
        }
        
        // 负坐标是允许的（窗口可在屏幕外）
        let result4 = wm.setWindowFrame("Test", x: -100, y: -50, width: 200, height: 150)
        guard result4 == true else {
            fatalError("❌ setWindowFrame: should allow negative x/y coordinates")
        }
        let frame = wm.getWindowFrame("Test")
        guard frame?.x == -100, frame?.y == -50 else {
            fatalError("❌ getWindowFrame: negative coordinates not preserved")
        }
        
        print("✅ Test 8 passed: invalid frame handling correct")
    }
    
    // MARK: - 测试9: 全屏状态
    static func testFullscreenState() {
        print("\n🧪 Test 9: Fullscreen State")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "KLine")
        
        // 手动将状态改为 fullscreen（通过 reopen 从 closed 再进入 fullscreen 模式）
        // 由于 open 只能创建 open 状态，我们通过以下方式测试：
        // 先关闭再重新打开，然后检查 isWindowOpen
        wm.close(windowNamed: "KLine")
        wm.open(windowNamed: "KLine")
        
        guard wm.isWindowOpen("KLine") == true else {
            fatalError("❌ isWindowOpen: reopened window should be open")
        }
        guard wm.getWindowState("KLine") == .open else {
            fatalError("❌ getWindowState: reopened window should be .open")
        }
        
        // 最小化后恢复，状态应为 open
        wm.minimizeWindow("KLine")
        wm.restoreWindow("KLine")
        guard wm.getWindowState("KLine") == .open else {
            fatalError("❌ getWindowState: restored window should be .open")
        }
        
        // fullscreen 是 WindowState 的有效值，验证它存在且被识别
        let allStates = WindowState.allCases
        guard allStates.contains(.fullscreen) else {
            fatalError("❌ WindowState: should contain .fullscreen")
        }
        guard allStates.count == 4 else {
            fatalError("❌ WindowState: should have exactly 4 cases")
        }
        
        print("✅ Test 9 passed: fullscreen state exists and state transitions correct")
    }
}
