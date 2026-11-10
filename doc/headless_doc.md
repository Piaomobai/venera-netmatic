# Venera Headless CLI

Headless 在桌面应用内运行，用于脚本、定时任务和 AI 工具适配。漫画源支持密码/Cookie 登录、验证、退出和换号重试，见 [Headless 登录流程](headless_auth.md)。已有 GUI 账号和 NAS 连接也可以复用。

```bash
venera --headless --json <command> [arguments] [options]
```

macOS 需要直接调用应用内的可执行文件，例如：

```bash
"Venera Netmatic.app/Contents/MacOS/Venera Netmatic" --headless --json help
```

macOS 的 headless 从原生入口启动独立 Flutter 引擎，跳过主窗口与菜单加载，并禁止应用激活。连续执行 CLI 命令不会弹出黑色窗口、抢占前台或出现临时 Dock 图标。

## 输出、状态和退出码

建议自动化始终传入 `--json`。stdout 每行一个 JSON 对象，进度使用 `status: running`，最后一行是最终结果：

```json
{"protocolVersion":1,"status":"success","message":"Completed.","data":{}}
```

失败结果包含稳定的 `code` 字段。`queued` 表示仅保存了下载队列，`skipped` 表示请求无需执行。仅入队不表示文件已经下载。

| 退出码 | 含义 |
|---|---|
| 0 | 成功、无需执行，或明确要求的仅入队操作已持久化 |
| 1 | 业务、网络、初始化或存储失败；批处理有失败项也返回 1 |
| 2 | 参数错误 |
| 3 | 数据目录已被其他进程占用 |
| 124 | 超时 |
| 130 | 收到取消信号 |

未传入 `--json` 时，保留旧版 `[CLI PRINT] ` 前缀。原有命令名称保留；失败的退出码已修正。`updatesubscribe` 的最终数据现在包含计数和 `comics` 字段，集成脚本应按新结构读取。

## 全局选项

- `--json`：严格 JSON 行输出；日志与结果分离。
- `--data-dir PATH`：使用独立配置、Cookie、数据库、队列和任务日志目录。未指定时使用 GUI 的默认目录。
- `--cache-dir PATH`：指定缓存目录。使用独立 data-dir 时，默认缓存位于其中的 `cache` 子目录。
- `--timeout SECONDS`：1–86400 秒，覆盖命令执行期限。普通查询默认 60 秒；NAS 查询/测试 2 分钟；下载及调度执行 1 小时；NAS 传输 6 小时；配置同步和源更新 5 分钟。常驻 `service serve` / `scheduler serve` 没有默认进程寿命限制。写入和传输超时后等待当前安全提交或回滚，因此不是强制终止时间。
- `--queue-timeout SECONDS`：1–86400 秒，仅用于向常驻服务提交的命令，限制执行前的排队时间。单次 CLI 传入此选项会返回参数错误。
- `--ignore-disheadless-log`：兼容旧参数；headless 默认不输出常规应用日志。
- `--`：后续内容按位置参数读取，可用于以 `--` 开头的搜索词。

参数支持 `--name value` 和 `--name=value`。JSON 参数应按当前 shell 正确引用；示例使用 Bash/zsh 的单引号。

### 同一数据目录仅允许一个进程

新版 GUI 和 CLI 在打开数据库之前共同获取操作系统文件锁。GUI 已打开或有其他 headless 命令运行时，再访问该目录返回 `app_busy`，不会修改其运行记录。锁文件不删除，进程退出后锁自动释放。

独立 CLI 不会向正在运行的 GUI 转发请求。请先关闭 GUI，或使用独立的 data-dir。一个长任务运行时，从该进程的 stdout 读取进度；其他 CLI 进程无法同时查询该目录。需要在下载和调度执行期间接受 AI 查询时，使用下文的 `service serve` 和独立 API 网关。

macOS 沙盒构建仍受文件访问范围限制。任意外部 data-dir 不会自动获得系统授权；测试目录应放在应用容器内，或使用默认目录。Linux 容器使用 Xvfb、Mesa 和独立会话总线提供 Flutter/GTK 环境，无需宿主机桌面或显示器；部署步骤见 [Docker 与服务入口](docker_headless.md)。

### 统一服务入口

```bash
venera --headless --json --data-dir /absolute/profile \
  service serve --socket /short/path/worker.sock

python3 docker/api_server.py --socket /short/path/worker.sock \
  --token-file /private/api-token --host 127.0.0.1 --port 8080
```

服务目前支持 Linux/macOS。API 网关与 Flutter worker 分进程；API 只转发请求，不打开数据目录。worker 独占数据目录和数据库，持续检查到期任务。请不要为同一个目录再启动 `scheduler serve` 或额外 CLI。

Linux Release 在 `bundle/headless/` 中附带 `api_server.py`、`ipc_client.py`、`ai-tags.env.example` 和本说明。裸机运行网关需要 Python 3.9 或更高版本。从源码启动时脚本位于 `docker/`，可以直接在宿主机运行。

网关提供可选的标签显示过滤，默认关闭。进入 `bundle/headless/`，复制 `ai-tags.env.example` 为自己的 `ai-tags.env`，设置 `VENERA_AI_HIDE_TAGS=true`，并填写 `VENERA_AI_HIDDEN_TAGS`（完整标签）和 `VENERA_AI_HIDDEN_TAG_FRAGMENTS`（标签中的词段）。文件中的两个名单均使用 JSON 字符串数组。然后加载配置并使用已有 worker 的 socket 和 token 启动网关：

```bash
set -a
. ./ai-tags.env
set +a
python3 ./api_server.py --socket /short/path/worker.sock \
  --token-file /private/api-token --host 127.0.0.1 --port 8080
```

也可以直接传入 `--hide-tags --hidden-tags '["示例标签"]' --hidden-tag-fragments '["示例词段"]'`。显式的 `--hide-tags` 或 `--no-hide-tags` 优先于 `VENERA_AI_HIDE_TAGS` 环境变量。名单与开关在启动时读取，修改后需重启网关。systemd 部署可在已有网关服务中用 `EnvironmentFile=/absolute/path/ai-tags.env` 加载配置，然后重启该服务。`.env` 只由 Compose 自动加载，独立运行 Python 时请使用上述方式加载环境变量。

过滤仅调整 HTTP 返回的作品 `tags` 字段，作品仍可通过书名、排行和详情查询返回。过滤范围与匹配规则见 [Docker 与服务入口](docker_headless.md)。普通 CLI 的 `--headless` 输出使用原始标签，接入 AI 时请连接此网关。

搜索、详情和列表等交互查询可越过等待中的写请求，包括排队的 NAS 同步；普通传输和排行榜扫描执行期间仍可处理这些查询。最多并发 4 个查询，其中慢速 NAS 查询/连接测试最多占 1 个位置。后台请求最多排队 192 条，所有非交互请求合计最多 224 条，为交互查询保留 32 个排队名额，总上限 256 条。

写入仍一次执行一个；前台写请求优先于 NAS 传输和自动调度，等待超过 30 秒的写请求恢复按到达时间排序。NAS 后台工作在交互查询活跃时先延后最多 2 秒，随后可与查询并行。WebDAV 导入、源更新等需要独占数据的操作保持安全屏障：前台独占写请求等待 1 秒或连续放行 8 个交互查询后，暂停接收新查询，待已有查询结束再执行；后台独占操作使用 30 秒等待阈值。已开始的独占操作期间，查询等待或按自己的排队期限退出。图片下载仍使用已有下载并发设置。

默认排队期限：交互查询 30 秒，普通写请求 10 分钟，NAS 请求及自动调度 1 小时。超过期限的请求保存为 `failed`，错误码 `queue_timeout`、退出码 124，且不会执行。期限写入请求日志，重启和停机时间也计入；旧版日志按原创建时间和默认期限计算，过期工作不会在升级后突然执行。`--timeout` 仅计算开始执行后的时间，与排队期限独立。

自动调度每次只执行一项到期任务，结束后交回写入执行位。NAS 定时同步可让扫描、下载规划先执行；NAS 任务逾期 5 分钟后恢复按到期时间排序。排行榜逐页、逐漫画详情读取、等待初始化和节流等待均检查取消；单次源读取默认上限 60 秒。NAS 文件枚举、哈希分块和传输文件边界也检查取消，已开始的文件安装或上传提交会先安全结束。

HTTP 命令异步返回 request ID，使用该 ID 查询结果或取消。已接受的排队请求和最近 100 条终态结果保存在 worker 数据目录；网关重启不影响任务。worker 重启后恢复排队请求，执行中请求标为 `interrupted`，不会自动重做可能有副作用的命令。已保存的下载队列可以通过 `downloads run` 继续；定时任务仍按自身的恢复和重试规则运行。`--enqueue-only` 只保存下载队列，需要另行提交 `downloads run`。

接口、鉴权、错误码和部署示例见 [Docker 与服务入口](docker_headless.md)。

## 查询命令

| 命令 | 功能及选项 |
|---|---|
| `help` / `--help` | 输出命令及参数清单，不打开数据目录 |
| `sources list` | 已安装源、搜索筛选项、支持的能力、登录状态和脚本加载错误 |
| `sources status <sourceKey>` | 登录能力及本地会话状态，不返回凭据 |
| `sources login <sourceKey>` | `--credentials-file PATH` 或 `--credentials-stdin`；`--replace` 显式换号 |
| `sources logout <sourceKey>` | 清理源会话，保留设置，支持重复退出 |
| `sources verify <sourceKey>` | 远端校验当前会话，不自动重登 |
| `sources reauth <sourceKey>` | 使用已保存密码重新认证 |
| `search <sourceKey> <query>` | 单源搜索；`--page N` 或 `--cursor VALUE`；`--options '["value"]'` |
| `ranking options <sourceKey>` | 源支持的排行周期及分页方式 |
| `ranking get <sourceKey> <option>` | 读取排行；`--page N` 或 `--cursor VALUE` |
| `categories list <sourceKey>` | 完整分类/标签目录及查询目标，支持 `--query/--offset/--limit`；随机展示分组也返回完整目录 |
| `categories options <sourceKey> <category>` | 分类筛选值及默认值，可传 `--param`；等待源动态选项加载 |
| `categories get <sourceKey> <category>` | 分类漫画；`--param VALUE --options '["value"]' --page N` |
| `tags resolve <sourceKey> <namespace> <tag>` | 将详情标签解析为源定义的搜索/分类目标；不启动 GUI |
| `comic get <sourceKey> <comicId>` | 漫画详情 |
| `comic chapters <sourceKey> <comicId>` | 章节目录 |
| `library list` | 本地书库 |
| `favorites list` | 收藏夹列表；传入 `--folder NAME` 查询夹内漫画 |
| `history list` | 阅读历史和进度 |
| `nas list` | NAS ID、名称、协议及默认连接标记，不返回用户名和密码 |
| `nas library <connectionId>` | NAS 书库索引 |
| `downloads list` | 已保存下载队列、进度及关联 jobId |
| `jobs list` | CLI 作业记录 |
| `jobs get <jobId>` | 指定作业状态和结果 |

`library list`、`favorites list --folder`、`history list` 和 `nas library` 支持 `--query TEXT --offset N --limit N`。limit 默认 50，最大 1000；结果包含 `total`、`items` 和 `nextOffset`。这些搜索基于标题和已有标签，不提供 OCR 或图像语义搜索。

```bash
venera --headless --json sources list
venera --headless --json search mysource '漫画名称' --page 1
venera --headless --json ranking options picacg
venera --headless --json ranking get picacg H24
venera --headless --json categories list picacg
venera --headless --json categories get picacg '全彩' --options '["ld"]' --page 2
venera --headless --json tags resolve picacg Tags '标签'
venera --headless --json comic get mysource comic-id
venera --headless --json library list --query '作者或标题' --limit 20
venera --headless --json favorites list --folder '追更'
venera --headless --json nas library nas-id --query '标题'
```

不同源分别使用页码或游标。搜索结果返回 `pagination`，以及相应的 `maxPage` 或 `nextCursor`。通过 `sources list` 获取筛选项，`--options` 中的值按源定义的顺序提供。

排行选项必须来自 `ranking options`；picacg 的 `H24`、`D7`、`D30` 分别为日、周、月榜。分类选项来自 `categories options`，动态选项在查询前等待加载，隐藏规则与分类名称一起应用。排行、分类和标签目标查询均属于交互优先级，可以越过排队中的 NAS 工作。

`tags resolve` 返回目标，不自动打开页面。`target.action` 为 `search` 时，将 `target.query` 传给 search；为 `category` 时，将 `target.category`、`target.param` 传给 categories get。picacg 的普通 Tags 标签走搜索，Categories 标签走分类，Author 标签走作者分类（param 为 a）。不支持的 GUI 目标返回 unsupported，不执行任意脚本或 URL。

源初始化钩子会在实际调用前等待。需要网页登录或对话框交互的源无法保证全自动；请在 GUI 中完成交互后重试。CLI 不提供任意 JavaScript 或 shell 执行入口。

## 下载队列

```bash
# 默认等待整个已保存队列完成，包括指定的后续 NAS 上传
venera --headless --json downloads add mysource comic-id
venera --headless --json downloads add mysource comic-id --chapters '["chapter-id"]' --nas nas-id

# 只保存队列，然后退出
venera --headless --json downloads add mysource comic-id --enqueue-only

# 恢复并执行已有队列
venera --headless --json downloads run

# 移除停止状态的队列项，保留已下载文件
venera --headless --json downloads remove mysource comic-id
```

下载使用现有增量规划器，跳过本地已有章节，保留图片并发下载设置；队列中的漫画依次执行。未指定章节时补齐缺失章节。指定的章节必须存在，且数组不能为空。

默认命令会等待**整个队列**执行完成。已有队列项的章节范围或 NAS 目标不会被静默替换；需要修改时先移除该队列项再提交。

队列以顺序写入、临时文件替换的方式保存。只有本地漫画注册、文件写入、可选 NAS 上传以及队列持久化完成后，CLI 才报告下载完成。失败项保留在队列中，使用 `downloads run` 重试。队列损坏或缺少恢复所需漫画源时保留原文件并报错，避免覆盖尚未恢复的任务。

`--enqueue-only` 返回 jobId 和 `queued`，需要后续执行 `downloads run`；它本身不启动后台服务。作业日志保存在 data-dir 下的 `headless_jobs.json`。重启后，原 running 状态按 interrupted 显示。完成及取消记录保留最近 200 条，未完成记录保留。

## NAS 与 WebDAV 同步

```bash
venera --headless --json nas test nas-id
venera --headless --json nas upload nas-id
venera --headless --json nas download nas-id mysource comic-id
venera --headless --json webdav up
venera --headless --json webdav down
```

- `nas upload` 将本地书库增量上传到现有 NAS 连接，复用 SHA-256 清单和已有文件替换逻辑，不删除其他设备的漫画。
- `nas download` 按连接、源和漫画 ID 下载指定漫画，校验可用的清单内容，成功后加入本地书库。
- `webdav up/down` 同步应用配置备份，和 NAS 漫画文件传输是两套操作。未配置或业务层返回错误时返回非零退出码。

这些命令会等待操作结束，返回持久化 jobId。协议类型取决于已配置 NAS 连接；本次真实命令测试使用本机 WebDAV 服务。FTP/FTPS/SMB 的 headless 联机兼容性尚未逐项验证。

当前未实现自动双向冲突合并或远端删除传播。WebDAV 备份清理和导入事务，以及多个设备并发更新 NAS 索引的既有风险，仍需要另行加固。

## 定时任务

```bash
venera --headless --json scheduler types
venera --headless --json scheduler list
venera --headless --json scheduler create nasSync \
  --name '每天备份漫画' \
  --schedule '{"type":"daily","hour":3,"minute":0}' \
  --config '{"nasConnectionId":"nas-id"}'

venera --headless --json scheduler create incrementalDownload \
  --schedule '{"type":"interval","intervalSeconds":3600}' \
  --config '{"scope":"library","maxComicsPerRun":20}'

venera --headless --json scheduler update task-id --name '新名称' \
  --config '{"maxComicsPerRun":50}'
venera --headless --json scheduler disable task-id
venera --headless --json scheduler enable task-id
venera --headless --json scheduler history task-id --limit 20
venera --headless --json scheduler run task-id
venera --headless --json scheduler rundue --max-tasks 100
venera --headless --json scheduler delete task-id
```

`types` 返回现有 runner 类型及默认配置，包括 `rankingMonitor`、`incrementalDownload`、`nasSync`。create 合并默认配置并校验；update 将给定配置合并到原配置。create 还支持 `--disabled` 和 `--run-on-start`。

schedule 使用现有计划结构：

```json
{"type":"interval","intervalSeconds":3600}
{"type":"daily","hour":3,"minute":0}
{"type":"cron","cronExpression":"0 3 * * *"}
```

使用设备本地时区。`rundue` 对调用时已到期的任务取快照，按计划时间和顺序执行一次，每次默认最多 100 项；失败重试和本次执行中新到期的任务留给下次。结果包含执行数量、失败数量及 remainingDue。

CLI 查询任务时不恢复或改写 running 状态，也不把 run-on-start 任务提前到期。执行命令取得数据目录锁后，可以恢复上次中断记录。

`run`、`rundue` 中的增量下载和榜单任务会等待其下载队列完成，包含可选 NAS 上传，再记录最终运行结果；下载失败会使任务失败，并保留可重试队列。

### 常驻执行与系统调度

```bash
venera --headless --json scheduler serve
```

serve 启动后发送 `state: ready` 进度事件，持续检查到期任务，退出前一直持有数据目录锁。它不会作为系统服务自动安装，也不会自动在后台脱离终端。可由系统服务管理器启动，或让系统定时调用 `scheduler rundue`。

收到 SIGINT/SIGTERM 时协作取消；下载暂停并保存，NAS 在当前文件操作安全结束后停止。进度输出与最终结果可能有时间间隔。用 `jobs get` 检查原作业、用 `scheduler history` 检查调度结果；它们分别记录传输作业和定时运行。

## 原有更新命令

```bash
venera --headless --json updatescript all
venera --headless --json updatesubscribe --folder '追更'
venera --headless --json updatesubscribe --update-comic-by-id-type comic-id mysource
```

保留原有功能。批量更新有失败项时返回非零退出码；订阅返回检查数量、更新数量、错误数量和更新漫画列表。

## 验证

完整 Flutter 测试覆盖参数、错误结果、跨进程锁、队列等待、取消、定时任务批处理和既有 GUI/下载/NAS 功能。

真实桌面 CLI 的本机测试入口：

```bash
python3 tool/headless_smoke_test.py \
  --executable '/absolute/path/to/venera' \
  --profile-root '/directory/the/application/can/write'
```

该测试在指定根目录下创建并清理独立配置，启动本机 HTTP/WebDAV 测试服务，不使用真实漫画源账号或 NAS。macOS 沙盒应用请将 profile-root 放在应用容器中。Linux ARM64 容器已执行验证；Windows、其他 Linux 架构及桌面环境需分别执行。

macOS 另提供窗口和焦点回归检查，覆盖快速重复命令、查询错误及常驻任务超时。它会检查 WindowServer 窗口、前台激活事件和应用激活策略：

```bash
swiftc -o /tmp/headless-window-probe tool/headless_window_probe.swift
/tmp/headless-window-probe '/absolute/path/to/Venera Netmatic' '/writable/profile/root'
```

2026-11-03 验证：328 项 Flutter 测试通过；13 条命令（含账号交互和常驻统一服务）均以禁止激活的策略运行，窗口及焦点异常为 0。macOS 使用真实 picacg 账号完成 32 项 CLI 和 13 项 API 检查，覆盖登录、搜索、排行、分类、tag、token 续期和退出。Linux ARM64 Docker 通过 14 组账号/查询、9 组 CLI、15 组服务和 8 组跨容器检查，包括查询优先、排队期限、执行超时和排行榜等待页面时的取消。真实账号测试配置已清理；Linux 的账号测试使用回环模拟 API。
