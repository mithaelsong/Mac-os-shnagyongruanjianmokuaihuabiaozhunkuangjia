// 功能13: 事件总线
// 对应: 模块可以发送事件，其他模块可以监听（NotificationCenter 封装）
// 优先级: P0

import Foundation

/// 事件总线 (功能13)
/// 基于 NotificationCenter，但加了类型安全和模块命名空间
public final class EventBus {
    public static let shared = EventBus()
    
    private let center = NotificationCenter.default
    private let queue = OperationQueue()
    private var observers: [String: [NSObjectProtocol]] = [:]
    private let lock = NSLock()
    
    private init() {
        queue.name = "com.xianrenzhilu.eventbus"
        queue.maxConcurrentOperationCount = 1 // 串行处理，保证顺序
    }
    
    // MARK: - 发送事件
    public func emit(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        center.post(name: name, object: nil, userInfo: userInfo)
    }
    
    // MARK: - 监听事件
    @discardableResult
    public func on(_ name: Notification.Name, queue: OperationQueue? = nil,
                   using block: @escaping (Notification) -> Void) -> String {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: queue ?? self.queue,
            using: block
        )
        
        let id = UUID().uuidString
        lock.lock()
        observers[id, default: []].append(observer)
        lock.unlock()
        
        return id
    }
    
    // MARK: - 监听一次
    public func once(_ name: Notification.Name, queue: OperationQueue? = nil,
                     using block: @escaping (Notification) -> Void) {
        var observer: NSObjectProtocol?
        observer = center.addObserver(
            forName: name,
            object: nil,
            queue: queue ?? self.queue
        ) { [weak self] notification in
            block(notification)
            if let observer = observer {
                self?.center.removeObserver(observer)
            }
        }
    }
    
    // MARK: - 取消监听
    public func off(_ id: String) {
        lock.lock()
        if let obs = observers.removeValue(forKey: id) {
            for observer in obs {
                center.removeObserver(observer)
            }
        }
        lock.unlock()
    }
    
    // MARK: - 模块专用事件
    public func emitModuleEvent(_ module: String, event: String, data: [String: Any]? = nil) {
        let name = Notification.Name("com.xianrenzhilu.module.\(module).\(event)")
        emit(name, userInfo: data)
    }
    
    public func onModuleEvent(_ module: String, event: String,
                              using block: @escaping ([String: Any]?) -> Void) -> String {
        let name = Notification.Name("com.xianrenzhilu.module.\(module).\(event)")
        return on(name) { notification in
            block(notification.userInfo as? [String: Any])
        }
    }
}

// MARK: - 预定义事件
public extension Notification.Name {
    static let moduleEvent = Notification.Name("com.xianrenzhilu.event.module")
    static let dataEvent = Notification.Name("com.xianrenzhilu.event.data")
    static let uiEvent = Notification.Name("com.xianrenzhilu.event.ui")
    static let systemEvent = Notification.Name("com.xianrenzhilu.event.system")
}

// MARK: - 事件类型安全封装
public struct TypedEvent<T> {
    public let name: Notification.Name
    public let payload: T
}