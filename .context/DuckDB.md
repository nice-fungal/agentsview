# DuckDB 调查结果

调查日期：2026-10-09。本文记录调查时工作区源码的行为及 Go 后端体积实验，
不代表所有平台或所有发布版本的结果。

## 它在应用中做什么

DuckDB 是可选的会话数据分析和只读访问后端。默认收集、编辑和浏览会话
仍使用 SQLite。DuckDB 保存从 SQLite 生成的副本，可重新生成，
不承担主档案职责。

当前用途是：

- 用 DuckDB SQL 对会话、项目、模型及使用量进行自定义分析。
- 生成一个便于携带和交给 DuckDB 工具使用的数据库文件。
- 从副本提供只读 AgentsView 网页界面。
- 通过 Quack 协议让其他机器读取这份副本。

这是现有功能的用途说明，不是所有查询都会更快的性能结论。
用法以 [DuckDB Mirror](../docs/duckdb.md) 和
[README](../README.md#duckdb-mirror-and-quack) 为准。

## 为什么复制一份数据

项目采用 SQLite 保存主档案、DuckDB 保存派生副本的架构：

```text
原始会话文件 -> SQLite 主档案 -> duckdb push -> sessions.duckdb 副本
```

保留 SQLite 可以继续使用现有入库流程、编辑能力和全文索引。
复制数据让另一套数据库引擎和分析工具消费同样的会话内容。
普通本地浏览和搜索不需要这个副本；支持另一种数据库使用方式
是当前架构选择，不是所有应用都必须复制数据的要求。

副本需要显式运行 `agentsview duckdb push` 才会创建或更新。
`duckdb push --watch` 可以持续更新，但数据流仍是 SQLite 到 DuckDB 单向。
副本可能落后于主档案，不是完整应用备份。

缺失、损坏或版本不匹配等情况下，push 会重建副本；通常增量更新会
替换变化的会话并应用记录的删除。实现见
[push.go](../internal/duckdb/push.go)、[sync.go](../internal/duckdb/sync.go)
和 [rebuild.go](../internal/duckdb/rebuild.go)。

## 有没有连接云端数据库

默认是本机进程内运行的数据库引擎，读写本地 `sessions.duckdb` 文件。
不需要云服务，也不需要单独启动数据库服务器。

Quack 是另行启用的远程读取方式：一台机器运行
`agentsview duckdb quack serve` 暴露副本，另一台配置 Quack URL，
通过 `duckdb status` 或 `duckdb serve` 读取。
远端可以部署在云服务器上，但这不是默认使用方式。

`duckdb push` 只写本地镜像，不向 Quack 远端写入。
配置了远端 URL 时，push 会拒绝执行并要求取消该配置。
远程读取仍会使用客户端进程中的 DuckDB 引擎，不能视为只链接一个轻量网络客户端。
连接实现见 [connect.go](../internal/duckdb/connect.go)。

## 搜索能力有没有增强

当前实现没有带来更强的文本搜索能力。

| 能力 | SQLite 主数据库 | DuckDB 副本 |
| --- | --- | --- |
| 全文搜索索引 | FTS5 索引 | 未使用全文索引，以字符串匹配兼容查询 |
| 子串和正则搜索 | 支持 | 支持 |
| 语义与混合搜索 | 配置匹配的向量索引后支持 | 当前不支持 |

DuckDB 的关键词查询使用 `ILIKE` 字符串匹配；内容搜索没有全文索引。
文档指出大档案上的内容搜索会更慢，本次没有重新做搜索性能基准。
实现见 [DuckDB Store](../internal/duckdb/store.go) 和
[SQLite Search](../internal/db/search.go)。

DuckDB 擅长分析型查询，不代表这里的会话搜索会更强，
也不代表当前统计页面必须依赖它。

## UI 实际有没有使用

默认桌面启动参数是 `agentsview serve --background`，打开 SQLite，
再将 SQLite 交给 HTTP 服务。因此默认会话列表、搜索和统计分析页面
都没有使用 DuckDB。

证据见 [桌面启动参数](../desktop/src-tauri/src/lib.rs) 和
[默认服务初始化](../cmd/agentsview/main.go)。

前端业务代码中没有找到启用 DuckDB、生成副本、配置 Quack 或切换到 DuckDB
的界面与调用。自动生成的 API 客户端有 `/api/v1/push/duckdb`，
但存在生成接口不等于业务 UI 使用了它。

用户手动执行 `agentsview duckdb serve` 后，服务端会把 DuckDB 接入同一套
HTTP API，并提供同一套只读 UI。桌面 UI 的通用远程服务器设置也可以连接
这个 HTTP 服务；前端不直接连接 Quack。

相关证据见 [DuckDB 服务初始化](../cmd/agentsview/duckdb.go) 和
[远程服务器设置](../frontend/src/lib/components/settings/RemoteSettings.svelte)。

## 为什么它会增加 Go 二进制体积

[driver.go](../internal/duckdb/driver.go) 导入 `duckdb-go/v2`，
静态链接预编译 DuckDB 库。驱动目前只排除 Windows ARM64，
其他支持平台的通用程序会包含它。
[backends.go](../cmd/agentsview/backends.go) 默认注册 DuckDB 镜像后端。
即使用户没有创建副本，链接内容也已经占据文件空间。

在 macOS ARM64、Go 1.27、CGO、`fts5`、`jsonv2`、`-trimpath` 和
`-ldflags='-s -w'` 条件下，临时对照构建结果如下。MB 使用十进制单位。

| 构建 | 字节数 | MB |
| --- | ---: | ---: |
| 原始 Go 后端 | 135,674,066 | 135.67 |
| 实验排除 DuckDB 驱动依赖链 | 85,905,330 | 85.91 |
| 减少 | 49,768,736 | 49.77 |

实验通过临时 Go overlay 替换驱动文件，排除实际 DuckDB 引擎。
它会禁用 DuckDB，不是保持全部行为不变的修复，也不是整个包目录的磁盘大小统计。
实验未修改仓库实现或运行到实际数据目录。

本次链接映射还识别了以下原生库代码和数据。统计只计实际链接的、
占据文件空间的符号，排除了仅占运行内存的零初始化段。

| 原生库 | 约 MB |
| --- | ---: |
| DuckDB 核心 | 25.83 |
| ICU 扩展 | 7.40 |
| 核心函数扩展 | 5.73 |
| Parquet 扩展 | 2.25 |
| 自动补全扩展 | 1.18 |
| JSON 扩展 | 0.53 |

这些是链接内容归属，不是分别移除这些扩展后的构建差值。
它们不包含完整的链接段开销和 Go 依赖、运行时信息，
不能拿合计值代替整个 DuckDB 依赖链的 49.77 MB 增量。

发布构建已经使用 `-s -w`；重建同等大小，额外 strip 也没有带来有效减少。
主要开销是实际引擎及相关依赖，而不是漏删调试信息。

## 后续可以考虑的优化

普通桌面使用没有直接使用 DuckDB，却承担了通用后端中的引擎体积。
可以评估按构建选择启用 DuckDB、单独分发对应后端，或定制静态库扩展集合。

这需要保留显式使用 DuckDB 和 Quack 的用户流程，并评估兼容性。
定制扩展前也须确认实际 SQL 和远程连接的需要。
这些是待评估的建议，本次没有实现，也没有批准删除现有功能。
