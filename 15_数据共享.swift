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

        logger.info("写入键 '\(key)'")

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
            logger.debug("读取键 '\(key)' (已找到)")
        } else {
            logger.debug("读取键 '\(key)' (未找到)")
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
            logger.info("已删除键 '\(key)'")
            // 通知订阅者该键已被删除（值为 nil）
            for subscription in subs {
                subscription.handler(nil)
            }
        } else {
            logger.warning("删除失败: 键 '\(key)' 未找到")
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

        logger.debug("包含检查: 键 '\(key)' = \(exists)")
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

        logger.info("已订阅键 '\(key)' (token: \(token.uuidString.prefix(8))...)")
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
                logger.info("已取消订阅 token \(token.uuidString.prefix(8))... 键 '\(key)'")
                return
            }
        }
        os_unfair_lock_unlock(&lock)
        logger.warning("取消失败: token \(token.uuidString.prefix(8))... 未找到")
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
        print("=== 数据共享测试 ===")
        testBasicReadWrite()
        testRemoveAndContains()
        testSubscriptionNotification()
        testUnsubscribe()
        testThreadSafety()
        print("\n=== 全部数据共享测试通过 ✅ ===")
    }

    // MARK: - 测试1: 数据读写
    private static func testBasicReadWrite() {
        print("\n🧪 测试1: 数据读写")

        let manager = SharedDataManager()

        // 写入多种类型的数据
        let set1 = manager.set("BTC-USDT", forKey: "symbol")
        let set2 = manager.set(42_000.5, forKey: "price")
        let set3 = manager.set(["theme": "dark", "language": "zh"], forKey: "config")

        guard set1 && set2 && set3 else {
            fatalError("❌ 测试1失败: set返回false")
        }

        // 读取并验证
        guard let symbol = manager.get("symbol") as? String, symbol == "BTC-USDT" else {
            fatalError("❌ 测试1失败: symbol读取不正确")
        }
        guard let price = manager.get("price") as? Double, price == 42_000.5 else {
            fatalError("❌ 测试1失败: price读取不正确")
        }
        guard let config = manager.get("config") as? [String: String],
              config["theme"] == "dark" else {
            fatalError("❌ 测试1失败: config读取不正确")
        }

        // 读取不存在的键
        let missing = manager.get("nonexistent")
        guard missing == nil else {
            fatalError("❌ 测试1失败: 不存在的键应返回nil")
        }

        print("✅ 测试1通过: 数据读写正确")
    }

    // MARK: - 测试2: 删除与存在检查
    private static func testRemoveAndContains() {
        print("\n🧪 测试2: 删除与存在检查")

        let manager = SharedDataManager()
        manager.set("value", forKey: "toBeRemoved")
        manager.set("keep", forKey: "toBeKept")

        // 检查存在性
        guard manager.contains("toBeRemoved") else {
            fatalError("❌ 测试2失败: 删除前contains应为true")
        }
        guard !manager.contains("nonexistent") else {
            fatalError("❌ 测试2失败: 不存在的键contains应为false")
        }

        // 删除存在的键
        let removed = manager.remove("toBeRemoved")
        guard removed else {
            fatalError("❌ 测试2失败: 删除存在的键应返回true")
        }
        guard !manager.contains("toBeRemoved") else {
            fatalError("❌ 测试2失败: 删除后键不应存在")
        }
        guard manager.get("toBeRemoved") == nil else {
            fatalError("❌ 测试2失败: 删除后get应返回nil")
        }

        // 删除不存在的键
        let removedAgain = manager.remove("toBeRemoved")
        guard !removedAgain else {
            fatalError("❌ 测试2失败: 删除不存在的键应返回false")
        }

        // 未删除的键应仍然存在
        guard manager.contains("toBeKept") else {
            fatalError("❌ 测试2失败: 未被删除的键应仍然存在")
        }

        print("✅ 测试2通过: 删除与存在检查正确")
    }

    // MARK: - 测试3: 订阅通知
    private static func testSubscriptionNotification() {
        print("\n🧪 测试3: 订阅通知")

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
            fatalError("❌ 测试3失败: 期望1次通知，实际\(count1)")
        }
        guard val1 == "first" else {
            fatalError("❌ 测试3失败: 期望'first'，实际\(String(describing: val1))")
        }

        // 第二次 set 应再次触发通知
        manager.set("second", forKey: "notifyKey")

        countLock.lock()
        let count2 = callCount
        let val2 = receivedValue as? String
        countLock.unlock()

        guard count2 == 2 else {
            fatalError("❌ 测试3失败: 期望2次通知，实际\(count2)")
        }
        guard val2 == "second" else {
            fatalError("❌ 测试3失败: 期望'second'，实际\(String(describing: val2))")
        }

        // 修改其他键不应触发此订阅
        manager.set("other", forKey: "otherKey")

        countLock.lock()
        let count3 = callCount
        countLock.unlock()

        guard count3 == 2 else {
            fatalError("❌ 测试3失败: 无关键变化不应触发通知，实际\(count3)")
        }

        // 删除应触发通知（值为 nil）
        manager.remove("notifyKey")

        countLock.lock()
        let count4 = callCount
        let val4 = receivedValue
        countLock.unlock()

        guard count4 == 3 else {
            fatalError("❌ 测试3失败: 删除应触发通知，实际\(count4)")
        }
        guard val4 == nil else {
            fatalError("❌ 测试3失败: 删除通知应传递nil，实际\(String(describing: val4))")
        }

        manager.unsubscribe(token)
        print("✅ 测试3通过: 订阅通知正确")
    }

    // MARK: - 测试4: 取消订阅
    private static func testUnsubscribe() {
        print("\n🧪 测试4: 取消订阅")

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
            fatalError("❌ 测试4失败: 已取消的订阅不应被调用")
        }

        // 取消不存在的令牌不应崩溃
        manager.unsubscribe(UUID())

        print("✅ 测试4通过: 取消订阅正确")
    }

    // MARK: - 测试5: 线程安全
    private static func testThreadSafety() {
        print("\n🧪 测试5: 线程安全 (100并发读写)")

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
            fatalError("❌ 测试5失败: 期望\(iterations)个键，实际\(manager.keyCount)")
        }

        // 验证订阅结果
        let subCount = manager.subscriberCount(for: "sharedKey")
        guard subCount == iterations else {
            fatalError("❌ 测试5失败: 期望\(iterations)个订阅者，实际\(subCount)")
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
            fatalError("❌ 测试5失败: 取消订阅后应无订阅者，实际\(remainingSubs)")
        }

        print("✅ 测试5通过: 线程安全验证 (\(iterations)并发操作)")
    }
}
