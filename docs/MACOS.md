# macOS 原生移植与构建

本分支使用 GameMaker 的 macOS 运行器和本地动态库，不依赖 Wine 或 Windows 虚拟机。原项目的 Windows 原生扩展在 macOS 上由 `libFvmNativeSupport.dylib` 提供兼容实现。

仓库包含预先构建的 `extensions/WindowsNative/libFvmNativeSupport.dylib`，与上游提交 Windows DLL 的方式一致。直接在 GameMaker 中打开项目即可使用这个通用 macOS 动态库；只有重新编译原生库或使用下方自动构建脚本时，才需要 Apple Command Line Tools。

当前验证状态（2026-09-27，macOS 14.5，GameMaker IDE 2026.0.0.16 / Runtime 2026.0.0.23）：

- 原生扩展：arm64 与通过 Rosetta 执行的 x86_64 两个架构各通过 20 项测试。
- 完整游戏编译：GML、1694 个精灵、75 个声音、12 个着色器、541 个对象、7 个房间与 282 个数据文件已编译完成。
- 原生 ARM64 运行：运行器完成初始化并进入主循环，音频组已加载，`save0.json` 成功写入。
- 本地打包：已从最新编译资源与官方运行器生成 ad-hoc 签名的 `.app`，通过 `codesign --verify --deep --strict`；保留 App Sandbox。GameMaker 官方 `PackageZip` 因本机未配置开发者签名身份而未完成发布签名。
- 实际界面：中文主菜单、关卡选择、鼠标布阵、数字键选卡、60 FPS 战斗与 Shift 120 FPS 加速均已确认。
- 自动存档：卡牌/宝石强化、胜利奖励、购买、任务领奖、装备与改名均在事务完成后写入；两秒检测永久进度变更、30 秒保存计时，并在失焦/换房间/退出时保存。真实原生 VM 集成测试 44/44 通过（事务、隔离、去重、写入/重命名故障与恢复均覆盖）。
- 存档重启：已确认角色等级与已通关进度在正常退出、升级本地安装后仍能读取。
- 下载发行包：已从 GitHub 下载 `v2.4.1-macos-coop.2` ZIP，校验 SHA-256、严格签名与四个核心二进制，再解压安装并通过正常应用入口启动。用户完成系统容器授权后，系统日志确认沙盒初始化成功及正常退出（状态 0）；原存档进度保留并成功再次写入。本次安装未取得自动化界面截图。
- 通关展示：首通/重复通关的奖励牌、实际卡面、分页与跳过动画通过独立 VM 7 项测试，重复结算不会再次发奖。
- 尚未完成：完整 Intel 游戏、所有关卡、全部系统文件选择与窗口模式的逐项验收。

Intel 当前只验证了原生扩展，尚未验证完整游戏；实际战斗验证不代表所有关卡与边界情况已覆盖。

## 所需环境

- macOS Ventura 13 或更新版本，Apple Silicon 或 Intel Mac。
- [GameMaker LTS 2026.0.0.16](https://gms.yoyogames.com/GameMaker-2026.0.0.16.pkg)，对应项目的 `IDEVersion`。
- GameMaker runtime **2026.0.0.23**，包含 base、本机架构构建工具和 mac 模块。首次启动 IDE 时选择 macOS 运行时即可。
- 在 GameMaker IDE 中登录自己的账号。本仓库的 Igor 构建脚本使用 IDE 生成的 `licence.plist`，不下载、生成或分享账号授权文件。
- Apple Command Line Tools：如未安装，运行 `xcode-select --install`。构建动态库需要 `clang++`、SDK、`lipo` 和 `codesign`。
- Python 3，用于运行时版本检查和原生库测试。

默认使用 **GMS2 VM**：游戏运行在原生 macOS GameMaker 运行器中，不需要完整 Xcode。**GMS2 YYC** 另需完整 Xcode；macOS 14.5 可使用 Xcode 16.2。详见 [GameMaker 2026.0 对应的 macOS 设置说明](https://github.com/YoYoGames/GameMaker-Bugs/wiki/macOS-GMS2/08ff3aa424799ad74ec9ba71d11cb2f0afe5c91d) 和 [Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements)。

## 构建和运行

在仓库根目录执行：

```sh
# 检查运行时和已登录账号；不读取或显示授权文件内容。
./tools/macos/build.sh doctor

# 只编译并测试原生库，无需 GameMaker 登录。
./tools/macos/build.sh native

# 编译游戏，不启动。
./tools/macos/build.sh compile

# 编译并运行游戏。
./tools/macos/build.sh run

# 构建本机使用的独立沙盒应用，无需 Apple Developer ID。
./tools/macos/build.sh package-local

# 使用自己的发布签名身份生成 macOS ZIP 包。
./tools/macos/build.sh package
```

每次游戏构建前，脚本先编译包含 arm64 与 x86_64 的通用动态库，验证其架构与本地签名，再将其放入 `extensions/WindowsNative/libFvmNativeSupport.dylib`。脚本随后调用已安装运行时的原生 Igor 执行 `Mac Compile`、`Mac Run` 或 `Mac PackageZip`。运行时必须与固定版本一致，避免较新编译器静默改变项目格式。

构建缓存、临时文件、日志和打包输出默认位于 `~/Library/Caches/FVM-Reborn/macos/`。ZIP 输出目标为 `~/Library/Caches/FVM-Reborn/macos/output/FVM_Reborn-macOS.zip`；GameMaker 还可能将 `.app` 留在项目 macOS 设置的 App Output 目录。日志存入 `~/Library/Caches/FVM-Reborn/macos/logs/`，默认只允许当前用户读取。分享日志前仍应检查其中是否包含自己的本地路径或账号信息。

使用用户缓存目录是为了让运行器读取构建资源、写入 `debug.log` 时不访问受 macOS 隐私保护的“文稿”目录。本机曾在构建输出位于文稿目录时遇到运行器等待文件访问授权，迁移输出后已能完成初始化。这是选择合适的构建目录，不需要调整系统隐私或安全设置。游戏存档仍使用 GameMaker 的 `game_save_id` 可写存档目录，与构建缓存分开。

可通过环境变量覆盖路径，不需要改脚本：

```sh
FVM_GAMEMAKER_RUNTIME="/path/to/runtime-2026.0.0.23" \
FVM_GAMEMAKER_USER="$HOME/Library/Application Support/GameMakerStudio2-LTS2026/your_user_id" \
FVM_MACOS_BUILD_DIR="$HOME/Library/Caches/FVM-Reborn-build" \
./tools/macos/build.sh run
```

存在多个登录账号时，必须用 `FVM_GAMEMAKER_USER` 指定账号目录。脚本仅检查授权文件是否存在且非空，实际授权和有效期由 Igor 校验。账号授权文件、访问密钥、缓存和构建日志不应提交到 Git。

完整 Xcode 已配置时，可使用 `FVM_GAMEMAKER_OUTPUT=YYC ./tools/macos/build.sh compile`。请先验证默认 VM 构建，再排查 YYC 工具链问题。

### Apple Silicon 编译器的音频转换问题

在 macOS 14.5、runtime 2026.0.0.23 上观察到默认并行音频转换会在 `GMAssetCompiler.GMSound.DoFFMPEG` 的 `Process.Start` 内触发 `System.AccessViolationException`。这发生在 GameMaker 编译工具中。将并行度降为 1 后，本机已完整通过音频转换和后续资源编译。因此脚本默认串行构建；可显式使用 `FVM_GAMEMAKER_JOBS=1 ./tools/macos/build.sh compile`。更高并行度需要在自己的系统上验证后再启用。

脚本启动 Igor 时同时设置 `COMPlus_ZapDisable=1`，与 [YoYoGames 官方 gm-cli 的 macOS 工具启动方式](https://github.com/YoYoGames/gm-cli/blob/main/src/spawn.ts) 保持一致，避免使用会引发兼容问题的预编译 .NET 镜像。该设置只作用于本次构建进程及其子进程，不修改安装的运行时或系统设置；无需另行安装或替换 .NET。

## 原生库测试与 CI

无需 GameMaker 账号即可独立执行：

```sh
bash FvmNativeSupport/macos/build.sh
python3 FvmNativeSupport/macos/test_native.py
```

`macos-native.yml` 工作流只构建并测试原生扩展，检查通用架构和签名。它不会声称已编译、启动或测试完整游戏，也不会上传 GameMaker 账号授权文件。

## 本地运行、打包与发布

本机没有配置 Apple Developer ID。GameMaker `PackageZip` 已完成游戏代码与资源编译，但 Application Oven 随后的发布签名返回 `Selected entitlements require explicit Signing Identifier`。因此另提供 `package-local.py`，使用官方 VM 运行器与已编译的 `game.zip` 组装供本机使用的应用。它不是编译器，不获取或修改 GameMaker 授权，也不依赖某次 Application Oven 留下的临时目录。

```sh
./tools/macos/build.sh package-local
```

该命令先用已登录的 GameMaker 执行 `Mac Compile`，确认本次新归档已生成后直接本地组装；不调用 Application Oven 的发布签名步骤，所有编译错误都会使构建失败。成功后打印 `output/local-时间戳/FVM Reborn.app` 的完整路径。`package-local` 只支持 VM。

也可单独对已编译的 VM `game.zip` 运行 `python3 tools/macos/package-local.py --output /new/path/FVM\ Reborn.app`。该脚本支持 `--game-zip`、`--runtime`、`--icon` 和 `--zip`，并读取 `FVM_MACOS_BUILD_DIR` / `FVM_GAMEMAKER_RUNTIME`。它不能修复编译错误。

脚本每次从官方 runner 复制新应用，将已编译资源放入 `Contents/Resources`、原生库放入 `Contents/MacOS`，从仓库的 PNG 用 macOS `sips` / `iconutil` 生成图标，并写入归档中的应用标识和版本。它还使用 Command Line Tools 编译 arm64/x86_64 通用启动器 `FVM_Launcher`，按由内至外的顺序签名动态库、内层运行器与应用，最后执行严格签名校验。现有 `.app` 或 ZIP 不会被覆盖；需要重新打包时选择新的输出路径。

启动器解决 runtime 2026.0.0.23 在下载隔离路径中的启动崩溃：App Translocation 可让 `NSBundle` 返回 `/private/var/...`，而运行器检查资源时会把已存在路径规范化为 `/var/...`。前缀比较不一致会使它找不到包内 `options.ini`，随后在加载游戏前解引用空指针。启动器用相同的 Foundation 规则规范化包内 `game.ios` 路径，通过官方 `-game` 参数启动未修改的 `Mac_Runner`，保留原参数。此修复不移除下载隔离标记或更改系统安全设置。

应用入口为 `Contents/MacOS/FVM_Launcher`，测试和命令行启动也应使用它。内层 `Mac_Runner` 仅带 `app-sandbox` 与 `inherit`，按 [Apple 沙盒辅助进程规则](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) 继承应用原有权限和容器；启动器不修改 bundle ID、HOME 或存档位置。只验证内层运行器能直接运行，不能代替下载 ZIP 后通过正常应用入口启动的验收。

本地应用使用标准 ad-hoc 签名，保留 App Sandbox、向外访问网络，以及通过系统文件选择框获得用户选定文件的读写权限。它不会填入空的团队/应用授权标识，不访问钥匙串，不修改 Gatekeeper、SIP 或系统隐私设置。应用可复制到自己的 `~/Applications` 后双击启动；脚本不会启动游戏。

本地签名未经过 Apple 公证。面向其他用户的常规发布应配置自己拥有的 Apple Developer ID，按 [GameMaker macOS 选项文档](https://manual.gamemaker.io/lts/en/Settings/Game_Options/macOS.htm) 完成发布签名和公证。签名原理及流程参考 [Apple 关于本地 ad-hoc 签名的说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 和 [Apple macOS 签名说明](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)。

### 更新已有安装时的存档访问授权

macOS 14 或更新版本会将沙盒容器与应用的代码签名关联。本测试包使用 ad-hoc 签名，更新后签名身份可能变化；即使应用标识与存档位置不变，系统也可能要求新版应用获得访问旧容器的许可。这与首次打开未公证应用时的开发者验证提示是两个独立步骤，见 [Apple 关于沙盒容器访问的说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

先正常退出旧版，再用新版替换应用并通过 Finder 打开。若 macOS 请求应用访问已有数据，请核对应用名称和下载来源，再通过该系统提示决定是否允许。等待许可时，应用可能尚未显示游戏窗口；拒绝许可可能使这次启动失败。原存档应保留在原容器内，不要删除容器、修改容器元数据、移除下载隔离标记或关闭 Gatekeeper 来处理这一提示。

隔离回归已确认：原运行器不更换入口、只更新版本并重新 ad-hoc 签名，也会触发同样的容器访问请求。系统日志明确记录签名不在旧容器 ACL 内并请求授权；等待发生在 `main` 之前。新启动器的路径回归 22/22 通过，覆盖 ZIP 解压、`/private/tmp` 别名、空格及中文路径、参数保留和沙盒文件写读。

2026-09-27 已对从 GitHub 实际下载的 `v2.4.1-macos-coop.2` 归档完成解压、安装及正常入口启动验证。系统日志确认用户通过普通容器授权后，启动器和运行器成功启动、沙盒正常初始化，并以状态 0 退出；直接打开下载解压出的应用也正常退出。存档文件比对确认原进度保留并再次成功写入。自动化界面工具超时，因此未核验本次安装的画面截图；两台实际异地 Mac 的人工合作验收与全部关卡仍未完成。

## 验收项目

发布前至少实际确认：启动与主菜单、中文字体、窗口及全屏切换、声音、创建和读写存档、一场完整战斗、实验室关卡导入与下载、退出后重新启动。完成验证后应在本文件记录系统版本、架构、GameMaker 版本、通过项目和已知问题。

## 自动存档机制

永久进度的关键事务完成后立即保存。事务嵌套会合并写盘，避免只保存升级结果却漏掉扣除的金币/材料。胜利奖励在胜利产生时提交，结算动画不会再次发奖。

先写同目录 `.pending`，关闭后回读验证，再轮换有效主档到 `.bak` 并提交新主档。加载会检查主档、已完整写入的 pending 与备份，损坏文件不会被静默重置。此流程提供中断恢复，不宣称跨平台的多步重命名是单步原子操作。写入失败会提示并保留可恢复的旧档，自动保存继续重试。

只有成功加载的当前槽允许保存；切槽在旧档保存及新档读取成功后才更新设置。备份导入前先生成时间戳快照，取消选择不会被当作成功。

### 独立存档与通关界面验收

`python3 tools/macos/test-autosave.py` 在唯一测试应用容器中运行真实存档脚本；只对临时副本注入写入关闭/重命名故障，不接触正常游戏存档。`python3 tools/macos/test-victory.py` 使用真实界面和素材验证结算幂等、卡面、跳过与分页；加 `--interactive` 可预览。
