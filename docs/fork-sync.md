# Fork 同步与构建手册（Peoley199/magpie）

本 fork 的上游是 `yetone/magpie`（remote 名 `upstream`），fork 自己的改动长期保留在上游之外。
本文是 2026-10-30 几轮同步（7499ebb5→cd10dfbe 700 提交、→cdf8151a 40、→ffa07395 4、
→f7f2d75f 149）沉淀的操作手册，配套两个脚本：

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
| `internal/gateway/claude_room.go` 里的 `dir := path.Clean`（**不是** `filepath.Clean`） | memLimit 的 cgroup 路径是 Unix 路径，Windows 上 `filepath` 会死循环 |
| `internal/gateway/anthropic_shapes.go` 里的 `zcodeStartPlan` / `withoutZCodeSystem` / `systemText` | ZCode Start Plan（无 GLM key 的 zcode 插件账号）拒绝一切带 system 的请求（405/3012），发前摘除并把文本挪进首条用户消息 |
| `internal/gateway/workdir.go` 里的 `zcodeWorkDir` | ZCode 的 `- Primary working directory:` 行与 Claude Code 的 ` - ` 行区分 |
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

## 四、远端仓库的处理

- **推送**：`git push origin main`，永远是 fast-forward（合并方式保证不改写历史）。禁止 rebase
  fork 自有提交后强推。
- **下次同步的起点**：合并后 `git merge-base main upstream/main` 就是上游最新提交——后续
  `git fetch upstream && git merge upstream/main` 天然只算增量，无需任何清理。
- **tag**：上游 tag 用 `git fetch upstream --tags` 补拉；版本号以 `git describe --tags upstream/main`
  为准（10-30 时是 v0.1.2115 = cdf8151a）。
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
