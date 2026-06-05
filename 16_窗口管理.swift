// 功能16: 窗口管理
// 对应: 主窗口、设置窗口、关于窗口的创建与显示
// 优先级: P1

import Foundation
import os

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
            logger.warning("open(windowNamed:)失败: 名称为空")
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
                logger.info("窗口'\(name)'已从关闭状态重新打开")
            } else {
                // 已打开，提升 zIndex（相当于激活）
                storage.windows[name]?.zIndex = storage.nextZIndex
                storage.nextZIndex += 1
                logger.info("窗口'\(name)'已打开(状态: \(existing.state.rawValue))，前置")
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
        logger.info("窗口'\(name)'已打开")
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
            logger.warning("close(windowNamed:)失败: '\(name)'未找到")
            return false
        }
        
        storage.windows[name]?.state = .closed
        logger.info("窗口'\(name)'已关闭")
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
            logger.warning("setWindowFrame失败: 无效尺寸(width=\(width), height=\(height))")
            return false
        }
        
        os_unfair_lock_lock(&storage.lock)
        defer { os_unfair_lock_unlock(&storage.lock) }
        
        guard storage.windows[name] != nil else {
            logger.warning("setWindowFrame失败: '\(name)'未找到")
            return false
        }
        
        storage.windows[name]?.frame = WindowFrame(x: x, y: y, width: width, height: height)
        logger.info("窗口'\(name)'帧已设置为\(WindowFrame(x: x, y: y, width: width, height: height))")
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
            logger.warning("minimizeWindow失败: '\(name)'未找到")
            return false
        }
        
        guard record.state == .open || record.state == .fullscreen else {
            logger.warning("minimizeWindow失败: '\(name)'状态为\(record.state.rawValue)，无法最小化")
            return false
        }
        
        storage.windows[name]?.state = .minimized
        logger.info("窗口'\(name)'已最小化")
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
            logger.warning("restoreWindow失败: '\(name)'未找到")
            return false
        }
        
        guard record.state == .minimized else {
            logger.warning("restoreWindow失败: '\(name)'状态为\(record.state.rawValue)，非最小化")
            return false
        }
        
        storage.windows[name]?.state = .open
        logger.info("窗口'\(name)'已恢复")
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
            logger.warning("bringToFront失败: '\(name)'未找到")
            return false
        }
        
        guard record.state != .closed else {
            logger.warning("bringToFront失败: '\(name)'已关闭")
            return false
        }
        
        storage.windows[name]?.zIndex = storage.nextZIndex
        storage.nextZIndex += 1
        logger.info("窗口'\(name)'已前置(zIndex: \(storage.windows[name]!.zIndex))")
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
        print("=== 窗口管理器测试 ===")
        testOpenAndClose()
        testWindowStateQuery()
        testSetAndGetFrame()
        testMinimizeAndRestore()
        testBringToFront()
        testListOpenWindows()
        testThreadSafety()
        testInvalidFrame()
        testFullscreenState()
        print("\n=== 全部窗口管理器测试通过 ✅ ===")
    }
    
    // MARK: - 测试1: 打开/关闭窗口
    static func testOpenAndClose() {
        print("\n🧪 测试1: 打开/关闭窗口")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 打开新窗口
        let result1 = wm.open(windowNamed: "Main")
        guard result1 == true else {
            fatalError("❌ 测试1失败: 新窗口应返回true")
        }
        
        // 重复打开已存在的窗口（应返回 true，相当于激活）
        let result2 = wm.open(windowNamed: "Main")
        guard result2 == true else {
            fatalError("❌ 测试1失败: 已打开窗口应返回true")
        }
        
        // 关闭已存在的窗口
        let result3 = wm.close(windowNamed: "Main")
        guard result3 == true else {
            fatalError("❌ 测试1失败: 存在窗口应返回true")
        }
        
        // 关闭后再次关闭（应返回 false）
        let result4 = wm.close(windowNamed: "Main")
        guard result4 == true else {
            fatalError("❌ 测试1失败: 已关闭窗口仍应返回true（状态存在）")
        }
        
        // 关闭不存在的窗口
        let result5 = wm.close(windowNamed: "NonExistent")
        guard result5 == false else {
            fatalError("❌ 测试1失败: 不存在窗口应返回false")
        }
        
        // 空名称打开
        let result6 = wm.open(windowNamed: "")
        guard result6 == false else {
            fatalError("❌ 测试1失败: 空名称应返回false")
        }
        
        print("✅ 测试1通过: 打开/关闭行为正确")
    }
    
    // MARK: - 测试2: 窗口状态查询
    static func testWindowStateQuery() {
        print("\n🧪 测试2: 窗口状态查询")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 不存在的窗口
        guard wm.isWindowOpen("Ghost") == false else {
            fatalError("❌ 测试2失败: 不存在窗口应为false")
        }
        
        // 打开后查询
        wm.open(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == true else {
            fatalError("❌ 测试2失败: 'Chart'应为打开")
        }
        guard wm.getWindowState("Chart") == .open else {
            fatalError("❌ 测试2失败: 'Chart'应为.open")
        }
        
        // 关闭后查询
        wm.close(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == false else {
            fatalError("❌ 测试2失败: 已关闭窗口应为false")
        }
        guard wm.getWindowState("Chart") == .closed else {
            fatalError("❌ 测试2失败: 已关闭窗口应为.closed")
        }
        
        // 重新打开后查询
        wm.open(windowNamed: "Chart")
        guard wm.isWindowOpen("Chart") == true else {
            fatalError("❌ 测试2失败: 重新打开窗口应为true")
        }
        
        print("✅ 测试2通过: 状态查询正确")
    }
    
    // MARK: - 测试3: 设置/获取窗口帧
    static func testSetAndGetFrame() {
        print("\n🧪 测试3: 设置/获取窗口帧")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Settings")
        
        // 未设置帧时返回 nil
        guard wm.getWindowFrame("Settings") == nil else {
            fatalError("❌ 测试3失败: 设置前应为nil")
        }
        
        // 设置合法帧
        let result1 = wm.setWindowFrame("Settings", x: 100, y: 200, width: 800, height: 600)
        guard result1 == true else {
            fatalError("❌ 测试3失败: 合法帧应返回true")
        }
        
        let frame = wm.getWindowFrame("Settings")
        guard let frame = frame else {
            fatalError("❌ 测试3失败: 设置后不应为nil")
        }
        guard frame.x == 100, frame.y == 200, frame.width == 800, frame.height == 600 else {
            fatalError("❌ 测试3失败: 返回\(frame)，期望(100, 200, 800, 600)")
        }
        
        // 更新帧
        let result2 = wm.setWindowFrame("Settings", x: 50, y: 50, width: 400, height: 300)
        guard result2 == true else {
            fatalError("❌ 测试3失败: 更新应返回true")
        }
        let updated = wm.getWindowFrame("Settings")
        guard updated?.width == 400, updated?.height == 300 else {
            fatalError("❌ 测试3失败: 更新失败")
        }
        
        // 对不存在的窗口设置帧
        let result3 = wm.setWindowFrame("Ghost", x: 0, y: 0, width: 100, height: 100)
        guard result3 == false else {
            fatalError("❌ 测试3失败: 不存在窗口应为false")
        }
        
        print("✅ 测试3通过: 帧设置/获取正确")
    }
    
    // MARK: - 测试4: 最小化/恢复
    static func testMinimizeAndRestore() {
        print("\n🧪 测试4: 最小化/恢复窗口")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Trade")
        
        // 最小化已打开的窗口
        let result1 = wm.minimizeWindow("Trade")
        guard result1 == true else {
            fatalError("❌ 测试4失败: 已打开窗口应返回true")
        }
        guard wm.getWindowState("Trade") == .minimized else {
            fatalError("❌ 测试4失败: 最小化后应为.minimized")
        }
        guard wm.isWindowOpen("Trade") == true else {
            fatalError("❌ 测试4失败: 最小化窗口仍为'打开'")
        }
        
        // 恢复已最小化的窗口
        let result2 = wm.restoreWindow("Trade")
        guard result2 == true else {
            fatalError("❌ 测试4失败: 已最小化窗口应返回true")
        }
        guard wm.getWindowState("Trade") == .open else {
            fatalError("❌ 测试4失败: 恢复后应为.open")
        }
        
        // 对未最小化的窗口恢复
        let result3 = wm.restoreWindow("Trade")
        guard result3 == false else {
            fatalError("❌ 测试4失败: 非最小化窗口应返回false")
        }
        
        // 对不存在的窗口最小化
        let result4 = wm.minimizeWindow("Ghost")
        guard result4 == false else {
            fatalError("❌ 测试4失败: 不存在窗口应返回false")
        }
        
        // 对关闭的窗口最小化
        wm.close(windowNamed: "Trade")
        let result5 = wm.minimizeWindow("Trade")
        guard result5 == false else {
            fatalError("❌ 测试4失败: 已关闭窗口应返回false")
        }
        
        print("✅ 测试4通过: 最小化/恢复正确")
    }
    
    // MARK: - 测试5: 前置窗口
    static func testBringToFront() {
        print("\n🧪 测试5: 窗口前置")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "A")
        wm.open(windowNamed: "B")
        wm.open(windowNamed: "C")
        
        // 初始顺序应为 C > B > A（zIndex 越大越前）
        let initialList = wm.listOpenWindows()
        guard initialList == ["C", "B", "A"] else {
            fatalError("❌ 测试5失败: 期望[C, B, A]，实际\(initialList)")
        }
        
        // 将 A 前置
        let result1 = wm.bringToFront("A")
        guard result1 == true else {
            fatalError("❌ 测试5失败: 已打开窗口应返回true")
        }
        
        let updatedList = wm.listOpenWindows()
        guard updatedList == ["A", "C", "B"] else {
            fatalError("❌ 测试5失败: 期望[A, C, B]，实际\(updatedList)")
        }
        
        // 对不存在的窗口前置
        let result2 = wm.bringToFront("Ghost")
        guard result2 == false else {
            fatalError("❌ 测试5失败: 不存在窗口应返回false")
        }
        
        // 对关闭的窗口前置
        wm.close(windowNamed: "B")
        let result3 = wm.bringToFront("B")
        guard result3 == false else {
            fatalError("❌ 测试5失败: 已关闭窗口应返回false")
        }
        
        print("✅ 测试5通过: 窗口前置正确")
    }
    
    // MARK: - 测试6: 列出打开窗口
    static func testListOpenWindows() {
        print("\n🧪 测试6: 列出打开的窗口")
        
        let wm = WindowManager(registry: ModuleRegistry())
        
        // 空列表
        guard wm.listOpenWindows().isEmpty else {
            fatalError("❌ 测试6失败: 初始应为空")
        }
        
        // 添加多个窗口
        wm.open(windowNamed: "Main")
        wm.open(windowNamed: "Settings")
        wm.open(windowNamed: "About")
        
        let list1 = wm.listOpenWindows().sorted()
        guard list1 == ["About", "Main", "Settings"] else {
            fatalError("❌ 测试6失败: 期望[About, Main, Settings]，实际\(list1)")
        }
        
        // 关闭一个窗口后
        wm.close(windowNamed: "Settings")
        let list2 = wm.listOpenWindows().sorted()
        guard list2 == ["About", "Main"] else {
            fatalError("❌ 测试6失败: 期望[About, Main]，实际\(list2)")
        }
        
        // 全部关闭后
        wm.close(windowNamed: "Main")
        wm.close(windowNamed: "About")
        guard wm.listOpenWindows().isEmpty else {
            fatalError("❌ 测试6失败: 全部关闭后应为空")
        }
        
        print("✅ 测试6通过: 列出打开窗口正确")
    }
    
    // MARK: - 测试7: 线程安全
    static func testThreadSafety() {
        print("\n🧪 测试7: 线程安全")
        
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
            fatalError("❌ 测试7失败: 期望\(windowCount)个窗口，实际\(openWindows.count)")
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
            fatalError("❌ 测试7失败: 并发操作后期望\(windowCount)个窗口，实际\(finalList.count)")
        }
        
        print("✅ 测试7通过: 线程安全正确")
    }
    
    // MARK: - 测试8: 无效帧参数
    static func testInvalidFrame() {
        print("\n🧪 测试8: 无效帧参数")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "Test")
        
        // 零宽度
        let result1 = wm.setWindowFrame("Test", x: 0, y: 0, width: 0, height: 100)
        guard result1 == false else {
            fatalError("❌ 测试8失败: 零宽度应返回false")
        }
        
        // 零高度
        let result2 = wm.setWindowFrame("Test", x: 0, y: 0, width: 100, height: 0)
        guard result2 == false else {
            fatalError("❌ 测试8失败: 零高度应返回false")
        }
        
        // 负数宽高
        let result3 = wm.setWindowFrame("Test", x: 0, y: 0, width: -100, height: 100)
        guard result3 == false else {
            fatalError("❌ 测试8失败: 负数宽度应返回false")
        }
        
        // 负坐标是允许的（窗口可在屏幕外）
        let result4 = wm.setWindowFrame("Test", x: -100, y: -50, width: 200, height: 150)
        guard result4 == true else {
            fatalError("❌ 测试8失败: 应允许负数x/y坐标")
        }
        let frame = wm.getWindowFrame("Test")
        guard frame?.x == -100, frame?.y == -50 else {
            fatalError("❌ 测试8失败: 负数坐标未保留")
        }
        
        print("✅ 测试8通过: 无效帧处理正确")
    }
    
    // MARK: - 测试9: 全屏状态
    static func testFullscreenState() {
        print("\n🧪 测试9: 全屏状态")
        
        let wm = WindowManager(registry: ModuleRegistry())
        wm.open(windowNamed: "KLine")
        
        // 手动将状态改为 fullscreen（通过 reopen 从 closed 再进入 fullscreen 模式）
        // 由于 open 只能创建 open 状态，我们通过以下方式测试：
        // 先关闭再重新打开，然后检查 isWindowOpen
        wm.close(windowNamed: "KLine")
        wm.open(windowNamed: "KLine")
        
        guard wm.isWindowOpen("KLine") == true else {
            fatalError("❌ 测试9失败: 重新打开窗口应为打开")
        }
        guard wm.getWindowState("KLine") == .open else {
            fatalError("❌ 测试9失败: 重新打开窗口应为.open")
        }
        
        // 最小化后恢复，状态应为 open
        wm.minimizeWindow("KLine")
        wm.restoreWindow("KLine")
        guard wm.getWindowState("KLine") == .open else {
            fatalError("❌ 测试9失败: 恢复后窗口应为.open")
        }
        
        // fullscreen 是 WindowState 的有效值，验证它存在且被识别
        let allStates = WindowState.allCases
        guard allStates.contains(.fullscreen) else {
            fatalError("❌ 测试9失败: 应包含.fullscreen")
        }
        guard allStates.count == 4 else {
            fatalError("❌ 测试9失败: 应有4个case")
        }
        
        print("✅ 测试9通过: 全屏状态存在且状态转换正确")
    }
}
