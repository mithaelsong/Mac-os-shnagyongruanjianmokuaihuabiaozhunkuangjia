// 功能15: 数据共享
// 对应: 模块间共享数据（如用户登录状态、市场数据）
// 优先级: P1

import Foundation
import os

// MARK: - SharedDataManager
/// 模块间共享数据的中心 (功能15)
///
/// 特性:
/// - 线程安全（os_unfair_lock 保护所有数据操作）
/// - 支持按键订阅数据变更通知
/// - 使用 ModuleLogger 记录所有操作
/// - 模块间共享数据的统一入口
public final class SharedDataManager {
    public static let shared = SharedDataManager()

    /// 订阅条目
    private struct Subscription {
        let id: UUID
        let key: String
        let handler: (Any?) -> Void
    }

    /// 数据存储
    private var storage: [String: Any] = [:]
    /// 订阅列表：键 -> 订阅ID -> 订阅
    private var subscriptions: [String: [UUID: Subscription]] = [:]
    private var lock = os_unfair_lock()
    private let logger = ModuleLogger(category: "SharedDataManager")

    private init() {}

    // MARK: - 保存数据
    /// 保存数据到共享存储
    /// - Parameters:
    ///   - value: 要保存的数据值
    ///   - key: 数据键
    /// - Returns: 保存成功返回 true
    @discardableResult
    public func set(_ value: Any, forKey key: String) -> Bool {
        os_unfair_lock_lock(&lock)
        storage[key] = value
        let subs = subscriptions[key]?.values ?? []
        os_unfair_lock_unlock(&lock)

        logger.info("Set value for key '\(key)'")

        // 通知所有订阅该键的监听者（锁外调用，避免死锁）
        for subscription in subs {
            subscription.handler(value)
        }

        return true
    }

    // MARK: - 读取数据
    /// 读取指定键的数据
    /// - Parameter key: 数据键
    /// - Returns: 存储的值，如果键不存在返回 nil
    public func get(_ key: String) -> Any? {
        os_unfair_lock_lock(&lock)
        let value = storage[key]
        os_unfair_lock_unlock(&lock)

        if value != nil {
            logger.debug("Get value for key '\(key)' (found)")
        } else {
            logger.debug("Get value for key '\(key)' (not found)")
        }

        return value
    }

    // MARK: - 删除数据
    /// 删除指定键的数据
    /// - Parameter key: 数据键
    /// - Returns: 如果键存在并删除成功返回 true，不存在返回 false
    @discardableResult
    public func remove(_ key: String) -> Bool {
        os_unfair_lock_lock(&lock)
        let existed = storage.removeValue(forKey: key) != nil
        let subs = subscriptions[key]?.values ?? []
        os_unfair_lock_unlock(&lock)

        if existed {
            logger.info("Removed value for key '\(key)'")
            // 通知订阅者该键已被删除（值为 nil）
            for subscription in subs {
                subscription.handler(nil)
            }
        } else {
            logger.warning("Remove failed: key '\(key)' not found")
        }

        return existed
    }

    // MARK: - 检查键是否存在
    /// 检查指定键是否存在于共享存储中
    /// - Parameter key: 数据键
    /// - Returns: 存在返回 true，否则返回 false
    public func contains(_ key: String) -> Bool {
        os_unfair_lock_lock(&lock)
        let exists = storage.keys.contains(key)
        os_unfair_lock_unlock(&lock)

        logger.debug("Contains check for key '\(key)': \(exists)")
        return exists
    }

    // MARK: - 订阅数据变更
    /// 订阅指定键的数据变更通知
    /// 当该键的数据被 set 或 remove 时，handler 会被调用
    /// - Parameters:
    ///   - key: 要监听的数据键
    ///   - handler: 变更回调，接收当前值（删除时为 nil）
    /// - Returns: 订阅令牌 UUID，用于取消订阅
    @discardableResult
    public func subscribe(_ key: String, handler: @escaping (Any?) -> Void) -> UUID {
        let token = UUID()
        let subscription = Subscription(id: token, key: key, handler: handler)

        os_unfair_lock_lock(&lock)
        subscriptions[key, default: [:]][token] = subscription
        os_unfair_lock_unlock(&lock)

        logger.info("Subscribed to key '\(key)' (token: \(token.uuidString.prefix(8))...)")
        return token
    }

    // MARK: - 取消订阅
    /// 取消指定订阅
    /// 传入无效的令牌时记录警告日志，不会崩溃
    /// - Parameter token: 订阅时返回的 UUID
    public func unsubscribe(_ token: UUID) {
        os_unfair_lock_lock(&lock)
        for key in subscriptions.keys {
            if subscriptions[key]?.removeValue(forKey: token) != nil {
                // 如果该键下没有订阅者了，清理空字典
                if subscriptions[key]?.isEmpty == true {
                    subscriptions.removeValue(forKey: key)
                }
                os_unfair_lock_unlock(&lock)
                logger.info("Unsubscribed token \(token.uuidString.prefix(8))... from key '\(key)'")
                return
            }
        }
        os_unfair_lock_unlock(&lock)
        logger.warning("Unsubscribe failed: token \(token.uuidString.prefix(8))... not found")
    }

    // MARK: - 统计信息
    /// 当前存储的键值对数量
    public var keyCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage.count
    }

    /// 获取所有存储的键列表
    public var allKeys: [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(storage.keys)
    }

    /// 获取指定键的订阅者数量
    public func subscriberCount(for key: String) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return subscriptions[key]?.count ?? 0
    }
}

// MARK: - 测试代码
/// SharedDataManager 功能验证
/// 运行方式：在单元测试或 Playground 中调用 `SharedDataManagerTests.runAllTests()`
public final class SharedDataManagerTests {

    /// 运行所有测试
    public static func runAllTests() {
        print("=== SharedDataManager Tests ===")
        testBasicReadWrite()
        testRemoveAndContains()
        testSubscriptionNotification()
        testUnsubscribe()
        testThreadSafety()
        print("\n=== All SharedDataManager Tests Passed ✅ ===")
    }

    // MARK: - 测试1: 数据读写
    private static func testBasicReadWrite() {
        print("\n🧪 Test 1: Basic Read and Write")

        let manager = SharedDataManager()

        // 写入多种类型的数据
        let set1 = manager.set("BTC-USDT", forKey: "symbol")
        let set2 = manager.set(42_000.5, forKey: "price")
        let set3 = manager.set(["theme": "dark", "language": "zh"], forKey: "config")

        guard set1 && set2 && set3 else {
            fatalError("❌ Test 1 failed: set returned false")
        }

        // 读取并验证
        guard let symbol = manager.get("symbol") as? String, symbol == "BTC-USDT" else {
            fatalError("❌ Test 1 failed: symbol read incorrect")
        }
        guard let price = manager.get("price") as? Double, price == 42_000.5 else {
            fatalError("❌ Test 1 failed: price read incorrect")
        }
        guard let config = manager.get("config") as? [String: String],
              config["theme"] == "dark" else {
            fatalError("❌ Test 1 failed: config read incorrect")
        }

        // 读取不存在的键
        let missing = manager.get("nonexistent")
        guard missing == nil else {
            fatalError("❌ Test 1 failed: nonexistent key should return nil")
        }

        print("✅ Test 1 passed: Read/write works correctly")
    }

    // MARK: - 测试2: 删除与存在检查
    private static func testRemoveAndContains() {
        print("\n🧪 Test 2: Remove and Contains")

        let manager = SharedDataManager()
        manager.set("value", forKey: "toBeRemoved")
        manager.set("keep", forKey: "toBeKept")

        // 检查存在性
        guard manager.contains("toBeRemoved") else {
            fatalError("❌ Test 2 failed: contains should be true before removal")
        }
        guard !manager.contains("nonexistent") else {
            fatalError("❌ Test 2 failed: contains should be false for nonexistent key")
        }

        // 删除存在的键
        let removed = manager.remove("toBeRemoved")
        guard removed else {
            fatalError("❌ Test 2 failed: remove should return true for existing key")
        }
        guard !manager.contains("toBeRemoved") else {
            fatalError("❌ Test 2 failed: key should not exist after removal")
        }
        guard manager.get("toBeRemoved") == nil else {
            fatalError("❌ Test 2 failed: get should return nil after removal")
        }

        // 删除不存在的键
        let removedAgain = manager.remove("toBeRemoved")
        guard !removedAgain else {
            fatalError("❌ Test 2 failed: remove should return false for nonexistent key")
        }

        // 未删除的键应仍然存在
        guard manager.contains("toBeKept") else {
            fatalError("❌ Test 2 failed: unrelated key should still exist")
        }

        print("✅ Test 2 passed: Remove and contains work correctly")
    }

    // MARK: - 测试3: 订阅通知
    private static func testSubscriptionNotification() {
        print("\n🧪 Test 3: Subscription Notification")

        let manager = SharedDataManager()
        var receivedValue: Any?
        var callCount = 0
        let countLock = NSLock()

        let token = manager.subscribe("notifyKey") { value in
            countLock.lock()
            receivedValue = value
            callCount += 1
            countLock.unlock()
        }

        // 第一次 set 应触发通知
        manager.set("first", forKey: "notifyKey")

        countLock.lock()
        let count1 = callCount
        let val1 = receivedValue as? String
        countLock.unlock()

        guard count1 == 1 else {
            fatalError("❌ Test 3 failed: expected 1 notification, got \(count1)")
        }
        guard val1 == "first" else {
            fatalError("❌ Test 3 failed: expected 'first', got \(String(describing: val1))")
        }

        // 第二次 set 应再次触发通知
        manager.set("second", forKey: "notifyKey")

        countLock.lock()
        let count2 = callCount
        let val2 = receivedValue as? String
        countLock.unlock()

        guard count2 == 2 else {
            fatalError("❌ Test 3 failed: expected 2 notifications, got \(count2)")
        }
        guard val2 == "second" else {
            fatalError("❌ Test 3 failed: expected 'second', got \(String(describing: val2))")
        }

        // 修改其他键不应触发此订阅
        manager.set("other", forKey: "otherKey")

        countLock.lock()
        let count3 = callCount
        countLock.unlock()

        guard count3 == 2 else {
            fatalError("❌ Test 3 failed: unrelated key change should not trigger notification, got \(count3)")
        }

        // 删除应触发通知（值为 nil）
        manager.remove("notifyKey")

        countLock.lock()
        let count4 = callCount
        let val4 = receivedValue
        countLock.unlock()

        guard count4 == 3 else {
            fatalError("❌ Test 3 failed: remove should trigger notification, got \(count4)")
        }
        guard val4 == nil else {
            fatalError("❌ Test 3 failed: remove notification should pass nil, got \(String(describing: val4))")
        }

        manager.unsubscribe(token)
        print("✅ Test 3 passed: Subscription notifications work correctly")
    }

    // MARK: - 测试4: 取消订阅
    private static func testUnsubscribe() {
        print("\n🧪 Test 4: Unsubscribe")

        let manager = SharedDataManager()
        var received = false

        let token = manager.subscribe("unsubKey") { _ in
            received = true
        }

        // 取消订阅
        manager.unsubscribe(token)

        // 修改数据不应触发已取消的订阅
        manager.set("newValue", forKey: "unsubKey")

        guard !received else {
            fatalError("❌ Test 4 failed: unsubscribed handler should not be called")
        }

        // 取消不存在的令牌不应崩溃
        manager.unsubscribe(UUID())

        print("✅ Test 4 passed: Unsubscribe works correctly")
    }

    // MARK: - 测试5: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 Test 5: Thread Safety (100 concurrent writers + readers)")

        let manager = SharedDataManager()
        let group = DispatchGroup()
        let iterations = 100

        // 并发写入
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                manager.set("value-\(i)", forKey: "key-\(i)")
                group.leave()
            }
        }

        // 并发读取（同时发生）
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                _ = manager.get("key-\(i)")
                group.leave()
            }
        }

        // 并发订阅
        var tokens: [UUID] = []
        let tokenLock = NSLock()
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let token = manager.subscribe("sharedKey") { _ in }
                tokenLock.lock()
                tokens.append(token)
                tokenLock.unlock()
                group.leave()
            }
        }

        group.wait()

        // 验证写入结果
        guard manager.keyCount == iterations else {
            fatalError("❌ Test 5 failed: expected \(iterations) keys, got \(manager.keyCount)")
        }

        // 验证订阅结果
        let subCount = manager.subscriberCount(for: "sharedKey")
        guard subCount == iterations else {
            fatalError("❌ Test 5 failed: expected \(iterations) subscribers, got \(subCount)")
        }

        // 并发取消订阅
        let unsubGroup = DispatchGroup()
        tokenLock.lock()
        let tokensToCancel = tokens
        tokenLock.unlock()

        for token in tokensToCancel {
            unsubGroup.enter()
            DispatchQueue.global().async {
                manager.unsubscribe(token)
                unsubGroup.leave()
            }
        }
        unsubGroup.wait()

        let remainingSubs = manager.subscriberCount(for: "sharedKey")
        guard remainingSubs == 0 else {
            fatalError("❌ Test 5 failed: expected 0 subscribers after unsubscribe, got \(remainingSubs)")
        }

        print("✅ Test 5 passed: Thread safety verified (\(iterations) concurrent ops)")
    }
}
