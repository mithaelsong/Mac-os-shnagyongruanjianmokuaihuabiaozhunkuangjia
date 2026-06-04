// 功能13: 事件总线
// 对应: 模块可以发送事件，其他模块可以监听（类型安全的发布/订阅机制）
// 优先级: P0

import Foundation
import os

// MARK: - EventType
/// 类型安全的事件标识符
/// 使用泛型 T 约束事件载荷类型，编译期即可保证类型安全
public struct EventType<T> {
    public let name: String
    
    public init(_ name: String) {
        self.name = name
    }
}

// MARK: - 预定义事件类型（类型安全版本）
public extension EventType where T == [String: Any] {
    /// 模块加载完成事件
    /// 载荷示例: ["moduleName": "KLine", "moduleVersion": "1.0.0", "loadTime": 0.123]
    static var moduleDidLoad: EventType<[String: Any]> { EventType("moduleDidLoad") }
    
    /// 模块卸载完成事件
    /// 载荷示例: ["moduleName": "KLine"]
    static var moduleDidUnload: EventType<[String: Any]> { EventType("moduleDidUnload") }
    
    /// 模块加载失败事件
    /// 载荷示例: ["moduleName": "KLine", "error": "Bundle not found"]
    static var moduleLoadFailed: EventType<[String: Any]> { EventType("moduleLoadFailed") }
    
    /// 模块启动完成事件
    /// 载荷示例: ["moduleName": "KLine"]
    static var moduleStarted: EventType<[String: Any]> { EventType("moduleStarted") }
    
    /// 模块停止完成事件
    /// 载荷示例: ["moduleName": "KLine"]
    static var moduleStopped: EventType<[String: Any]> { EventType("moduleStopped") }
    
    /// 配置变更事件
    /// 载荷示例: ["key": "theme", "oldValue": "light", "newValue": "dark"]
    static var configChanged: EventType<[String: Any]> { EventType("configChanged") }
    
    /// 数据更新事件
    /// 载荷示例: ["source": "market", "dataType": "kline", "payload": [...]]
    static var dataUpdated: EventType<[String: Any]> { EventType("dataUpdated") }
}

// MARK: - Notification.Name 扩展（兼容 NotificationCenter 的旧代码）
public extension Notification.Name {
    static let moduleDidLoad = Notification.Name("moduleDidLoad")
    static let moduleDidUnload = Notification.Name("moduleDidUnload")
    static let moduleLoadFailed = Notification.Name("moduleLoadFailed")
    static let moduleStarted = Notification.Name("moduleStarted")
    static let moduleStopped = Notification.Name("moduleStopped")
    static let configChanged = Notification.Name("configChanged")
    static let dataUpdated = Notification.Name("dataUpdated")
}

// MARK: - EventBus
/// 事件总线 (功能13)
/// 模块间通信的核心机制，解耦模块间的直接调用关系
/// 特性:
/// - 发布/订阅/取消/一次性订阅
/// - 线程安全（os_unfair_lock 保护订阅者列表）
/// - 类型安全（EventType<T> 泛型约束）
/// - 支持自定义分发队列（异步/同步）
/// - 兼容 NotificationCenter 风格的旧 API
public final class EventBus {
    public static let shared = EventBus()
    
    /// 订阅者内部结构
    private struct Subscriber {
        let id: String
        let once: Bool
        let queue: DispatchQueue?
        let handler: (Any) -> Void
    }
    
    /// 事件名 -> 订阅者ID -> 订阅者
    /// 双层字典结构，快速按事件名和订阅ID定位
    private var subscribers: [String: [String: Subscriber]] = [:]
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "EventBus")
    
    private init() {}
    
    // MARK: - 订阅事件（on）
    /// 订阅指定事件，每次事件发布都会触发 handler
    /// - Parameters:
    ///   - event: 事件类型（EventType<T>）
    ///   - queue: 事件分发队列（nil 表示在发布线程同步调用）
    ///   - handler: 事件处理闭包，接收类型安全的载荷
    /// - Returns: 订阅ID，用于后续取消订阅
    @discardableResult
    public func on<T>(
        _ event: EventType<T>,
        queue: DispatchQueue? = nil,
        handler: @escaping (T) -> Void
    ) -> String {
        let id = UUID().uuidString
        
        let subscriber = Subscriber(
            id: id,
            once: false,
            queue: queue,
            handler: { payload in
                if let typedPayload = payload as? T {
                    handler(typedPayload)
                }
            }
        )
        
        os_unfair_lock_lock(&lock)
        subscribers[event.name, default: [:]][id] = subscriber
        os_unfair_lock_unlock(&lock)
        
        logger.info("Subscribed to event '\(event.name)' (id: \(id.prefix(8))...)")
        return id
    }
    
    // MARK: - 一次性订阅（once）
    /// 订阅指定事件，仅触发一次后自动取消订阅
    /// 适合只需要监听一次的场景（如初始化完成通知）
    /// - Parameters:
    ///   - event: 事件类型
    ///   - queue: 事件分发队列
    ///   - handler: 事件处理闭包
    /// - Returns: 订阅ID（可用于手动取消）
    @discardableResult
    public func once<T>(
        _ event: EventType<T>,
        queue: DispatchQueue? = nil,
        handler: @escaping (T) -> Void
    ) -> String {
        let id = UUID().uuidString
        
        // 使用 weak self 避免在事件总线释放前造成循环引用
        let subscriber = Subscriber(
            id: id,
            once: true,
            queue: queue,
            handler: { [weak self] payload in
                if let typedPayload = payload as? T {
                    handler(typedPayload)
                }
                // 自动取消订阅（once 特性）
                self?.removeSubscriber(id: id, from: event.name)
            }
        )
        
        os_unfair_lock_lock(&lock)
        subscribers[event.name, default: [:]][id] = subscriber
        os_unfair_lock_unlock(&lock)
        
        logger.info("Once-subscribed to event '\(event.name)' (id: \(id.prefix(8))...)")
        return id
    }
    
    // MARK: - 取消订阅（off）
    /// 取消指定订阅，释放对应的 handler
    /// 传入无效的订阅ID时记录警告日志
    /// - Parameter subscriptionId: 订阅时返回的 ID
    public func off(_ subscriptionId: String) {
        os_unfair_lock_lock(&lock)
        for eventName in subscribers.keys {
            if subscribers[eventName]?.removeValue(forKey: subscriptionId) != nil {
                os_unfair_lock_unlock(&lock)
                logger.info("Unsubscribed id \(subscriptionId.prefix(8))... from event '\(eventName)'")
                return
            }
        }
        os_unfair_lock_unlock(&lock)
        logger.warning("Subscription id \(subscriptionId.prefix(8))... not found (already unsubscribed?)")
    }
    
    // MARK: - 发布事件（emit）
    /// 发布事件到所有订阅者
    /// 遍历订阅者列表时无需持有锁，保证高并发下的低延迟
    /// - Parameters:
    ///   - event: 事件类型
    ///   - payload: 事件载荷（类型必须与 EventType<T> 的 T 一致）
    public func emit<T>(_ event: EventType<T>, payload: T) {
        os_unfair_lock_lock(&lock)
        let eventSubscribers = subscribers[event.name]?.values ?? []
        os_unfair_lock_unlock(&lock)
        
        let count = eventSubscribers.count
        guard count > 0 else {
            logger.debug("Event '\(event.name)' emitted but no subscribers")
            return
        }
        
        logger.info("Emitting event '\(event.name)' to \(count) subscriber(s)")
        
        for subscriber in eventSubscribers {
            if let queue = subscriber.queue {
                queue.async {
                    subscriber.handler(payload)
                }
            } else {
                subscriber.handler(payload)
            }
        }
    }
    
    // MARK: - 兼容旧代码的发布接口（基于 Notification.Name）
    /// 兼容 NotificationCenter 风格的发布接口
    /// 内部将 userInfo 转换为 [String: Any] 后通过类型安全通道分发
    /// 适用于旧代码或需要与 NotificationCenter 桥接的场景
    public func emit(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        let dict = userInfo?.reduce(into: [String: Any]()) { result, pair in
            if let key = pair.key as? String {
                result[key] = pair.value
            }
        } ?? [:]
        emit(EventType<[String: Any]>(name.rawValue), payload: dict)
    }
    
    // MARK: - 统计信息
    /// 获取总订阅者数量（所有事件累加）
    public var subscriberCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return subscribers.values.reduce(0) { $0 + $1.count }
    }
    
    /// 获取指定事件的订阅者数量
    public func subscriberCount<T>(for event: EventType<T>) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return subscribers[event.name]?.count ?? 0
    }
    
    // MARK: - 私有方法
    /// 移除指定事件的订阅者（供 once 使用）
    private func removeSubscriber(id: String, from eventName: String) {
        os_unfair_lock_lock(&lock)
        subscribers[eventName]?.removeValue(forKey: id)
        os_unfair_lock_unlock(&lock)
        logger.info("Auto-removed once-subscriber \(id.prefix(8))... from '\(eventName)'")
    }
}

// MARK: - 测试代码
/// 事件总线功能验证
/// 运行方式：在单元测试或 Playground 中调用 `EventBusTests.runAllTests()`
public final class EventBusTests {
    
    /// 运行所有测试
    public static func runAllTests() {
        print("=== EventBus Tests ===")
        testBasicEmitAndOn()
        testOnceSubscription()
        testOffCancellation()
        testMultipleSubscribers()
        testQueueDispatch()
        testThreadSafety()
        testAllPredefinedEvents()
        testCompatibleAPI()
        print("\n=== All EventBus Tests Passed ✅ ===")
    }
    
    // MARK: - 测试1: 基本发布和订阅
    private static func testBasicEmitAndOn() {
        print("\n🧪 Test 1: Basic Emit and On")
        
        let bus = EventBus()
        var received = false
        var receivedPayload: [String: Any]?
        
        let id = bus.on(.moduleDidLoad) { payload in
            received = true
            receivedPayload = payload
        }
        
        bus.emit(.moduleDidLoad, payload: ["moduleName": "TestModule", "version": "1.0.0"])
        
        guard received else {
            fatalError("❌ Test 1 failed: Subscriber did not receive event")
        }
        guard let name = receivedPayload?["moduleName"] as? String, name == "TestModule" else {
            fatalError("❌ Test 1 failed: Payload incorrect")
        }
        
        print("✅ Test 1 passed: Event received with correct payload")
        bus.off(id)
    }
    
    // MARK: - 测试2: 一次性订阅
    private static func testOnceSubscription() {
        print("\n🧪 Test 2: Once Subscription")
        
        let bus = EventBus()
        var callCount = 0
        
        bus.once(.moduleDidUnload) { payload in
            callCount += 1
            print("   Once subscriber received: \(payload)")
        }
        
        // 第一次发射（应触发）
        bus.emit(.moduleDidUnload, payload: ["moduleName": "TestModule"])
        // 第二次发射（不应触发）
        bus.emit(.moduleDidUnload, payload: ["moduleName": "TestModule"])
        
        guard callCount == 1 else {
            fatalError("❌ Test 2 failed: Once subscriber called \(callCount) times, expected 1")
        }
        print("✅ Test 2 passed: Once subscriber called exactly once")
    }
    
    // MARK: - 测试3: 取消订阅
    private static func testOffCancellation() {
        print("\n🧪 Test 3: Off Cancellation")
        
        let bus = EventBus()
        var received = false
        
        let id = bus.on(.configChanged) { payload in
            received = true
            print("   Received configChanged: \(payload)")
        }
        
        // 取消订阅
        bus.off(id)
        
        // 发射事件（不应触发已取消的订阅者）
        bus.emit(.configChanged, payload: ["key": "theme", "value": "dark"])
        
        guard !received else {
            fatalError("❌ Test 3 failed: Cancelled subscriber still received event")
        }
        print("✅ Test 3 passed: Cancelled subscriber did not receive event")
        
        // 测试取消不存在的订阅（不应崩溃）
        bus.off("invalid-id-12345")
        print("✅ Test 3b passed: Cancelling invalid id handled gracefully")
    }
    
    // MARK: - 测试4: 多个订阅者
    private static func testMultipleSubscribers() {
        print("\n🧪 Test 4: Multiple Subscribers")
        
        let bus = EventBus()
        var countA = 0
        var countB = 0
        var countC = 0
        
        bus.on(.dataUpdated) { _ in countA += 1 }
        bus.on(.dataUpdated) { _ in countB += 1 }
        bus.on(.dataUpdated) { _ in countC += 1 }
        
        bus.emit(.dataUpdated, payload: ["source": "market", "data": [1, 2, 3]])
        
        guard countA == 1 && countB == 1 && countC == 1 else {
            fatalError("❌ Test 4 failed: Expected all 3 subscribers to fire once, got A=\(countA), B=\(countB), C=\(countC)")
        }
        print("✅ Test 4 passed: All 3 subscribers received event")
    }
    
    // MARK: - 测试5: 队列分发
    private static func testQueueDispatch() {
        print("\n🧪 Test 5: Queue Dispatch")
        
        let bus = EventBus()
        let expectation = DispatchSemaphore(value: 0)
        var receivedOnMainThread = false
        
        bus.on(.moduleStarted, queue: .main) { payload in
            receivedOnMainThread = Thread.isMainThread
            print("   Received on main thread: \(Thread.isMainThread), payload: \(payload)")
            expectation.signal()
        }
        
        // 在后台线程发射
        DispatchQueue.global().async {
            bus.emit(.moduleStarted, payload: ["moduleName": "QueueTest"])
        }
        
        let result = expectation.wait(timeout: .now() + 2)
        guard result == .success else {
            fatalError("❌ Test 5 failed: Timeout waiting for async dispatch")
        }
        guard receivedOnMainThread else {
            fatalError("❌ Test 5 failed: Event not dispatched to main thread")
        }
        print("✅ Test 5 passed: Event dispatched to specified queue")
    }
    
    // MARK: - 测试6: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 Test 6: Thread Safety (100 concurrent subscriptions)")
        
        let bus = EventBus()
        let group = DispatchGroup()
        let iterations = 100
        var totalReceived = 0
        let countLock = NSLock()
        
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                bus.on(.moduleStopped) { _ in
                    countLock.lock()
                    totalReceived += 1
                    countLock.unlock()
                }
                group.leave()
            }
        }
        
        group.wait()
        
        bus.emit(.moduleStopped, payload: ["moduleName": "ConcurrentTest"])
        
        countLock.lock()
        let count = totalReceived
        countLock.unlock()
        
        guard count == iterations else {
            fatalError("❌ Test 6 failed: Expected \(iterations) events, got \(count)")
        }
        print("✅ Test 6 passed: \(iterations) concurrent subscriptions all received event")
    }
    
    // MARK: - 测试7: 所有预定义事件
    private static func testAllPredefinedEvents() {
        print("\n🧪 Test 7: All Predefined Events")
        
        let bus = EventBus()
        var receivedEvents: [String] = []
        let lock = NSLock()
        
        bus.on(.moduleDidLoad) { _ in lock.lock(); receivedEvents.append("moduleDidLoad"); lock.unlock() }
        bus.on(.moduleDidUnload) { _ in lock.lock(); receivedEvents.append("moduleDidUnload"); lock.unlock() }
        bus.on(.moduleLoadFailed) { _ in lock.lock(); receivedEvents.append("moduleLoadFailed"); lock.unlock() }
        bus.on(.moduleStarted) { _ in lock.lock(); receivedEvents.append("moduleStarted"); lock.unlock() }
        bus.on(.moduleStopped) { _ in lock.lock(); receivedEvents.append("moduleStopped"); lock.unlock() }
        bus.on(.configChanged) { _ in lock.lock(); receivedEvents.append("configChanged"); lock.unlock() }
        bus.on(.dataUpdated) { _ in lock.lock(); receivedEvents.append("dataUpdated"); lock.unlock() }
        
        bus.emit(.moduleDidLoad, payload: [:])
        bus.emit(.moduleDidUnload, payload: [:])
        bus.emit(.moduleLoadFailed, payload: [:])
        bus.emit(.moduleStarted, payload: [:])
        bus.emit(.moduleStopped, payload: [:])
        bus.emit(.configChanged, payload: [:])
        bus.emit(.dataUpdated, payload: [:])
        
        let expected = [
            "moduleDidLoad", "moduleDidUnload", "moduleLoadFailed",
            "moduleStarted", "moduleStopped", "configChanged", "dataUpdated"
        ]
        
        guard receivedEvents == expected else {
            fatalError("❌ Test 7 failed: Expected \(expected), got \(receivedEvents)")
        }
        print("✅ Test 7 passed: All 7 predefined events fired correctly")
    }
    
    // MARK: - 测试8: 兼容 API（Notification.Name + userInfo）
    private static func testCompatibleAPI() {
        print("\n🧪 Test 8: Compatible Notification.Name API")
        
        let bus = EventBus()
        var received = false
        var receivedPayload: [String: Any]?
        
        // 使用类型安全 API 订阅，但用 Notification.Name 风格发布
        let id = bus.on(.moduleDidLoad) { payload in
            received = true
            receivedPayload = payload
        }
        
        bus.emit(.moduleDidLoad, userInfo: ["moduleName": "CompatModule", "version": "2.0.0"])
        
        guard received else {
            fatalError("❌ Test 8 failed: Compatible API subscriber did not receive event")
        }
        guard let name = receivedPayload?["moduleName"] as? String, name == "CompatModule" else {
            fatalError("❌ Test 8 failed: Compatible API payload incorrect")
        }
        
        print("✅ Test 8 passed: Compatible Notification.Name API works correctly")
        bus.off(id)
    }
}
