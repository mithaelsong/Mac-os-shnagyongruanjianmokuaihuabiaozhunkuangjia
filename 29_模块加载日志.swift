// 功能29: 模块加载日志
// 对应: 输出每个模块的加载时间、成功/失败状态
// 优先级: P0

import Foundation
import os.lock

// MARK: - LoadRecord

/// 模块加载记录
/// 记录单次模块加载的完整信息，包括起止时间、耗时和结果
public struct LoadRecord: Codable, Sendable, CustomStringConvertible {
    public let moduleName: String
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let success: Bool
    public let errorMessage: String?

    public var description: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let status = success ? "✅" : "❌"
        let err = errorMessage != nil ? " — \(errorMessage!)" : ""
        return "\(status) [\(fmt.string(from: startTime))-\(fmt.string(from: endTime))] \(moduleName) \(String(format: "%.3f", duration))s\(err)"
    }
}

// MARK: - ModuleLoadLogger

/// 模块加载日志记录器（功能29）
/// 线程安全的单例，记录每个模块的加载耗时和结果，支持导出和统计
public final class ModuleLoadLogger: @unchecked Sendable {

    // MARK: - 单例
    public static let shared = ModuleLoadLogger()

    // MARK: - 私有状态
    private var _records: [LoadRecord] = []
    private var _lock = os_unfair_lock()

    // MARK: - 初始化
    private init() {}

    // MARK: - 锁辅助方法
    @inline(__always)
    private func withLock<T>(_ block: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return block()
    }

    // MARK: - 记录加载事件

    /// 记录模块加载开始
    /// - Parameter moduleName: 模块名称
    /// - Returns: 纳秒级时间戳，用于后续 logLoadEnd 计时
    public func logLoadStart(moduleName: String) -> UInt64 {
        log("[ModuleLoadLogger] 开始加载模块: \(moduleName)")
        return DispatchTime.now().uptimeNanoseconds
    }

    /// 记录模块加载结束
    /// - Parameters:
    ///   - moduleName: 模块名称
    ///   - startTime: logLoadStart 返回的时间戳
    ///   - success: 是否加载成功
    ///   - error: 错误信息（加载失败时）
    public func logLoadEnd(moduleName: String, startTime: UInt64, success: Bool, error: String? = nil) {
        let endTime = DispatchTime.now().uptimeNanoseconds
        let duration = TimeInterval(endTime - startTime) / 1_000_000_000.0
        let endDate = Date()
        let startDate = Date(timeInterval: -duration, since: endDate)

        let record = LoadRecord(
            moduleName: moduleName,
            startTime: startDate,
            endTime: endDate,
            duration: duration,
            success: success,
            errorMessage: error
        )

        withLock {
            _records.append(record)
        }

        if success {
            log("[ModuleLoadLogger] ✅ 模块 \(moduleName) 加载成功，耗时 \(String(format: "%.3f", duration))s")
        } else {
            log("[ModuleLoadLogger] ❌ 模块 \(moduleName) 加载失败，耗时 \(String(format: "%.3f", duration))s — \(error ?? "未知错误")")
        }
    }

    // MARK: - 查询记录

    /// 获取所有加载记录
    /// - Returns: 所有加载记录数组
    public func getLoadReport() -> [LoadRecord] {
        return withLock { Array(_records) }
    }

    /// 按模块名查询加载记录
    /// - Parameter moduleName: 模块名称
    /// - Returns: 该模块的所有加载记录
    public func records(for moduleName: String) -> [LoadRecord] {
        return withLock { _records.filter { $0.moduleName == moduleName } }
    }

    // MARK: - 统计

    /// 成功加载次数
    public var successCount: Int {
        return withLock { _records.filter { $0.success }.count }
    }

    /// 失败加载次数
    public var failureCount: Int {
        return withLock { _records.filter { !$0.success }.count }
    }

    // MARK: - 导出与清除

    /// 导出加载报告为文本
    /// - Returns: 格式化的报告文本
    public func exportReport() -> String {
        let records = getLoadReport()
        var lines: [String] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "zh_CN")

        lines.append("=== 模块加载报告 ===")
        lines.append("生成时间: \(dateFormatter.string(from: Date()))")
        lines.append("总记录数: \(records.count)")
        lines.append("成功次数: \(successCount)")
        lines.append("失败次数: \(failureCount)")
        lines.append("成功率: \(records.isEmpty ? "N/A" : String(format: "%.1f%%", Double(successCount) / Double(records.count) * 100))")
        lines.append("")

        for (index, record) in records.enumerated() {
            let status = record.success ? "✅ 成功" : "❌ 失败"
            lines.append("[\(index + 1)] \(record.moduleName)")
            lines.append("    状态: \(status)")
            lines.append("    开始: \(dateFormatter.string(from: record.startTime))")
            lines.append("    结束: \(dateFormatter.string(from: record.endTime))")
            lines.append("    耗时: \(String(format: "%.3f", record.duration))s")
            if let error = record.errorMessage {
                lines.append("    错误: \(error)")
            }
            lines.append("")
        }

        lines.append("=== 报告结束 ===")
        return lines.joined(separator: "\n")
    }

    /// 清除所有记录
    public func clearRecords() {
        withLock {
            _records.removeAll()
        }
        log("[ModuleLoadLogger] 所有记录已清除")
    }

    // MARK: - 私有日志
    private func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}

// MARK: - 测试

#if DEBUG

/// 模块加载日志测试套件
class ModuleLoadLoggerTests {
    private var logger: ModuleLoadLogger!

    init() {
        logger = ModuleLoadLogger.shared
        logger.clearRecords()
    }

    /// 运行全部测试
    func runAllTests() {
        testLogLoadSuccess()
        testLogLoadFailure()
        testGetLoadReport()
        testRecordsForModule()
        testSuccessFailureCount()
        testExportReport()
        testClearRecords()
        testThreadSafety()
        print("✅ 模块加载日志测试全部通过")
    }

    // 测试1: 成功加载记录
    private func testLogLoadSuccess() {
        let start = logger.logLoadStart(moduleName: "SuccessModule")
        usleep(1000) // 1ms 延迟，确保 duration > 0
        logger.logLoadEnd(moduleName: "SuccessModule", startTime: start, success: true)
        let records = logger.records(for: "SuccessModule")
        assert(records.count == 1, "应有1条记录")
        assert(records[0].success == true, "应标记成功")
        assert(records[0].duration > 0, "耗时应大于0")
        assert(records[0].errorMessage == nil, "成功不应有错误")
        print("✅ testLogLoadSuccess 通过")
    }

    // 测试2: 失败加载记录
    private func testLogLoadFailure() {
        let start = logger.logLoadStart(moduleName: "FailModule")
        logger.logLoadEnd(moduleName: "FailModule", startTime: start, success: false, error: "依赖缺失")
        let records = logger.records(for: "FailModule")
        assert(records.count == 1, "应有1条记录")
        assert(records[0].success == false, "应标记失败")
        assert(records[0].errorMessage == "依赖缺失", "错误信息应匹配")
        print("✅ testLogLoadFailure 通过")
    }

    // 测试3: 获取所有报告
    private func testGetLoadReport() {
        logger.clearRecords()
        let start1 = logger.logLoadStart(moduleName: "ModuleA")
        logger.logLoadEnd(moduleName: "ModuleA", startTime: start1, success: true)
        let start2 = logger.logLoadStart(moduleName: "ModuleB")
        logger.logLoadEnd(moduleName: "ModuleB", startTime: start2, success: false, error: "超时")
        let report = logger.getLoadReport()
        assert(report.count == 2, "报告应有2条记录")
        assert(report[0].moduleName == "ModuleA", "第一条应为ModuleA")
        assert(report[1].moduleName == "ModuleB", "第二条应为ModuleB")
        print("✅ testGetLoadReport 通过")
    }

    // 测试4: 按模块名查询
    private func testRecordsForModule() {
        logger.clearRecords()
        let start1 = logger.logLoadStart(moduleName: "TargetModule")
        logger.logLoadEnd(moduleName: "TargetModule", startTime: start1, success: true)
        let start2 = logger.logLoadStart(moduleName: "TargetModule")
        logger.logLoadEnd(moduleName: "TargetModule", startTime: start2, success: false, error: "重复加载")
        let start3 = logger.logLoadStart(moduleName: "OtherModule")
        logger.logLoadEnd(moduleName: "OtherModule", startTime: start3, success: true)
        let targetRecords = logger.records(for: "TargetModule")
        assert(targetRecords.count == 2, "TargetModule应有2条记录")
        assert(targetRecords.allSatisfy { $0.moduleName == "TargetModule" }, "所有记录模块名应为TargetModule")
        print("✅ testRecordsForModule 通过")
    }

    // 测试5: 成功/失败统计
    private func testSuccessFailureCount() {
        logger.clearRecords()
        let s1 = logger.logLoadStart(moduleName: "M1")
        logger.logLoadEnd(moduleName: "M1", startTime: s1, success: true)
        let s2 = logger.logLoadStart(moduleName: "M2")
        logger.logLoadEnd(moduleName: "M2", startTime: s2, success: true)
        let s3 = logger.logLoadStart(moduleName: "M3")
        logger.logLoadEnd(moduleName: "M3", startTime: s3, success: false, error: "失败")
        assert(logger.successCount == 2, "成功次数应为2")
        assert(logger.failureCount == 1, "失败次数应为1")
        print("✅ testSuccessFailureCount 通过")
    }

    // 测试6: 导出报告
    private func testExportReport() {
        logger.clearRecords()
        let s1 = logger.logLoadStart(moduleName: "ExportTest")
        logger.logLoadEnd(moduleName: "ExportTest", startTime: s1, success: true)
        let report = logger.exportReport()
        assert(report.contains("ExportTest"), "报告应包含模块名")
        assert(report.contains("✅ 成功"), "报告应包含成功状态")
        assert(report.contains("模块加载报告"), "报告应包含标题")
        assert(report.contains("报告结束"), "报告应包含结束标记")
        print("✅ testExportReport 通过")
    }

    // 测试7: 清除记录
    private func testClearRecords() {
        let s = logger.logLoadStart(moduleName: "ClearTest")
        logger.logLoadEnd(moduleName: "ClearTest", startTime: s, success: true)
        assert(logger.getLoadReport().count > 0, "清除前应有记录")
        logger.clearRecords()
        assert(logger.getLoadReport().isEmpty, "清除后应无记录")
        assert(logger.successCount == 0, "成功次数应为0")
        assert(logger.failureCount == 0, "失败次数应为0")
        print("✅ testClearRecords 通过")
    }

    // 测试8: 线程安全（100个并发加载）
    private func testThreadSafety() {
        logger.clearRecords()
        let group = DispatchGroup()
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                let start = self.logger.logLoadStart(moduleName: "Concurrent\(i)")
                self.logger.logLoadEnd(moduleName: "Concurrent\(i)", startTime: start, success: i % 2 == 0)
                group.leave()
            }
        }
        group.wait()
        assert(logger.getLoadReport().count == 100, "应有100条记录，实际有 \(logger.getLoadReport().count)")
        assert(logger.successCount + logger.failureCount == 100, "成功+失败应等于总数")
        print("✅ testThreadSafety 通过")
    }
}

#endif
