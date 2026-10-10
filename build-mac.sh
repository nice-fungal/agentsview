# build-mac.sh — macOS 桌面端（Tauri）完整构建步骤，纯注释版
#
# 本文件暂时不含任何可执行代码。每个步骤独立、按序执行，
# 后续将据此清理 desktop/scripts/prepare-sidecar.sh 并落地实现。
# 使用 Go 1.27 或更新版本，encoding/json/v2 无需实验开关。
# 依赖已提前安装（pnpm workspace 模式），本脚本不含任何安装步骤。
#
# 最终产物：
#   ./agentsview（根目录，本机构建可供 dev 复用）
#   desktop/src-tauri/binaries/agentsview-<target-triple>
#   desktop/src-tauri/binaries/version.json
#   desktop/src-tauri/tauri.macos.version.conf.json
#   desktop/src-tauri/target/release/bundle/macos/AgentsView.app

# 前置（提前、手动、独立完成；构建步骤与 make 均不处理）
# 定价快照：确认 internal/pricing/snapshot/litellm_snapshot.json.gz
# 存在（正常已随仓库提交）。缺失时手动恢复：
#   go run ./internal/pricing/cmd/litellm-snapshot -restore
# （幂等：本地文件 SHA256 命中 pinned ref 时自动跳过）
# make 的 pricing-snapshot 目标只 print 提醒，不做这件事

# 1. 构建前端（仓库根目录执行），产出 frontend/dist
pnpm --filter agentsview-frontend run build

# 2. 同步 Go embed 目录（仓库根目录执行）
#    注意：internal/web/dist 是全工程共享的 embed 输入，本步骤
#    之后任何 go build（含纯 server 构建）都会嵌入这份前端产物
rm -rf internal/web/dist
cp -r frontend/dist internal/web/dist
printf '%s\n' 'keep embed dir for generated frontend assets' > internal/web/dist/.keep

# 3. 编译 Go 二进制并放置 sidecar 与版本元数据
#    - 真实命令（仓库根目录执行）：
#      make build-release
#    - make 只负责 Go：版本元数据与 ldflags 由 Makefile 顶部统一计算
#      （VERSION/COMMIT/BUILD_DATE/LDFLAGS_RELEASE，唯一信息源）；
#      快照与前端前置已按裁定从 make 移除，make 只 print 提醒。
#      步骤 1/2 的产物 internal/web/dist 是本步骤的输入
#    - 目标优先级：TAURI_ENV_TARGET_TRIPLE → CARGO_BUILD_TARGET → rustc host。
#      Makefile 内联映射 GOOS/GOARCH，未知目标直接报错；交叉编译需
#      配置匹配的 CGO 编译器。本机 macOS 构建无需设置目标变量。
#    - 产出四件：
#      ./agentsview（根目录，本机构建可供 dev 复用）
#      desktop/src-tauri/binaries/agentsview-<target-triple>
#      desktop/src-tauri/binaries/version.json（原始元数据，冒烟验证用）
#      其中 target 与编译目标、sidecar 文件名一致。
#      desktop/src-tauri/tauri.macos.version.conf.json（Tauri 分层配置
#      覆盖，仅一个键 version；semver 化由 make 完成，非 tag 输入
#      落 0.0.0-dev 兜底）

# 4. Tauri 打包
#    - 真实命令（仓库根目录执行）：
#      pnpm --filter agentsview-desktop exec tauri build --bundles app --config src-tauri/tauri.macos.version.conf.json
#    - 显式选择目标时，Tauri 的 --target 必须与步骤 3 解析出的三元组一致；
#      指定 --target 后，bundle 输出位于 target/<target-triple>/release/ 下。
#    - 唯一构建目标是单文件 .app，不存在 dmg，不存在签名
#    - --config 走 Tauri 原生分层合并：override 深度合并到
#      tauri.conf.json 之上，跟踪文件零修改，无需补丁与还原
#    - 文件名遵循生态模式 tauri.<platform>.conf.json，但不是
#      tauri.macos.conf.json 精确名，不会被 CLI 自动加载
#    - 消费：步骤 3 的 sidecar（externalBin）、desktop/ui 自托管
#      webview UI（与 Go 嵌入的 Svelte 产物是两份独立资源，互不影响）
#    - 产出 bundle/macos/AgentsView.app

# 5. 收集产物
#     - 校验 AgentsView.app 存在，缺失即失败
#     - 拷贝到分发目录 dist/desktop/macos/

# 6. 冒烟验证
#     - 运行 sidecar 的 version 子命令：输出不得是 dev、
#       不得缺 commit、不得缺 build date，且与
#       desktop/src-tauri/binaries/version.json 一致
#     - 启动 AgentsView.app，观察窗口、托盘、agentsview:// 深链接

# GOOS/GOARCH 目标三元组映射已内联在 Makefile 的 build-release 配方中，
# 不依赖 prepare-sidecar.sh；Windows sidecar 文件名会添加 .exe。

# 顺序依赖总览：
#   1 前端 → 2 embed → 3 go+sidecar+conf → 4 tauri → 5 收集 → 6 冒烟
#   各步严格按序执行，失败即中止；不再存在任何修改跟踪文件的
#   步骤，也就不再需要还原语义
