# 任务：功能2 - 初始化日志系统

## 要怎么做

1. **文件位置**：创建 `02_初始化日志系统.swift`
2. **核心类**：
   - `LogSystem` - 全局单例日志系统
   - `ModuleLogger` - 供各模块使用的日志记录器
   - `LogEntry` - 日志条目结构体
   - `LogLevel` - 日志级别枚举
   - `LogOutput` 协议 + `ConsoleLogOutput` + `FileLogOutput` 实现
3. **技术方案**：
   - 使用 `DispatchQueue` 异步写入，不阻塞主线程
   - 文件日志按天轮转，文件名格式 `log_YYYY-MM-dd.txt`
   - 7天自动清理旧日志
   - 日志目录：`~/Library/Application Support/XianRenZhiLu/Logs/`
   - 支持5个级别：debug < info < warning < error < fatal
   - 默认级别 info，可通过配置修改
4. **API要求**：
   - `LogSystem.shared.log(level:category:message:...)` 主入口
   - `ModuleLogger` 提供便捷方法：debug/info/warning/error/fatal
   - 所有方法支持 `#file`, `#function`, `#line` 自动捕获
5. **线程安全**：
   - 使用 `NSLock` 保护日志队列
   - 文件句柄操作在串行队列执行

## 不能怎么做

1. **不能**在主线程直接写文件（必须用异步队列）
2. **不能**使用 `print()` 作为唯一输出（必须同时支持文件）
3. **不能**让日志文件无限增长（必须7天清理）
4. **不能**在日志路径不存在时崩溃（必须自动创建目录）
5. **不能**暴露文件句柄给外部（必须私有）
6. **不能**使用 `DateFormatter` 频繁创建（必须复用或缓存）

## 常见坑

- 文件句柄忘记关闭导致泄漏
- 多线程同时写文件导致内容混乱
- 日期格式化性能问题
- 日志目录权限问题

## 验收标准

1. 代码能在 macOS Swift 项目编译通过
2. 提供简单测试：写入几条日志，验证文件生成
3. 线程安全测试：多线程并发写入不崩溃
4. 7天清理逻辑：模拟旧文件验证删除

请只实现这一个功能，完成后告诉我。