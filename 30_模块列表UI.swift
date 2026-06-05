// 功能30: 模块列表 UI（开发者工具）
// 对应: 开发者工具：显示已加载模块，支持手动加载/卸载
// 优先级: P3 (开发工具)

import Foundation
import AppKit

// MARK: - 模块列表项状态

/// 模块在列表中显示的状态
public enum ModuleListItemState: String, CaseIterable {
    case notLoaded = "未加载"
    case loaded = "已加载"
    case started = "已启动"
    case error = "错误"

    /// 状态对应的颜色
    public var color: NSColor {
        switch self {
        case .notLoaded:  return .secondaryLabelColor
        case .loaded:     return .systemBlue
        case .started:    return .systemGreen
        case .error:      return .systemRed
        }
    }
}

// MARK: - 模块列表项

/// 模块列表数据源项
public struct ModuleListItem {
    public let name: String
    public let version: String
    public let description: String
    public let state: ModuleListItemState

    public init(name: String, version: String, description: String, state: ModuleListItemState) {
        self.name = name
        self.version = version
        self.description = description
        self.state = state
    }
}

// MARK: - 状态指示器视图

/// 彩色圆点状态指示器
public final class StatusIndicatorView: NSView {
    private let dotLayer = CAShapeLayer()

    public var state: ModuleListItemState = .notLoaded {
        didSet { updateAppearance() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        dotLayer.frame = bounds
        dotLayer.path = NSBezierPath(ovalIn: bounds).cgPath
        layer?.addSublayer(dotLayer)
        updateAppearance()
    }

    public override func layout() {
        super.layout()
        let size = min(bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - size) / 2,
                          y: (bounds.height - size) / 2,
                          width: size,
                          height: size)
        dotLayer.frame = rect
        dotLayer.path = NSBezierPath(ovalIn: rect).cgPath
    }

    private func updateAppearance() {
        dotLayer.fillColor = state.color.cgColor
    }
}

// MARK: - 模块列表视图

/// 模块列表主视图，包含表格、工具栏和空状态提示
public final class ModuleListUIView: NSView {

    // MARK: - 子视图

    public private(set) var tableView: NSTableView!
    public private(set) var scrollView: NSScrollView!
    public private(set) var toolbarStack: NSStackView!
    public private(set) var loadButton: NSButton!
    public private(set) var unloadButton: NSButton!
    public private(set) var reloadButton: NSButton!
    public private(set) var refreshButton: NSButton!
    public private(set) var emptyLabel: NSTextField!

    // MARK: - 初始化

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - UI 搭建

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // ---- 表格 ----
        tableView = NSTableView()
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "模块名称"
        nameColumn.minWidth = 120
        nameColumn.maxWidth = 300
        tableView.addTableColumn(nameColumn)

        let versionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        versionColumn.title = "版本"
        versionColumn.minWidth = 80
        versionColumn.maxWidth = 120
        tableView.addTableColumn(versionColumn)

        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "状态"
        stateColumn.minWidth = 100
        stateColumn.maxWidth = 160
        tableView.addTableColumn(stateColumn)

        let descColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("description"))
        descColumn.title = "描述"
        descColumn.minWidth = 150
        tableView.addTableColumn(descColumn)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        addSubview(scrollView)

        // ---- 工具栏 ----
        toolbarStack = NSStackView()
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 12
        toolbarStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        loadButton = NSButton(title: "➕ 加载模块", target: nil, action: nil)
        loadButton.bezelStyle = .rounded

        unloadButton = NSButton(title: "➖ 卸载模块", target: nil, action: nil)
        unloadButton.bezelStyle = .rounded

        reloadButton = NSButton(title: "🔄 重载模块", target: nil, action: nil)
        reloadButton.bezelStyle = .rounded

        refreshButton = NSButton(title: "⟳ 刷新", target: nil, action: nil)
        refreshButton.bezelStyle = .rounded

        toolbarStack.addArrangedSubview(loadButton)
        toolbarStack.addArrangedSubview(unloadButton)
        toolbarStack.addArrangedSubview(reloadButton)
        toolbarStack.addArrangedSubview(refreshButton)
        toolbarStack.addArrangedSubview(NSView()) // 弹性占位
        addSubview(toolbarStack)

        // ---- 空状态提示 ----
        emptyLabel = NSTextField(labelWithString: "暂无已加载模块")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // ---- 约束 ----
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: topAnchor),
            toolbarStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarStack.heightAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // MARK: - 空状态

    /// 设置空状态可见性
    public func setEmptyStateVisible(_ visible: Bool) {
        emptyLabel.isHidden = !visible
        scrollView.isHidden = visible
    }
}

// MARK: - NSBezierPath → CGPath 扩展

extension NSBezierPath {
    fileprivate var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0 ..< self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:          path.move(to: points[0])
            case .lineTo:          path.addLine(to: points[0])
            case .curveTo:         path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:       path.closeSubpath()
            @unknown default:      break
            }
        }
        return path
    }
}

// MARK: - 模块列表视图控制器

/// 模块列表视图控制器 (功能30)
public final class ModuleListViewController: NSViewController {

    // MARK: - 类型别名

    private typealias ListView = ModuleListUIView

    // MARK: - UI 组件

    private var moduleListView: ListView { view as! ListView }

    // MARK: - 数据

    private var items: [ModuleListItem] = []
    private var errorModules: Set<String> = []

    // MARK: - 业务对象

    private let registry = ModuleRegistry.shared
    private lazy var starter = ModuleStarter(
        registry: registry,
        logger: ModuleLogger(category: "ModuleListUI")
    )
    private lazy var unloader = ModuleUnloader(
        registry: registry,
        eventBus: EventBus.shared
    )
    private lazy var dynamicLoader = DynamicModuleLoader(
        registry: registry,
        loader: ModuleLoader(
            registry: registry,
            eventBus: EventBus.shared,
            logger: ModuleLogger(category: "ModuleListUI")
        ),
        systemVersion: Version(major: 2, minor: 0, patch: 0)
    )
    private let logger = ModuleLogger(category: "ModuleListUI")

    // MARK: - 生命周期

    public override func loadView() {
        self.view = ListView(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupDelegates()
        setupActions()
        refresh()
    }

    // MARK: - 委托与动作绑定

    private func setupDelegates() {
        moduleListView.tableView.delegate = self
        moduleListView.tableView.dataSource = self
    }

    private func setupActions() {
        moduleListView.loadButton.target = self
        moduleListView.loadButton.action = #selector(loadModule)

        moduleListView.unloadButton.target = self
        moduleListView.unloadButton.action = #selector(unloadModule)

        moduleListView.reloadButton.target = self
        moduleListView.reloadButton.action = #selector(reloadModule)

        moduleListView.refreshButton.target = self
        moduleListView.refreshButton.action = #selector(refresh)
    }

    // MARK: - 刷新数据

    /// 刷新模块列表数据并重载表格
    @objc public func refresh() {
        items = buildItems()
        moduleListView.setEmptyStateVisible(items.isEmpty)
        moduleListView.tableView?.reloadData()
        logger.info("模块列表已刷新，共 \(items.count) 个模块")
    }

    private func buildItems() -> [ModuleListItem] {
        let names = registry.allModuleNames.sorted()
        return names.map { name in
            let metadata = registry.getMetadata(named: name)
            let state: ModuleListItemState
            if errorModules.contains(name) {
                state = .error
            } else if registry.isLoaded(name: name) {
                state = starter.isStarted(name) ? .started : .loaded
            } else {
                state = .notLoaded
            }
            return ModuleListItem(
                name: name,
                version: metadata?.version ?? "—",
                description: metadata?.description ?? "",
                state: state
            )
        }
    }

    // MARK: - 按钮动作

    /// 手动加载模块（弹出文件选择器）
    @objc private func loadModule() {
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.title = "选择模块 Bundle"
        var contentTypes: [UTType] = [.package]
        if let bundleType = UTType(filenameExtension: "bundle") { contentTypes.append(bundleType) }
        if let dylibType = UTType(filenameExtension: "dylib") { contentTypes.append(dylibType) }
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self = self else { return }
            guard result == .OK, let url = panel.url else { return }
            self.loadModule(from: url)
        }
    }

    private func loadModule(from url: URL) {
        logger.info("正在加载模块: \(url.path)")
        let result = dynamicLoader.load(from: url)
        switch result {
        case .success(let metadata):
            errorModules.remove(metadata.name)
            logger.info("模块加载成功: \(metadata.name) v\(metadata.version)")
            // 自动尝试启动
            let startResult = starter.startModule(metadata.name)
            if case .failure(let reason) = startResult {
                logger.warning("模块启动失败: \(metadata.name)，原因: \(self.reasonString(reason))")
            }
        case .failure(let error):
            logger.error("模块加载失败: \(error)")
            showAlert(title: "加载失败", message: "无法加载模块: \(error)")
        }
        refresh()
    }

    /// 卸载选中的模块
    @objc private func unloadModule() {
        guard let name = selectedModuleName() else {
            showAlert(title: "提示", message: "请先选择一个模块")
            return
        }
        logger.info("正在卸载模块: \(name)")

        // 先停止
        if starter.isStarted(name) {
            starter.stopModule(name)
        }

        let result = unloader.unload(name: name)
        switch result {
        case .success:
            errorModules.remove(name)
            logger.info("模块卸载成功: \(name)")
        case .failure(let reason):
            logger.error("模块卸载失败: \(name)，原因: \(reason)")
            errorModules.insert(name)
            showAlert(title: "卸载失败", message: "无法卸载模块 \(name): \(reason)")
        }
        refresh()
    }

    /// 重载选中的模块（卸载 + 加载）
    @objc private func reloadModule() {
        guard let name = selectedModuleName() else {
            showAlert(title: "提示", message: "请先选择一个模块")
            return
        }
        guard let metadata = registry.getMetadata(named: name) else {
            showAlert(title: "提示", message: "无法获取模块元数据")
            return
        }

        logger.info("正在重载模块: \(name)")

        // 1. 停止
        if starter.isStarted(name) {
            starter.stopModule(name)
        }

        // 2. 卸载
        let unloadResult = unloader.unload(name: name)
        guard case .success = unloadResult else {
            logger.error("重载失败：卸载步骤出错")
            showAlert(title: "重载失败", message: "卸载模块时出错")
            refresh()
            return
        }

        // 3. 重新加载（需要路径）
        // 注：动态加载的模块路径不保存在注册表中，这里仅演示重载逻辑
        // 实际项目中可通过元数据或其他方式保留原始路径
        logger.info("模块 \(name) 已卸载，请重新加载")
        showAlert(title: "重载", message: "模块 \(name) 已卸载，请使用「加载模块」重新加载。")
        errorModules.remove(name)
        refresh()
    }

    // MARK: - 辅助方法

    private func selectedModuleName() -> String? {
        let row = moduleListView.tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row].name
    }

    private func reasonString(_ reason: ModuleStartFailureReason) -> String {
        switch reason {
        case .notRegistered:          return "未注册"
        case .dependencyFailed(let n): return "依赖失败: \(n)"
        case .startFailed(let err):   return "启动异常: \(err)"
        case .dependencyCycle(let c): return "循环依赖: \(c.joined(separator: " -> "))"
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSTableViewDataSource

extension ModuleListViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

// MARK: - NSTableViewDelegate

extension ModuleListViewController: NSTableViewDelegate {

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        switch tableColumn?.identifier.rawValue {
        case "name":
            textField.stringValue = item.name
            textField.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        case "version":
            textField.stringValue = item.version
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor

        case "state":
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let indicator = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.state = item.state

            let label = NSTextField(labelWithString: item.state.rawValue)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = item.state.color

            container.addSubview(indicator)
            container.addSubview(label)

            NSLayoutConstraint.activate([
                indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                indicator.widthAnchor.constraint(equalToConstant: 10),
                indicator.heightAnchor.constraint(equalToConstant: 10),

                label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
            ])

            cell.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                container.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell

        case "description":
            textField.stringValue = item.description
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor

        default:
            break
        }

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -5),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = moduleListView.tableView.selectedRow
        moduleListView.unloadButton.isEnabled = row >= 0
        moduleListView.reloadButton.isEnabled = row >= 0
    }
}

// MARK: - 开发者菜单扩展

public extension MenuManager {
    /// 添加开发者菜单（包含模块列表入口）
    func addDeveloperMenu() {
        let devMenu = NSMenu(title: "开发者")

        let showModulesItem = NSMenuItem(
            title: "模块列表…",
            action: #selector(showModuleList),
            keyEquivalent: "m"
        )
        showModulesItem.keyEquivalentModifierMask = [.command, .option]
        showModulesItem.target = self

        devMenu.addItem(showModulesItem)
        devMenu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(
            title: "刷新模块列表",
            action: #selector(showModuleList),
            keyEquivalent: "r"
        )
        refreshItem.keyEquivalentModifierMask = [.command, .option]
        refreshItem.target = self
        devMenu.addItem(refreshItem)

        registerModuleMenu(devMenu, for: "DeveloperTools", title: "开发者")
    }

    @objc private func showModuleList() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 700, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "模块列表"
        window.minSize = NSSize(width: 500, height: 300)

        let viewController = ModuleListViewController()
        window.contentViewController = viewController
        window.makeKeyAndOrderFront(nil)

        // 同时记录到纯数据层窗口管理器
        _ = ModuleWindowManager.shared.openWindow(
            identifier: "module-list-\(UUID().uuidString.prefix(8))",
            title: "模块列表",
            content: viewController.view,
            moduleName: "DeveloperTools",
            frame: window.frame
        )
    }
}

// MARK: - 测试代码
/// 模块列表UI功能验证
/// 运行方式：在单元测试或 Playground 中调用 `ModuleListUITests.run()`
public enum ModuleListUITests {

    // MARK: - 模拟模块
    final class MockModule: XRZModule {
        let name: String
        var startCalled = false
        var stopCalled = false

        init(name: String) { self.name = name }

        func start() throws {
            startCalled = true
        }

        func stop() throws {
            stopCalled = true
        }
    }

    /// 运行所有测试
    public static func run() {
        cleanupRegistry()
        print("=== 模块列表UI测试 ===")

        testEmptyState()
        cleanupRegistry()

        testDisplayLoadedModules()
        cleanupRegistry()

        testStatusIndicator()
        cleanupRegistry()

        testRefresh()
        cleanupRegistry()

        testModuleItemStateColors()
        cleanupRegistry()

        print("\n=== 全部模块列表UI测试通过 ✅ ===")
    }

    // MARK: - 辅助

    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }

    // MARK: - 测试1: 空状态

    static func testEmptyState() {
        print("\n🧪 测试1: 空状态显示")

        let vc = ModuleListViewController()
        vc.loadViewIfNeeded()
        vc.refresh()

        let listView = vc.view as! ModuleListUIView
        guard !listView.emptyLabel.isHidden else {
            fatalError("❌ 测试1失败: 空状态标签应可见")
        }
        guard listView.scrollView.isHidden else {
            fatalError("❌ 测试1失败: 滚动视图应隐藏")
        }
        guard listView.emptyLabel.stringValue == "暂无已加载模块" else {
            fatalError("❌ 测试1失败: 空状态文本不匹配")
        }

        print("✅ 测试1通过: 空状态显示正确")
    }

    // MARK: - 测试2: 显示已加载模块

    static func testDisplayLoadedModules() {
        print("\n🧪 测试2: 显示已加载模块")

        let registry = ModuleRegistry.shared

        let modA = ModuleListUITests.MockModule(name: "TestA")
        let modB = ModuleListUITests.MockModule(name: "TestB")

        registry.register(
            module: modA,
            name: "TestA",
            metadata: ModuleMetadata(
                name: "TestA",
                version: "1.0.0",
                description: "测试模块A",
                entryClass: "MockModule",
                dependencies: []
            )
        )
        registry.register(
            module: modB,
            name: "TestB",
            metadata: ModuleMetadata(
                name: "TestB",
                version: "2.0.0",
                description: "测试模块B",
                entryClass: "MockModule",
                dependencies: []
            )
        )

        let vc = ModuleListViewController()
        vc.loadViewIfNeeded()
        vc.refresh()

        let listView = vc.view as! ModuleListUIView
        guard listView.emptyLabel.isHidden else {
            fatalError("❌ 测试2失败: 空状态标签应隐藏")
        }
        guard !listView.scrollView.isHidden else {
            fatalError("❌ 测试2失败: 滚动视图应可见")
        }
        guard listView.tableView.numberOfRows == 2 else {
            fatalError("❌ 测试2失败: 期望2行，实际\(listView.tableView.numberOfRows)")
        }

        print("✅ 测试2通过: 已加载模块正确显示")
    }

    // MARK: - 测试3: 状态指示器

    static func testStatusIndicator() {
        print("\n🧪 测试3: 状态指示器")

        let indicator = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))

        for state in ModuleListItemState.allCases {
            indicator.state = state
            guard indicator.state == state else {
                fatalError("❌ 测试3失败: 状态设置失败 \(state)")
            }
        }

        print("✅ 测试3通过: 状态指示器切换正常")
    }

    // MARK: - 测试4: 刷新方法

    static func testRefresh() {
        print("\n🧪 测试4: 刷新列表")

        let registry = ModuleRegistry.shared
        registry.register(module: ModuleListUITests.MockModule(name: "R1"), name: "R1")

        let vc = ModuleListViewController()
        vc.loadViewIfNeeded()
        vc.refresh()

        let listView = vc.view as! ModuleListUIView
        let initialCount = listView.tableView.numberOfRows
        guard initialCount == 1 else {
            fatalError("❌ 测试4失败: 初始应为1行，实际\(initialCount)")
        }

        registry.register(module: ModuleListUITests.MockModule(name: "R2"), name: "R2")
        vc.refresh()

        let newCount = listView.tableView.numberOfRows
        guard newCount == 2 else {
            fatalError("❌ 测试4失败: 刷新后应为2行，实际\(newCount)")
        }

        print("✅ 测试4通过: 刷新列表正常工作")
    }

    // MARK: - 测试5: 状态颜色映射

    static func testModuleItemStateColors() {
        print("\n🧪 测试5: 状态颜色映射")

        let tests: [(ModuleListItemState, NSColor)] = [
            (.notLoaded, .secondaryLabelColor),
            (.loaded,    .systemBlue),
            (.started,   .systemGreen),
            (.error,     .systemRed)
        ]

        for (state, expected) in tests {
            guard state.color == expected else {
                fatalError("❌ 测试5失败: \(state)颜色不匹配")
            }
        }

        print("✅ 测试5通过: 状态颜色映射正确")
    }
}
