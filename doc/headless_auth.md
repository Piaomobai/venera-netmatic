# Headless 漫画源登录

账号操作由持有数据目录锁的 Flutter worker 执行。AI 和 API 网关不直接读写账号文件。以下命令和接口已经实现；密码登录及 Cookie 登录取决于源提供的能力，WebView/验证码交互返回 `interaction_required`。

## 准备与选源

将可信的漫画源 `.js` 放入 `<data-dir>/comic_source/`，然后启动或重启 worker。首次使用 picacg 只需要脚本，不需要事先在 GUI 登录。安装脚本意味着执行该脚本；API 不接受上传脚本、读取任意凭据文件或执行任意 JavaScript。

```bash
venera --headless --json --data-dir /private/profile sources list
venera --headless --json --data-dir /private/profile sources status picacg
```

每条搜索、详情或下载命令中的 `sourceKey` 选择漫画源，不存在共享的“当前源”。`sources list` 的 `account` 对象列出登录方式、Cookie 字段顺序、是否支持远端校验和本地会话状态，不返回用户名、密码、Cookie 或 token。

## 首次登录

密码凭据格式：`{"username":"账号","password":"密码"}`。Cookie 格式：`{"cookies":["值1","值2"]}`，顺序对应 `cookieFields`。不接受密码命令行参数。

使用权限为 `0600` 或 `0400` 的私密 JSON 文件：

```bash
venera --headless --json --data-dir /private/profile \
  sources login picacg --credentials-file /private/picacg-login.json
```

也可以通过 `--credentials-stdin` 从标准输入读取 JSON，EOF 后提交。下例使用隐藏密码输入，不把密码写入 shell 历史或进程参数：

```python
import getpass, json, subprocess

credentials = {"username": input("账号: "), "password": getpass.getpass("密码: ")}
subprocess.run([
    "/absolute/path/to/venera", "--headless", "--json",
    "--data-dir", "/private/profile", "sources", "login", "picacg",
    "--credentials-stdin",
], input=json.dumps(credentials), text=True, check=True)
```

macOS 的可执行文件位于应用包 `Contents/MacOS/Venera Netmatic`。沙盒构建的配置及凭据文件须放在应用容器可访问的位置。

picacg 登录后自动使用认证接口校验新 token。其他源若提供 `account.validateSession()`，同样自动校验；未提供的源返回 `unverified`，表示登录函数成功，但尚无独立远端校验。

## 失败、退出、换号与重试

```bash
# 查询本地状态，不发起远端登录
venera --headless --json sources status picacg
# 只校验当前会话，不自动续期
venera --headless --json sources verify picacg
# 使用已保存的账号密码重新认证
venera --headless --json sources reauth picacg
# 退出可以重复调用
venera --headless --json sources logout picacg
# 换号：先清除旧身份，再尝试新账号
venera --headless --json sources login picacg --replace --credentials-file /private/other-account.json
```

同一个部署应始终使用相同的 `--data-dir`。已有账号时，不带 `--replace` 的登录返回 `already_logged_in`，保留旧会话。`--replace`、退出后登录或普通失败重试，一旦开始新的登录请求，失败后均保持退出状态，不恢复旧账号。凭据格式/权限错误、登录方式不支持及等待执行期间取消，不会清除原账号。

退出删除该源的账号、token、其他私有会话数据和已记录归属的 Cookie，清空网络缓存，保留源设置。漫画文件、本地书库、收藏、阅读记录、NAS 配置和任务数据库不受影响。Cookie 归属在源使用网络及 Cookie API 时记录并持久化；旧 GUI 配置中从未被该 worker 使用的 Cookie，仍依赖源自身的 logout 钩子清理。

| 状态/错误码 | 调用方应采取的动作 |
|---|---|
| `logged_out` | 提交新的凭据 |
| `unverified` | 本地有账号；如果 `canVerify` 为 true，调用 verify |
| `authenticated` | 最近登录、校验或续期成功；状态带最近校验时间，不保证未来请求仍有效 |
| `expired` / `authentication_required` | reauth；若无可复用密码，重新提交登录，或退出换号 |
| `authentication_failed` | 不自动反复重试；检查凭据后重新登录或换号 |
| `credentials_required` | 使用私密输入提交凭据；Cookie 会话不能用密码 reauth |
| `invalid_credentials` / `insecure_credentials` | 修正 JSON、字段顺序、大小或文件权限 |
| `already_logged_in` | 显式 logout 或 login --replace |
| `network_error` / `auth_rate_limited` | 检查连接或等待后显式重试，不在后台循环尝试密码 |
| `auth_invalid_response` | 检查源 API 地址、代理和脚本兼容性 |
| `interaction_required` | 在 GUI 完成人工交互后导入会话 |
| `source_cleanup_failed` | 本地凭据已清除，但脚本退出钩子失败；重启 worker 后重试 |
| `cleanup_required` | 当前 worker 已阻止继续使用清理失败的源；修复后重启 |
| `timeout` / `cancelled` / `queue_timeout` | 查询状态后决定是否重试；排队超时不会执行登录 |
| `interrupted` | worker 已重启；查询状态并重新提交，账号操作不会自动重放 |
| `persistence_failed` | 停止 worker，修复存储/权限并检查账号文件后再启动 |

登录和退出经过独占写队列，不会在下载传输执行到一半时换号。登录默认最多排队 30 秒；`--queue-timeout` 可在服务请求中覆盖。执行默认 60 秒，支持 `--timeout`。取消和超时是协作式的：已开始的账号脚本/网络请求先结束，再清理暂存 token，最后释放队列位置。源网络请求保留 15 秒传输期限；任意不结束的第三方 JS 无法被安全强杀，需要重启 worker。

已超时搜索对应的底层 JS Promise 也可能尚未结束。新账号操作会等这些调用结束，防止旧账号的自动续期随后覆盖新账号。

## picacg 续期兼容

headless 为 picacg 提供源内的传输适配：API 返回 401 时合并并发重登，使用新 token 重试一次；如果其他请求已经换过 token，直接使用最新 token。搜索、详情、章节等调用因此共用续期流程，避免旧版详情脚本在重登成功后仍抛旧 401。重登被拒绝后标记 `expired`，等待显式操作，避免高频查询反复尝试错误密码。此适配只针对该源配置的 API 地址，不修改磁盘上的源脚本。

## 常驻服务/API

worker 已运行时，使用 API，而不是另开 CLI 抢占数据目录。

```http
POST /v1/source-auth
Authorization: Bearer <API密钥>
Content-Type: application/json

{"sourceKey":"picacg","action":"login","credentials":{"username":"账号","password":"密码"},"replace":false,"timeout":60,"queueTimeout":30}
```

返回 HTTP 202 和 request ID；通过 `GET /v1/requests/<id>` 等待结果，或 `POST /v1/requests/<id>/cancel` 取消。`action` 支持 `status`、`login`、`logout`、`verify`、`reauth`；只有 login 可携带 credentials/replace。其他动作只需 sourceKey/action，以及可选期限。

普通 `/v1/commands` 可提交状态、退出、校验和重认证命令；登录必须使用专用接口，不能通过命令请求读取 worker 本机凭据文件。API 网关只在内存中转发凭据，worker 的请求日志只记录命令、源和期限。排队中的凭据在取消、过期、完成或关闭时释放；重启后未完成的账号操作标为 interrupted，必须显式重提。

为兼容源的自动重登，账号密码/token 仍保存在 worker 的源数据文件中，Cookie 保存在配置目录的 SQLite 中，均为明文、权限 `0600`；源目录权限 `0700`，写入采用临时文件原子替换。整个配置目录和备份应仅对部署账号开放，不能放进 Git、镜像、普通任务日志或交给 AI。API 密钥只交给可信客户端；远程连接应使用 TLS。

## 验证

```bash
python3 tool/headless_auth_smoke.py --executable /absolute/path/to/venera --profile-root /private/test-root
docker run --rm venera-headless-worker:local --auth-self-test
```

上述自动化脚本使用隔离配置、假账号和回环模拟 API，覆盖首次登录、换号失败和重试、校验、续期合并、退出、取消、超时、worker 崩溃和输出脱敏。`--picacg-script /path/to/picacg.js` 可使用真实源脚本对模拟 API 验证；不读取其 `.data`。该脚本不连接真实服务器；真实服务器需使用单独的隔离配置联测。

已在 macOS 隔离配置中使用真实 picacg 账号和服务完成 CLI/API 联测：登录、搜索翻页与排序、日/周/月排行、分类目录与分类翻页、详情标签的搜索/分类目标、章节目录、强制失效 token 后的自动重登，以及退出、重新登录和显式 reauth 均通过。退出后搜索、排行和分类请求返回 authentication_required，重启后的本地状态保持 logged_out；测试配置已清除。该结果不代表其他源、验证码或账号风控分支已完成真实联测。
