// 功能30: 模块列表 UI（可选）
// 对应: 开发者工具：显示已加载模块，支持手动加载/卸载
// 优先级: P3 (开发工具)

import AppKit

/// 模块列表视图控制器 (功能30)
public final class ModuleListViewController: NSViewController {
    
    // MARK: - UI 组件
    private var tableView: NSTableView!
    private var loadButton: NSButton!
    private var unloadButton: NSButton!
    private var reloadButton: NSButton!
    
    // MARK: - 数据
    private var modules: [(name: String, metadata: ModuleMetadata?, state: String)] = []
    
    // MARK: - 生命周期
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshData()
    }
    
    // MARK: - 设置 UI
    private func setupUI() {
        // 表格
        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        
        // 列
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "模块名称"
        nameColumn.width = 150
        tableView.addTableColumn(nameColumn)
        
        let versionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        versionColumn.title = "版本"
        versionColumn.width = 100
        tableView.addTableColumn(versionColumn)
        
        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "状态"
        stateColumn.width = 100
        tableView.addTableColumn(stateColumn)
        
        let scrollView = NSScrollView(frame: view.bounds)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)
        
        // 按钮
        let buttonStack = NSStackView(frame: NSRect(x: 10, y: 10, width: 300, height: 30))
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        
        loadButton = NSButton(title: "加载", target: self, action: #selector(loadSelected))
        unloadButton = NSButton(title: "卸载", target: self, action: #selector(unloadSelected))
        reloadButton = NSButton(title: "重载", target: self, action: #selector(reloadSelected))
        
        buttonStack.addArrangedSubview(loadButton)
        buttonStack.addArrangedSubview(unloadButton)
        buttonStack.addArrangedSubview(reloadButton)
        
        view.addSubview(buttonStack)
    }
    
    // MARK: - 刷新数据
    private func refreshData() {
        modules = ModuleRegistry.shared.allModuleNames.map { name in
            let metadata = ModuleRegistry.shared.getMetadata(named: name)
            let state = ModuleRegistry.shared.isLoaded(name: name) ? "已加载" : "未加载"
            return (name: name, metadata: metadata, state: state)
        }
        
        tableView?.reloadData()
    }
    
    // MARK: - 按钮动作
    @objc private func loadSelected() {
        guard tableView.selectedRow >= 0 else { return }
        let module = modules[tableView.selectedRow]
        
        // 加载模块
        // 实际实现需要 ModuleLoader
        LogSystem.shared.log(level: .info, category: "ModuleListUI",
                            message: "Loading module: \(module.name)")
    }
    
    @objc private func unloadSelected() {
        guard tableView.selectedRow >= 0 else { return }
        let module = modules[tableView.selectedRow]
        
        let unloader = ModuleUnloader(
            registry: ModuleRegistry.shared,
            eventBus: EventBus.shared
        )
        _ = unloader.unload(name: module.name)
        
        refreshData()
    }
    
    @objc private func reloadSelected() {
        guard tableView.selectedRow >= 0 else { return }
        let module = modules[tableView.selectedRow]
        
        // 重载 = 卸载 + 加载
        let unloader = ModuleUnloader(
            registry: ModuleRegistry.shared,
            eventBus: EventBus.shared
        )
        _ = unloader.unload(name: module.name)
        
        // 重新加载...
        refreshData()
    }
}

// MARK: - NSTableViewDataSource
extension ModuleListViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return modules.count
    }
}

// MARK: - NSTableViewDelegate
extension ModuleListViewController: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let module = modules[row]
        let cell = NSTableCellView()
        
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        
        switch tableColumn?.identifier.rawValue {
        case "name":
            textField.stringValue = module.name
        case "version":
            textField.stringValue = module.metadata?.version ?? "未知"
        case "state":
            textField.stringValue = module.state
        default:
            break
        }
        
        return cell
    }
}

// MARK: - 开发者菜单
public extension MenuManager {
    func addDeveloperMenu() {
        let devMenu = NSMenu(title: "开发者")
        
        let showModulesItem = NSMenuItem(
            title: "模块列表",
            action: #selector(showModuleList),
            keyEquivalent: "m"
        )
        showModulesItem.keyEquivalentModifierMask = [.command, .option]
        
        devMenu.addItem(showModulesItem)
        
        registerModuleMenu(devMenu, for: "DeveloperTools", title: "开发者")
    }
    
    @objc private func showModuleList() {
        let window = WindowManager.shared.createModuleWindow(
            module: "ModuleList",
            size: NSSize(width: 600, height: 400)
        )
        
        let viewController = ModuleListViewController()
        window.contentViewController = viewController
        window.makeKeyAndOrderFront(nil)
    }
}