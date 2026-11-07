# Fork 同步与构建手册（Peoley199/magpie）

本 fork 的上游是 `yetone/magpie`（remote 名 `upstream`），fork 自己的改动长期保留在上游之外。
本文是 2026-10-30／10-31／11-01／11-05／11-06／11-07 几轮同步（7499ebb5→cd10dfbe 700 提交、
→cdf8151a 40、→ffa07395 4、→f7f2d75f 149、→380032cda 11、→854fc8161 237、→6abacd46c 827、
→84ad780b6 110、→665b9aff1 180）沉淀的操作手册，配套两个脚本：

- `scripts/fork-sync.sh` — 调查→方案→合并→验证→（推送）→构建，一条命令跑完；
- `scripts/fork-suite-compare.sh` — 合并头与合并前基线的红测试对照（判断"回归还是预存"）。

## 一、本机环境事实（先读）

| 事实 | 结论 |
| --- | --- |
| 直连 github.com:443 / proxy.golang.org 被墙 | git 网络命令加 `-c http.proxy=http://127.0.0.1:7897`；go 命令加 `HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=...`。代理端口读注册表 `HKCU\...\Internet Settings\ProxyServer`（当前 7897）；`JAVA_TOOL_OPTIONS` 里的 7892 无进程监听，别用 |
| Windows CI/上游 CI 只编译 `_test.go` 不运行 | 上游自带的 Windows-only 测试缺陷（symlink 权限、Keychain、loopback 句柄、GOOS 守卫缺失）在本地全量跑时会红，**绝大多数不是回归**——判回归必须跑基线对照 |
| 本机 Bun 1.3.14 < 1.4.2 | `TestZCodeStartPlanTakesNoSystem`、`TestPluginToldWhereTheAgentWorks` 等插件端到端测试自动 SKIP，属已知限制 |
| 本机无 make/gcc | 构建见 §七：桌面应用直接 `go build -tags production,comlauncher -H windowsgui`，不需要 make，也不需要 cgo |

## 二、fork 的自有提交（合并时必须保留的指纹）

| 指纹（文件 + 特征串） | 作用 |
| --- | --- |
| ~~`internal/gateway/claude_room.go` 的 `dir := path.Clean`~~ **已退役（11-05）**：上游 #4113 采纳了同一修复且是超集，fork 的 `1805cad0` 已放弃，该文件与上游逐字节相同 | memLimit 的 cgroup 路径是 Unix 路径，Windows 上 `filepath` 会死循环 |
| `internal/gateway/anthropic_shapes.go` 里的 `zcodeStartPlan` / `withoutZCodeSystem` / `systemTextOf` | ZCode Start Plan（无 GLM key 的 zcode 插件账号）拒绝一切带 system 的请求（405/3012），发前摘除并把文本挪进首条用户消息。11-05 起用 `systemTextOf`：上游新测试声明了同名 helper，fork 的函数让名（见 11-05 节） |
| `internal/gateway/workdir.go` 里的 `zcodeWorkDir` | ZCode 的 `- Primary working directory:` 行与 Claude Code 的 ` - ` 行区分。11-06 起它同时出现在 `callerForms` 与 `turnForms`（`<system-reminder>` 作用域里），因为上游 #4940 把读法分成了两层（见 11-06 节） |
| `internal/gateway/gateway.go` forwardOnce 里 `if to == provider.Anthropic && zcodeStartPlan(p)` | 上述摘除的调用点（在 `fitUserBetas` 之后） |
| 测试：`internal/gateway/zcode_start_system_test.go`、`testdata/workdir/zcode-3.16.3.json`、`workdir_test.go` 的 ZCode 用例 | fork 自有，上游没有 |

**指纹必须是判别式的**。10-30 第一次写成 `path\.Clean\("/" \+ parts\[2\]\)`，它匹配的是
`filepath.Clean("/" + parts[2])` 的**子串**——正是我们要替换的那行代码。脚本因此对 upstream 报
"upstream adopted a fork fix"，而实际上上游 `claude_room.go:167` 仍是 `filepath.Clean`。换成
`dir := path\.Clean` 后两边才算得清。写新指纹时用 `git grep` 在 `upstream/main` 和我们 `main`
上各跑一次：必须一个匹配、一个不匹配。

合并前先查**上游是否已自行实现了等价物**（`git grep <指纹> upstream/main`）：上游对 ZCode 3012
的处理是互补方向（`restrictedSaid` 事后让账号休息），两者共存，不算重复；若上游真采纳了同一修复
（如 `path.Clean` 出现在上游 claude_room），合并会冲突或变成冗余，需在合并信息里说明并清理。

## 三、标准流程（脚本已自动化）

```
bash scripts/fork-sync.sh --yes            # 全流程，含构建；不推送
bash scripts/fork-sync.sh --yes --push     # 全流程 + 推送 origin main
bash scripts/fork-sync.sh --yes --suite    # 额外跑 45m 全量套件（本机一次只跑一个套件）
bash scripts/fork-sync.sh --yes --push --install 'D:\magpie'   # 再替换桌面应用（留 .bak 档）
bash scripts/fork-sync.sh --build-only --install 'D:\magpie'   # 不同步，只重建并安装当前头
bash scripts/fork-suite-compare.sh /tmp/fork-suite.log         # 红测试：回归 vs 预存
```

人工需要判断的只有两处（其余全自动）：

1. **合并前**：脚本打印"调查报告"（双方领先数、fork 自有提交、文件重叠、上游是否已采纳指纹）。
   若显示零重叠或重叠不相交 → 直接放行；若上游已采纳某指纹 → 停下人工决策。
2. **全量套件红时**：跑 `scripts/fork-suite-compare.sh`，凡"基线也红（签名一致）"或"上游新测试
   在 Windows 的已知缺陷类"（symlink 权限 / loopback 句柄 / GOOS 守卫 / 跨测试 LOCALAPPDATA 污染 /
   TempDir 文件锁）→ 放行；凡签名变化或无法归类 → 停下查因。
3. **判"是不是我们的问题"的终极一招**：把同一个测试放到**纯上游**树上跑。上游没有 fork 的任何提交，
   在那里还红就与 fork 无关——比跑整包基线快得多，且结论更硬：

   ```
   git worktree add /tmp/up upstream/main
   (cd /tmp/up && HTTPS_PROXY=http://127.0.0.1:7897 go test ./internal/<pkg> -run '^TestX$' -count=1)
   git worktree remove --force /tmp/up && git worktree prune
   ```

### 10-30 实测记录（基线 51 个预存红 + 15 个上游自带红，0 回归）

预存红签名逐一与基线相同（symlink/Keychain/`/bin/sh`/macOS 断言等）。15 个"仅合并头红"的归类：
- 5 个 plugin page 测试：`os.Symlink` 无管理员权限失败；
- 4 个 handover 测试（c26b2992 新增）：`A device attached to the system is not functioning`，
  与预存的 #3568 同类（Windows loopback 文件句柄）；
- 3 个 Hermes 测试（34d38ed6 新增）：fixture 根目录落在 `LOCALAPPDATA\hermes`，testenv 把
  LOCALAPPDATA 指向同进程共享的临时 home，测试间互相污染（Linux 下根在各测试自己的 TempDir 不触发）；
- 1 个 `TestCodexDaemonEnvIsTheTerminals`（4534561f）：断言 Linux 行为，`codexDaemonEnv` 在
  Windows 有提前返回（`codex_daemon.go:378`），测试缺 GOOS 守卫；
- 1 个 `TestFnmWinBins`：fixture 依赖 symlink 成功；
- 1 个 `TestLibraryMCPHub`：断言全过，仅 TempDir 清理遇 Windows 文件锁。

### 10-31 实测记录（ffa07395→v0.1.2232，149 提交；12 包 57 红，0 回归）

基线对照（`fork-suite-compare.sh`，基线 = 上次合并的 fork 侧 9fb675638）：53 个签名与基线一致，
1 个签名变化（`TestLoadConcurrentWithSavesAndEdits`，同为 Windows rename 文件锁，只是卡在 add 而非
remove），3 个"仅合并头红"。这三个都**在纯上游 `f7f2d75f2` 上同样复现**，与 fork 无关：

| 测试 | 现象 | 根因 |
| --- | --- | --- |
| `TestMaskedRecordKeepsSentAndBack` | 单独跑过，与其它 masking 测试同跑就红（`Sent:` 空） | 测试间共享 maskrec 状态，隔离缺陷 |
| `TestRestartSwitchedCodexAppReal` | `index out of range [0]` panic | 子进程 env 只给 `MAGPIE_CODEX_SWITCH_HELPER/TMPDIR/HOME`，Windows 上缺 `TEMP/TMP`，`os.MkdirTemp` 退到 `C:\WINDOWS` 失败（实测报 `testenv: mkdir C:\WINDOWS\magpie-test-home-…: Access is denied`），helper 无输出即退出，`f.started[0]` 越界 |
| `TestSlowTransferIsNotCutShort` | `the server sent and took nothing for 1s (PUT)` | 靠 `SetReadBuffer/SetWriteBuffer` 造慢线路，Windows 上语义不同，线路没有真的变慢 |

顺带记一笔：这一轮我自己的 `fork-suite-compare.sh` 也有个坑——基线一度取 `HEAD^1`，而合并后
又有文档提交，`HEAD^1` 就成了合并提交本身，基线代码与合并头相同，于是 57 个红里只"认出" 15 个。
现在基线取"最后一次合并的第一个父提交"（或第二个参数指定）。

### 10-31 第二轮（f7f2d75f→v0.1.2244，11 提交；12 包 59 红，0 回归）

自动跑完 `--yes --push --install`。三个"仅合并头红"全部排除：

| 测试 | 现象 | 结论 |
| --- | --- | --- |
| `TestT3CodeCodexInstance` | `CreateFile …\T3 "a" $b\userdata\settings.json: The filename … is incorrect` | 上游新测试（d6beb9975）用了 Windows 非法文件名字符；**纯上游树同样红** |
| `TestCodexModelEffortLetsUnrelatedCallsGo` | `a build allocated 566400 bytes, the log's rows are 552184` | 字节上限型断言，满套件负载下 sync.Pool 不保留缓冲；**单跑与整包跑都过**（LESSONS #3472 同类） |
| `TestLibraryMCPHub` | `TempDir RemoveAll cleanup: … used by another process` | npm 进程仍持有文件；**两棵树上单跑都过**，只在满套件里红 |

其余 56 个签名与基线一致、1 个同类签名变化（Windows rename 文件锁）。结论仍是 0 回归。

### 11-01（v0.1.2244→v0.1.2422，**237 提交**；13 包 64 红，0 回归）

`--yes --push --install` 一次跑完（运行中的 app 用改名法装上）。基线对照：56 个签名一致、
1 个同类签名变化、7 个"仅合并头红"。这 7 个全部排除，且**每条都做了纯上游复现**：

| 测试 | 根因（实测） |
| --- | --- |
| `TestGitUpdateInstallsTheBranchsCommitNow`／`TestGitUpdateKeepsACommitPin` | `bun add git+file:///C:/…` 让 Bun 自己崩（"Bun has crashed… a bug in Bun"）；纯上游同样红 |
| `TestHubRootsOfACodexThread` | 转 metadata 里的 `/work/repo` 在 Windows 上不是绝对路径，roots 变成空；纯上游同样红 |
| `TestPackagedByDpkg` | fixture 文件名 `magpie:amd64.list` 含冒号，Windows 上这是 NTFS 备用数据流，文件建不出来，`dpkgOwner` 找不到 → nil；纯上游同样红 |
| `TestSettingsSaveKeepsWhatItDoesNotSend` | 上游新增设置项 `SearchAll` 没加进这个守卫测试的 fixture，守卫当场报"not sent by the Settings page"；纯上游同样红（与平台无关，是真上游红灯） |
| `TestMagpieModelsKeptWhileCatalogStays` | 分配字节上限，`internal/agent` 与上游**逐字节相同**（`git diff` 为空），纯上游同样红 |
| `TestCodexModelEffortLetsUnrelatedCallsGo` | 同类字节上限，靠 sync.Pool，`internal/usage` 与上游相同：同一份代码上游 8 次里 3 次过、本机合并头 8 次全红，属负载相关抖动（LESSONS #3472） |

**一条很有用的判据**：fork 只改 `internal/gateway`（加 docs/scripts）。凡是别的包里的红，
`git diff upstream/main HEAD -- <pkg>` 为空就说明代码与上游完全一样，**根本不可能是 fork 引起的**，
连跑纯上游都省了 —— 上面 `internal/agent`、`internal/usage` 两条就是这样定性的。

另外 `TestMaskedRecordKeepsSentAndBack`（上一轮红）这一轮转绿，属测试间状态相关，不是新问题。

### 11-05（v0.1.2422→v0.1.3005，**827 提交**；16 包 81 红，0 回归）

本轮第一次触发指纹守护的**真实分支**：上游 `9a951eb03`（#4113）采纳了我们的 memLimit 修复，
且是超集（同样 `path.Clean`/`path.Dir`，另加 `path.Join` 标签和 #5118 的 `memOwn`）。按"上游已
采纳 → 取上游、放弃我们的 delta"决策：`claude_room.go` 现在与上游逐字节相同，fork 的 `1805cad0`
退役。指纹清单同步更新（见 §二）。

合并又暴露一个 git 测不出的**语义冲突**：上游新测试 `zenfree_v2_test.go` 声明了 helper
`systemText`，与 fork 的 Start Plan 代码里的同名不同签名函数撞车。fork 侧改名为
`systemTextOf`（只动 fork 自己的文件）。指纹守护测不出这种撞名——记下这个盲区。

基线对照：60 个签名一致、1 个同类变化（`TestHubRootsOfACodexThread`，上游加了 Session 字段）、
20 个"仅合并头红"。这 20 个分布在 `sessions/agent/appdir/browsermcp/library/catalog/gui/claudetui`
——全部与上游**逐字节相同**的包（`git diff upstream/main HEAD -- <pkg>` 为空，fork 只改
internal/gateway），并在纯上游树上逐一复现（20/20 红）。归类：

| 类别 | 测试 |
| --- | --- |
| Windows symlink 权限（library 的 WSL 测试，7 个） | `TestWSLSkillsLinked` 等 |
| 分配字节上限（sync.Pool 负载相关，4 个） | `TestCCListingKeepsItsNames`（3000 文件 12146 allocs）、`TestClaudeViaMagpieKept`、`TestOwnOptionsKept`、`TestViaMagpieKeptWhileCatalogStays` |
| 依赖真实外部程序（3 个） | `TestShimFirstMessageWaitsForTools`（shim 30s 没写字）、`TestDesktopHandlerNeedsItsEntryAndProgram`、`TestImageFromLeavesTheRest` |
| 上游自己的断言在 Windows 失效（其余） | `TestOwnModelsSayTheyGoDirect`（OpenCode Go 模型列表）、`TestFoldersJoinedOnce`、`TestKimiOldSharedEntrySwept` 等 |

转绿：`TestCodexModelEffortLetsUnrelatedCallsGo`、`TestLibraryMCPHub`、
`TestSettingsSaveKeepsWhatItDoesNotSend`（上游修了它的 fixture）——都属负载/状态相关，不是新问题。

### 11-06（v0.1.3005→v0.1.3079，**110 提交**；16 包 84 红，0 回归）

合并冲突第一次真实发生：`internal/gateway/workdir.go`。上游 #4940（`db9d6a610`）把工作目录读法
拆成两层——调用方自己那层（系统提示 + `{role:"system"}` 消息）整段读，对话里的轮次只读调用方
声明过的形式（`<cwd>`/`<env>`/Claude Code 的 `<system-reminder>`），用户消息里**引用**的
`Primary working directory:` 不再算数；fork 侧则在 `workPlace` 里读 ToolResult 部件、并用
`zcodeWorkDir` 在行内任意位置匹配 ZCode 的标签。解法是两头都取：用上游的两层 forms
（`callerForms`/`turnForms`），把 `zcodeWorkDir` 加进 callerForms，并加进 turnForms 的
`<system-reminder>` 作用域；部件循环保留 `ToolResult`。原来靠"` - ` 开头就跳过"实现的
"(was …)"剥离改由 `dirForm.was` 承担，reminder 作用域里同样剥。

第二个 blind spot 记在这：指纹守护只查函数名 `zcodeWorkDir` 在不在上游，看不出它的**语义**
这次被重新安放（放进两层 forms 的具体哪几项），这只能靠人读。

基线对照（`fork-suite-compare.sh`，基线 = 上次合并的第一个父 `0d06f72e8`）：82 个预存红签
名一致、0 个签名变化、3 个"仅合并头红"。这 3 个全部在**纯上游 `84ad780b6` 树上同时复现**
（`go test ./internal/agent -run '^TestHowInstalledWindowsShim$'` 等同样红，断言值完全相同），
与 fork 无关：

| 测试 | 包 | 现象 |
| --- | --- | --- |
| `TestHowInstalledWindowsShim` | agent | 断言 npm 安装命令的形态，Windows 上 npm.cmd 的实际形态与断言不同 |
| `TestMiseShimWindowsFiveAgents` | agent | 同类，mise 的 node prefix 路径断言 |
| `TestPluginAgentMissingSaysSo` | gui | 断言 `~\.config\magpie-kimi`，上游新 fixture 在 Windows 上写法不同 |

另外 `TestMaskedRecordKeepsSentAndBack`（上两轮的红）本轮转绿，属测试间状态相关。

**推送通道**：本轮 `git push origin main` 走默认 ssh 通道一次成功（fetch 同样正常），没有触发
11-05 记的 443 备用通道；那条备用命令仍留在 `~/.ssh/config` 注释里（全文见 §四）。

**构建与安装**：桌面版按 §七 那组命令重建（`v0.1.3079-28-gf2ab8d842`，81,948,672 字节），
应用当时在跑，用改名法装上 `D:\magpie`，旧版留档
`.bak-v0.1.3005-27-g0d06f72e8`（v0.1.3005-27 是上一轮装进去的版本）。

### 11-07（v0.1.3079→v0.1.3216，**180 提交**；16 包 88 红，0 回归）

本轮**没有冲突**：上游也动了 fork 拥有的两个文件（`gateway.go` +302 行、`anthropic_shapes.go`
+101 行），但都自动合并成功。合并后逐项复核指纹存活（`zcodeStartPlan`、`zcodeWorkDir`、
`systemTextOf`、forwardOnce 调用点、workdir 两层 forms 里的 ZCode 项），上游侧仍然一个都没有；
`go build ./...`、`gofmt`、`go vet`、fork 的网关测试全绿。

基线对照（基线 = 上次合并的第一个父 `e2df3991e`）：85 个基线红、88 个合并头红；83 个签名一致、
1 个同类签名变化（`TestLoadConcurrentWithSavesAndEdits`：Windows rename 文件锁，这次卡在
remove 而非 add，与 10-31 记的同类）、4 个"仅合并头红"。这 4 个全部在**纯上游 `665b9aff1`**
上以相同签名复现，与 fork 无关：

| 测试 | 包 | 现象（纯上游同样） |
| --- | --- | --- |
| `TestCodexOwnModelsFollowPicks` | agent | 分配上限：一次读做了 114 allocs，断言 ≤20（字节/分配上限类，与 Windows 无关也不稳定） |
| `TestCheckSkillsFindsNewInGitRepo` | library | `git push` 以 `exit status 0xc0000005`（访问冲突）退出，Windows git 崩溃 |
| `TestAntigravityAppFolder` | sessions | 上游新测试断言 `/work/api`，Windows 上读出的分隔符是 `\work\api` |
| `TestUnroutedHeldReportSaved` | gateway | 只在满套件负载下红；两边**单跑都过**，报告模板等待 50ms 的持有窗口被负载拉长（时序类） |

`TestUnroutedHeldReportSaved` 是唯一落在 fork 改动包（`internal/gateway`）里的新红，所以额外
验证过：测试文件与上游**逐字节相同**、本轮的合并没有碰它、单跑在合并头和纯上游都通过——判为
上游的时序测试在满套件负载下的抖动，不是回归。`TestMaskedRecordKeepsSentAndBack` 继续绿。

**构建与安装**：`v0.1.3216-30-gbaa804eba`（82,914,816 字节，PE subsystem=2），应用正在跑，
改名法装上 `D:\magpie`，旧版留档 `.bak-v0.1.3079-28-gf2ab8d842`。推送一次成功（默认通道）。

## 四、远端仓库的处理

- **推送**：`git push origin main`，永远是 fast-forward（合并方式保证不改写历史）。禁止 rebase
  fork 自有提交后强推。
- **推送通道**：默认 `git push origin main`（ssh）在 11-06、11-07 两轮都一次成功；10-31 与
  11-05 遇到过 22 端口直连被重置，备用通道是 SSH over 443 + 本机代理
  （`ssh://git@ssh.github.com:443/…` + `ProxyCommand=connect -H 127.0.0.1:7897`）。一次性用法：

  ```
  GIT_SSH_COMMAND='ssh -p 443 -i ~/.ssh/Project_JGame_Ugit -o IdentitiesOnly=yes -o ProxyCommand="connect -H 127.0.0.1:7897 ssh.github.com 443"' \
    git push ssh://git@ssh.github.com:443/Peoley199/magpie.git main
  ```
- **下次同步的起点**：合并后 `git merge-base main upstream/main` 就是上游最新提交——后续
  `git fetch upstream && git merge upstream/main` 天然只算增量，无需任何清理。
- **tag**：上游 tag 用 `git fetch upstream --tags` 补拉；版本号以 `git describe --tags upstream/main`
  为准（11-07 时是 v0.1.3216 = 665b9aff1）。
- 合并提交信息按惯例：一行主题（提交数 + fork 修复保留）+ 正文（上游要点、fork 修复为何保留、
  冲突情况、跑了什么）。

## 五、构建

构建与安装的完整步骤见 [§七](#七桌面版构建与安装dmagpie)。要点：桌面应用走 release-windows
那组命令（go-winres + comlauncher + `-H windowsgui`），**不要**用普通 `go build`；纯 CLI 用
`-tags nogui` + `CGO_ENABLED=0`。产物放 `dist/`（上游 .gitignore 已忽略，不污染工作树）。

## 六、脚本实测记录（2026-10-30，全部通过）

`fork-sync.sh` 各路径实跑：
- **调查模式**（无参数）：拉取 → 双向计数 → fork 提交清单 → 文件重叠 → 指纹核查 → 干跑合并并验证
  指纹存活，然后停止，零改动；
- **全流程**（`--yes`）：自动合并 cdf8151a→ffa07395（4 提交，含 Responses WebSocket #4058），
  `go build ./...`、`gofmt`、`go vet`、fork 测试全绿；后又自动合并 149 提交
  （ffa07395→v0.1.2232），一次跑通"合并→验证→构建→安装→推送"；
- **构建+安装**（`--build-only --install 'D:\magpie'`）：重建当前头、替换 `D:\magpie` 里的桌面
  应用、旧版留 `.bak-v<版本>`；
- **幂等**（`--yes --push`，上游已全部合入）：正确输出 `nothing to sync` 并退出，不误合并；
- **脏树保护**：工作树有未提交改动时在任何改动前 `STOP`；
- **指纹守护**：上游若采纳同一修复会 `STOP` 让人决策（10-30 因指纹写错误报过一次，见 §二）。

`fork-suite-compare.sh` 两种输入实跑：预存红 → 判定 "NO new failures" + 签名一致；注入一个假的新
失败 → 准确列为 "failures NEW on the merge head"。

注意：脚本用 `set -uo pipefail`（**没有** `set -e`），因为脏树检查那行是
`grep -q . && die` 形式——去掉 `set -e` 才不会在正常路径上误中止。

## 七、桌面版构建与安装（D:\magpie）

**桌面应用必须按 Makefile 的 `release-windows` 构建**，不是普通 `go build`：

```
go run github.com/tc-hib/go-winres@v0.3.3 make --in build/windows/winres.json \
    --arch amd64 --out rsrc --file-version 0.1.2119 --product-version 0.1.2119
CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" \
    -o internal/update/launcher-amd64.com ./internal/update/launcher
CGO_ENABLED=0 go build -tags production,comlauncher -trimpath \
    -ldflags="-s -w -X main.version=$(git describe --tags --always) -H windowsgui" \
    -o dist/magpie-windows-amd64.exe .
rm -f rsrc_windows_*.syso internal/update/launcher-*.com
```

四个关键点，漏掉任何一个产物都不对：

| 要素 | 作用 | 怎么验 |
| --- | --- | --- |
| `-H windowsgui` | GUI 子系统，否则启动会弹控制台窗口 | PE 头 subsystem 必须是 **2**（3=console） |
| `comlauncher` tag | 把 COM launcher 嵌进 exe（开机/快捷方式路径） | `internal/update/com_embed_windows_*.go` |
| go-winres | 图标 + 文件版本资源（资源管理器里显示 0.1.2119） | PowerShell `VersionInfo.FileVersion` |
| `-tags production` | 生产构建（与发布版一致） | 未带时二进制明显偏小/功能不同 |

**可复现性已实测**：在 `14d97a93` 上用上面这组命令重建，得到 60,389,888 字节，与用户原来
`D:\magpie\magpie-windows-amd64.exe` 大小完全一致（说明命令就是发布流程的那一组）。新头
`0973e30a` 是 71,850,496 字节，增量来自上游 244 个提交（.text +2.6MB、.rdata +6.9MB），
不是构建参数出差错。

**安装**（脚本 `--install` 自动做）：

```
# 应用没在跑时：
cp -p magpie-windows-amd64.exe magpie-windows-amd64.exe.bak-v<旧版本>   # 旧版留档
cp dist/magpie-windows-amd64.exe magpie-windows-amd64.exe
# 应用正在跑时（Windows 不许覆盖或删除运行中的 exe，但**允许改名**）：
mv magpie-windows-amd64.exe magpie-windows-amd64.exe.bak-v<旧版本>
cp dist/magpie-windows-amd64.exe magpie-windows-amd64.exe
./magpie-windows-amd64.exe --version
```

运行中的进程继续用它那份（已改名的）文件，网关不中断；下次从菜单栏退出再启动，同一路径拿到的
就是新版本。10-31 用这招在 `v0.1.2232` 运行中直接装上了 `v0.1.2244`，网关全程 200。

`D:\magpie` 现有的 `.bak` / `.bak-v0.1.1373` 就是同一套留档约定。GUI 子系统的 exe 从控制台
调用 `--version` 仍有输出，可以直接冒烟。

**不要安装 `dist/magpie.exe`**——那是 console 子系统的开发用构建，装上去会多一个黑窗口。

## 八、验证命令速查

```
# fork 修复核心测试（最快闸门）
HTTPS_PROXY=http://127.0.0.1:7897 go test ./internal/gateway -run 'TestWithoutZCodeSystem|TestWorkDir|TestClaudeMem|TestZCodeStartPlan' -count=1
# 全量（LESSONS：-timeout 45m，tee 落盘，一次一个套件）
HTTPS_PROXY=http://127.0.0.1:7897 go test -timeout 45m ./... 2>&1 | tee /tmp/full-suite.log
```
