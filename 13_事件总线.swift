// 功能13: 事件总线
// 模块间通信的核心机制，发布/订阅模式
// 优先级: P0

import Foundation
import os

// MARK: - EventType
/// Type-safe event identifier
/// Generic T constrains payload type for compile-time safety
public struct EventType<T> {
    public let name: String
    
    public init(_ name: String) {
        self.name = name
    }
}

// MARK: - Predefined Events (Type-Safe)
public extension EventType where T == [String: Any] {
    /// Module loaded event
    /// Ex: ["moduleName":"KLine","moduleVersion":"1.0.0","loadTime":0.123]
    static var moduleDidLoad: EventType<[String: Any]> { EventType("moduleDidLoad") }
    
    /// Module unloaded event
    /// Ex: ["moduleName":"KLine"]
    static var moduleDidUnload: EventType<[String: Any]> { EventType("moduleDidUnload") }
    
    /// Module load failed event
    /// Ex: ["moduleName":"KLine","error":"Bundle not found"]
    static var moduleLoadFailed: EventType<[String: Any]> { EventType("moduleLoadFailed") }
    
    /// Module started event
    /// Ex: ["moduleName":"KLine"]
    static var moduleStarted: EventType<[String: Any]> { EventType("moduleStarted") }
    
    /// Module stopped event
    /// Ex: ["moduleName":"KLine"]
    static var moduleStopped: EventType<[String: Any]> { EventType("moduleStopped") }
    
    /// Config changed event
    /// Ex: ["key":"theme","oldValue":"light","newValue":"dark"]
    static var configChanged: EventType<[String: Any]> { EventType("configChanged") }
    
    /// Data updated event
    /// Ex: ["source":"market","dataType":"kline","payload":[...]]
    static var dataUpdated: EventType<[String: Any]> { EventType("dataUpdated") }
}

// MARK: - Notification.Name Extension (Legacy Compat)
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
/// Event Bus (Function 13)
/// Core inter-module communication, decouples direct calls
/// Features:
/// - Pub/Sub/Unsub/Once
/// - Thread-safe (os_unfair_lock)
/// - Type-safe (EventType<T> generic)
/// - Custom dispatch queue (async/sync)
/// - Legacy NotificationCenter API
public final class EventBus {
    public static let shared = EventBus()
    
    /// Subscriber internal struct
    private struct Subscriber {
        let id: String
        let once: Bool
        let queue: DispatchQueue?
        let handler: (Any) -> Void
    }
    
    /// EventName -> SubID -> Subscriber
    /// Nested dict for fast lookup
    private var subscribers: [String: [String: Subscriber]] = [:]
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "EventBus")
    
    private init() {}
    
    // MARK: - Subscribe (on)
    /// Subscribe to event, handler called on every emit
    /// - Parameters:
    ///   - event: Event type (EventType<T>)
    ///   - queue: Queue (nil = sync on emitter thread)
    ///   - handler: Handler receiving type-safe payload
    /// - Returns: Subscription ID for cancellation
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
    
    // MARK: - One-time (once)
    /// Subscribe once, auto-unsubscribes after first emit
    /// For one-time notifications (e.g. init complete)
    /// - Parameters:
    ///   - event: Event type
    ///   - queue: Dispatch queue
    ///   - handler: Event handler
    /// - Returns: Subscription ID
    @discardableResult
    public func once<T>(
        _ event: EventType<T>,
        queue: DispatchQueue? = nil,
        handler: @escaping (T) -> Void
    ) -> String {
        let id = UUID().uuidString
        
        // Use weak self to avoid retain cycle
        let subscriber = Subscriber(
            id: id,
            once: true,
            queue: queue,
            handler: { [weak self] payload in
                if let typedPayload = payload as? T {
                    handler(typedPayload)
                }
                // Auto-unsubscribe (once feature)
                self?.removeSubscriber(id: id, from: event.name)
            }
        )
        
        os_unfair_lock_lock(&lock)
        subscribers[event.name, default: [:]][id] = subscriber
        os_unfair_lock_unlock(&lock)
        
        logger.info("Once-subscribed to event '\(event.name)' (id: \(id.prefix(8))...)")
        return id
    }
    
    // MARK: - Unsubscribe (off)
    /// 取消订阅, release handler
    /// Logs warning for invalid ID
    /// - Parameter subscriptionId: ID from on()/once()
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
    
    // MARK: - Emit
    /// Emit event to all subscribers
    /// Iterates without lock for low-latency concurrency
    /// - Parameters:
    ///   - event: Event type
    ///   - payload: Payload (must match EventType<T>)
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
    
    // MARK: - Legacy Emit (Notification.Name)
    /// Legacy NotificationCenter-compatible emit
    /// Converts userInfo to [String:Any], dispatches via type-safe channel
    /// For legacy code or NotificationCenter bridging
    public func emit(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        let dict = userInfo?.reduce(into: [String: Any]()) { result, pair in
            if let key = pair.key as? String {
                result[key] = pair.value
            }
        } ?? [:]
        emit(EventType<[String: Any]>(name.rawValue), payload: dict)
    }
    
    // MARK: - Statistics
    /// Total subscribers across all events
    public var subscriberCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return subscribers.values.reduce(0) { $0 + $1.count }
    }
    
    /// Subscriber count for specific event
    public func subscriberCount<T>(for event: EventType<T>) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return subscribers[event.name]?.count ?? 0
    }
    
    // MARK: - Private Methods
    /// Remove subscriber from event (used by once)
    private func removeSubscriber(id: String, from eventName: String) {
        os_unfair_lock_lock(&lock)
        subscribers[eventName]?.removeValue(forKey: id)
        os_unfair_lock_unlock(&lock)
        logger.info("Auto-removed once-subscriber \(id.prefix(8))... from '\(eventName)'")
    }
}

// MARK: - Test Code
/// EventBus functional tests
/// Run: `EventBusTests.runAllTests()` in tests or playground
public final class EventBusTests {
    
    /// Run all tests
    public static func runAllTests() {
        print("=== 事件总线测试 ===")
        testBasicEmitAndOn()
        testOnceSubscription()
        testOffCancellation()
        testMultipleSubscribers()
        testQueueDispatch()
        testThreadSafety()
        testAllPredefinedEvents()
        testCompatibleAPI()
        print("\n=== 全部事件总线测试通过 ✅ ===")
    }
    
    // MARK: - Test 1: Basic Emit and On
    private static func testBasicEmitAndOn() {
        print("\n🧪 测试1: 基本发布和订阅")
        
        let bus = EventBus()
        var received = false
        var receivedPayload: [String: Any]?
        
        let id = bus.on(.moduleDidLoad) { payload in
            received = true
            receivedPayload = payload
        }
        
        bus.emit(.moduleDidLoad, payload: ["moduleName": "TestModule", "version": "1.0.0"])
        
        guard received else {
            fatalError("❌ 测试1失败: 订阅者未收到事件")
        }
        guard let name = receivedPayload?["moduleName"] as? String, name == "TestModule" else {
            fatalError("❌ 测试1失败: 载荷不正确")
        }
        
        print("✅ 测试1通过: 事件正确接收")
        bus.off(id)
    }
    
    // MARK: - Test 2: Once Subscription
    private static func testOnceSubscription() {
        print("\n🧪 测试2: 一次性订阅")
        
        let bus = EventBus()
        var callCount = 0
        
        bus.once(.moduleDidUnload) { payload in
            callCount += 1
            print("   Once subscriber received: \(payload)")
        }
        
        // 第一次发送（应触发）
        bus.emit(.moduleDidUnload, payload: ["moduleName": "TestModule"])
        // 第二次发送（不应触发）
        bus.emit(.moduleDidUnload, payload: ["moduleName": "TestModule"])
        
        guard callCount == 1 else {
            fatalError("❌ 测试2失败: 一次性订阅被调用了 \(callCount) 次，期望 1 次")
        }
        print("✅ 测试2通过: 一次性订阅仅触发一次")
    }
    
    // MARK: - Test 3: Cancellation
    private static func testOffCancellation() {
        print("\n🧪 测试3: 取消订阅")
        
        let bus = EventBus()
        var received = false
        
        let id = bus.on(.configChanged) { payload in
            received = true
            print("   Received configChanged: \(payload)")
        }
        
        // 取消订阅
        bus.off(id)
        
        // 发送事件（已取消的订阅者不应触发）
        bus.emit(.configChanged, payload: ["key": "theme", "value": "dark"])
        
        guard !received else {
            fatalError("❌ 测试3失败: 已取消的订阅者仍收到事件")
        }
        print("✅ 测试3通过: 取消后未收到事件")
        
        // 取消无效ID（不应崩溃）
        bus.off("invalid-id-12345")
        print("✅ 测试3b通过: 取消无效ID正常处理")
    }
    
    // MARK: - Test 4: Multiple Subscribers
    private static func testMultipleSubscribers() {
        print("\n🧪 测试4: 多个订阅者")
        
        let bus = EventBus()
        var countA = 0
        var countB = 0
        var countC = 0
        
        bus.on(.dataUpdated) { _ in countA += 1 }
        bus.on(.dataUpdated) { _ in countB += 1 }
        bus.on(.dataUpdated) { _ in countC += 1 }
        
        bus.emit(.dataUpdated, payload: ["source": "market", "data": [1, 2, 3]])
        
        guard countA == 1 && countB == 1 && countC == 1 else {
            fatalError("❌ 测试4失败: 期望3个订阅者都触发，实际 A=\(countA), B=\(countB), C=\(countC)")
        }
        print("✅ 测试4通过: 3个订阅者全部收到事件")
    }
    
    // MARK: - Test 5: Queue Dispatch
    private static func testQueueDispatch() {
        print("\n🧪 测试5: 队列分发")
        
        let bus = EventBus()
        let expectation = DispatchSemaphore(value: 0)
        var receivedOnMainThread = false
        
        bus.on(.moduleStarted, queue: .main) { payload in
            receivedOnMainThread = Thread.isMainThread
            print("   Received on main thread: \(Thread.isMainThread), payload: \(payload)")
            expectation.signal()
        }
        
        // 在后台线程发送
        DispatchQueue.global().async {
            bus.emit(.moduleStarted, payload: ["moduleName": "QueueTest"])
        }
        
        let result = expectation.wait(timeout: .now() + 2)
        guard result == .success else {
            fatalError("❌ 测试5失败: 异步分发超时")
        }
        guard receivedOnMainThread else {
            fatalError("❌ 测试5失败: 事件未分发到主线程")
        }
        print("✅ 测试5通过: 事件正确分发到指定队列")
    }
    
    // MARK: - Test 6: Thread Safety
    private static func testThreadSafety() {
        print("\n🧪 测试6: 线程安全 (100个并发订阅)")
        
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
            fatalError("❌ 测试6失败: 期望 \(iterations) 个事件，实际 \(count)")
        }
        print("✅ 测试6通过: \(iterations) 个并发订阅全部收到事件")
    }
    
    // MARK: - Test 7: Predefined Events
    private static func testAllPredefinedEvents() {
        print("\n🧪 测试7: 所有预定义事件")
        
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
            fatalError("❌ 测试7失败: 期望 \(expected)，实际 \(receivedEvents)")
        }
        print("✅ 测试7通过: 所有7个预定义事件正确发送")
    }
    
    // MARK: - 测试8: 兼容API
    private static func testCompatibleAPI() {
        print("
🧪 测试8: 兼容Notification.Name API")
        
        let bus = EventBus()
        var received = false
        var receivedPayload: [String: Any]?
        
        // Subscribe via type-safe API, emit via Notification.Name
        let id = bus.on(.moduleDidLoad) { payload in
            received = true
            receivedPayload = payload
        }
        
        bus.emit(.moduleDidLoad, userInfo: ["moduleName": "CompatModule", "version": "2.0.0"])
        
        guard received else {
            fatalError("❌ 测试8失败: 兼容API订阅者未收到事件")
        }
        guard let name = receivedPayload?["moduleName"] as? String, name == "CompatModule" else {
            fatalError("❌ 测试8失败: 兼容API载荷不正确")
        }
        
        print("✅ 测试8通过: 兼容Notification.Name API工作正常")
        bus.off(id)
    }
}
