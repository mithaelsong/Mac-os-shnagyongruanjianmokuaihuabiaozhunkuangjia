// 功能20: 多窗口支持
// 对应: 模块可拥有独立窗口（如 KLine、新闻浮窗等），由管理器统一跟踪
// 优先级: P2

import Foundation
import AppKit

// MARK: - ModuleWindow

/// 模块窗口结构体，记录窗口基本信息（纯数据层）
public struct ModuleWindow {
    public let identifier: String
    public let title: String
    public let contentView: NSView
    public let moduleName: String
    public var isVisible: Bool
    public var frame: NSRect
    
    public init(
        identifier: String,
        title: String,
        contentView: NSView,
        moduleName: String,
        isVisible: Bool = false,
        frame: NSRect = .zero
    ) {
        self.identifier = identifier
        self.title = title
        self.contentView = contentView
        self.moduleName = moduleName
        self.isVisible = isVisible
        self.frame = frame
    }
}

// MARK: - ModuleWindowManager

/// 多窗口管理单例（纯数据层）
/// 只记录窗口状态，不负责实际的 NSWindow 创建和渲染
/// 主程序通过查询 openWindows 自行决定如何展示窗口
public final class ModuleWindowManager {
    
    // MARK: Singleton
    
    public static let shared = ModuleWindowManager()
    
    // MARK: Properties
    
    /// 锁，保护 _windows 和 _windowMap
    private var lock = os_unfair_lock()
    
    /// 窗口列表，按打开顺序排列
    private var _windows: [ModuleWindow] = []
    
    /// 窗口标识 → 窗口的映射，加速按键查询
    private var _windowMap: [String: ModuleWindow] = [:]
    
    /// 所有打开窗口的列表（只读副本）
    public var openWindows: [ModuleWindow] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _windows
    }
    
    // MARK: Init
    
    private init() {}
    
    // MARK: Open
    
    /// 打开一个新窗口（纯数据层，不创建实际的 NSWindow）
    /// - Parameters:
    ///   - identifier: 窗口唯一标识
    ///   - title: 窗口标题
    ///   - content: 窗口内容视图
    ///   - moduleName: 所属模块名
    ///   - frame: 窗口初始位置和大小，nil 则使用默认位置 (200,200,800,600)
    /// - Returns: 是否成功打开（重复标识符返回 false）
    @discardableResult
    public func openWindow(
        identifier: String,
        title: String,
        content: NSView,
        moduleName: String,
        frame: NSRect? = nil
    ) -> Bool {
        os_unfair_lock_lock(&lock)
        
        // 检查标识是否已存在
        guard _windowMap[identifier] == nil else {
            os_unfair_lock_unlock(&lock)
            return false
        }
        
        let defaultFrame = NSRect(x: 200, y: 200, width: 800, height: 600)
        let windowFrame = frame ?? defaultFrame
        
        let moduleWindow = ModuleWindow(
            identifier: identifier,
            title: title,
            contentView: content,
            moduleName: moduleName,
            isVisible: true,
            frame: windowFrame
        )
        
        _windows.append(moduleWindow)
        _windowMap[identifier] = moduleWindow
        
        os_unfair_lock_unlock(&lock)
        
        return true
    }
    
    // MARK: Close
    
    /// 关闭指定标识的窗口
    /// - Parameter identifier: 窗口标识
    /// - Returns: 是否成功关闭
    @discardableResult
    public func closeWindow(identifier: String) -> Bool {
        os_unfair_lock_lock(&lock)
        
        guard let _ = _windowMap[identifier] else {
            os_unfair_lock_unlock(&lock)
            return false
        }
        
        // 从列表移除
        _windows.removeAll { $0.identifier == identifier }
        _windowMap.removeValue(forKey: identifier)
        
        os_unfair_lock_unlock(&lock)
        
        return true
    }
    
    /// 关闭指定模块的所有窗口
    /// - Parameter moduleName: 模块名
    /// - Returns: 关闭的窗口数量
    @discardableResult
    public func closeAllWindows(moduleName: String) -> Int {
        os_unfair_lock_lock(&lock)
        
        let count = _windows.count { $0.moduleName == moduleName }
        
        _windows.removeAll { $0.moduleName == moduleName }
        
        // 同步清理 _windowMap
        for key in _windowMap.keys {
            if let window = _windowMap[key], window.moduleName == moduleName {
                _windowMap.removeValue(forKey: key)
            }
        }
        
        os_unfair_lock_unlock(&lock)
        
        return count
    }
    
    // MARK: Query
    
    /// 获取指定标识的窗口
    /// - Parameter identifier: 窗口标识
    /// - Returns: 窗口信息，不存在则返回 nil
    public func getWindow(identifier: String) -> ModuleWindow? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _windowMap[identifier]
    }
    
}

// MARK: - Test Code

#if DEBUG

/// 多窗口管理模块测试
/// 运行方式：在 Swift 项目 Debug 模式下编译，或使用 swift 命令行运行
public func runModuleWindowManagerTests() {
    print("=== 模块窗口管理器测试 ===")
    
    let manager = ModuleWindowManager.shared
    
    // 测试1: 打开窗口
    print("\n[Test 1] 打开窗口")
    let view1 = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let result1 = manager.openWindow(
        identifier: "test-window-1",
        title: "测试窗口1",
        content: view1,
        moduleName: "M1_行情",
        frame: NSRect(x: 100, y: 100, width: 400, height: 300)
    )
    guard result1 == true else {
        fatalError("[FAIL] 打开窗口失败: 返回 false")
    }
    guard manager.openWindows.count == 1 else {
        fatalError("[FAIL] 窗口列表数量应为1，实际为 \(manager.openWindows.count)")
    }
    print("[PASS] 打开窗口成功")
    
    // 测试2: 重复标识符打开失败
    print("\n[Test 2] 重复标识符打开失败")
    let result2 = manager.openWindow(
        identifier: "test-window-1",
        title: "重复窗口",
        content: NSView(),
        moduleName: "M1_行情"
    )
    guard result2 == false else {
        fatalError("[FAIL] 重复标识符应返回 false，实际返回 true")
    }
    print("[PASS] 重复标识符正确拒绝")
    
    // 测试3: 按键查询
    print("\n[Test 3] 按键查询窗口")
    let window = manager.getWindow(identifier: "test-window-1")
    guard window != nil else {
        fatalError("[FAIL] 应能查询到 test-window-1")
    }
    guard window?.identifier == "test-window-1" else {
        fatalError("[FAIL] 查询结果标识符不匹配")
    }
    guard window?.title == "测试窗口1" else {
        fatalError("[FAIL] 查询结果标题不匹配")
    }
    guard window?.moduleName == "M1_行情" else {
        fatalError("[FAIL] 查询结果模块名不匹配")
    }
    print("[PASS] 按键查询正确")
    
    // 测试4: 打开多个窗口（同模块+不同模块）
    print("\n[Test 4] 打开多个窗口")
    let result3 = manager.openWindow(
        identifier: "test-window-2",
        title: "测试窗口2",
        content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)),
        moduleName: "M1_行情"
    )
    let result4 = manager.openWindow(
        identifier: "test-window-3",
        title: "测试窗口3",
        content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)),
        moduleName: "M2_交易"
    )
    guard result3 == true && result4 == true else {
        fatalError("[FAIL] 打开多个窗口失败")
    }
    guard manager.openWindows.count == 3 else {
        fatalError("[FAIL] 窗口总数应为3，实际为 \(manager.openWindows.count)")
    }
    print("[PASS] 多窗口打开成功")
    
    // 测试5: 关闭单个窗口
    print("\n[Test 5] 关闭单个窗口")
    let closeResult = manager.closeWindow(identifier: "test-window-1")
    guard closeResult == true else {
        fatalError("[FAIL] 关闭窗口应返回 true")
    }
    guard manager.getWindow(identifier: "test-window-1") == nil else {
        fatalError("[FAIL] 关闭后应查询不到窗口")
    }
    guard manager.openWindows.count == 2 else {
        fatalError("[FAIL] 关闭后窗口数应为2，实际为 \(manager.openWindows.count)")
    }
    print("[PASS] 关闭单个窗口成功")
    
    // 测试6: 关闭指定模块的所有窗口
    print("\n[Test 6] 关闭指定模块的所有窗口")
    let closedCount = manager.closeAllWindows(moduleName: "M1_行情")
    guard closedCount == 1 else {
        fatalError("[FAIL] 应关闭1个M1_行情窗口，实际关闭 \(closedCount)")
    }
    guard manager.openWindows.count == 1 else {
        fatalError("[FAIL] 关闭M1_行情后窗口数应为1，实际为 \(manager.openWindows.count)")
    }
    guard manager.getWindow(identifier: "test-window-3") != nil else {
        fatalError("[FAIL] M2_交易窗口不应被关闭")
    }
    print("[PASS] 按模块关闭成功")
    
    // 测试7: 关闭不存在的窗口
    print("\n[Test 7] 关闭不存在的窗口")
    let result5 = manager.closeWindow(identifier: "non-existent")
    guard result5 == false else {
        fatalError("[FAIL] 关闭不存在的窗口应返回 false")
    }
    print("[PASS] 关闭不存在窗口正确返回 false")
    
    // 测试8: 窗口列表按打开顺序排列
    print("\n[Test 8] 窗口列表按打开顺序排列")
    manager.closeAllWindows(moduleName: "M2_交易")
    
    let ids = ["win-a", "win-b", "win-c"]
    for (index, id) in ids.enumerated() {
        let result = manager.openWindow(
            identifier: id,
            title: "窗口 \(index)",
            content: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)),
            moduleName: "M3_测试"
        )
        guard result == true else {
            fatalError("[FAIL] 打开窗口 \(id) 失败")
        }
    }
    
    let windows = manager.openWindows
    guard windows.count == 3 else {
        fatalError("[FAIL] 窗口列表应为3个，实际 \(windows.count)")
    }
    guard windows[0].identifier == "win-a" else {
        fatalError("[FAIL] 第1个窗口应为 win-a，实际 \(windows[0].identifier)")
    }
    guard windows[1].identifier == "win-b" else {
        fatalError("[FAIL] 第2个窗口应为 win-b，实际 \(windows[1].identifier)")
    }
    guard windows[2].identifier == "win-c" else {
        fatalError("[FAIL] 第3个窗口应为 win-c，实际 \(windows[2].identifier)")
    }
    print("[PASS] 窗口顺序正确")
    
    // 测试9: 关闭所有窗口（清理）
    print("\n[Test 9] 关闭所有窗口")
    let totalClosed = manager.closeAllWindows(moduleName: "M3_测试")
    guard totalClosed == 3 else {
        fatalError("[FAIL] 应关闭3个窗口，实际关闭 \(totalClosed)")
    }
    guard manager.openWindows.isEmpty else {
        fatalError("[FAIL] 全部关闭后窗口列表应为空")
    }
    print("[PASS] 全部关闭成功")
    
    print("\n=== All Tests Passed ===")
}

#endif
