修复下载后双击启动时的 `quit unexpectedly`：启动器规范化 macOS 临时隔离路径，再交由原版游戏引擎加载资源。应用标识、原存档路径和沙盒权限保持一致。

原生 macOS 移植及双人异地合作测试版。房主的 Mac 运行战斗并保存合作数据库，队友通过邀请码加入；两人共享战役、卡组与资源，各放置一个角色。

- 关键操作自动存档：升级、购买、领取奖励、通关等进度及时保存；写入校验、备份恢复和合作结算防重。
- 可视化通关奖励：金币、材料、真实卡牌与装备图示，首通解锁及动画。
- 合作：公网 WSS、断线暂停与重连、主机持久化、共同奖励、音乐同步，单人存档独立保留。

下载下面的 **FVM-Reborn-macOS-universal-v2.4.1-coop.2.zip**，解压后将其中的 `FVM Reborn.app` 放入应用程序目录。队友无需 GameMaker、Python 或开发账号。ZIP 内有中文开始说明、许可证、构建信息和对应源码链接。

macOS 13+；包含 Apple Silicon / Intel 通用二进制。Apple Silicon 已实际运行，Intel 完整游戏仍待实机验证。当前包为 **ad-hoc 签名，未经过 Apple Developer ID 签名或公证**；如系统无法验证开发者，请核对来源和 SHA-256 后参考 [Apple 官方打开说明](https://support.apple.com/102445)。

**更新已有安装：** 请先正常退出旧版，再替换并打开新版。macOS 14+ 可能因新版临时签名变化，再次请求访问原有游戏数据；核对应用及来源后，通过系统提示决定是否允许。等待授权期间可能尚未出现游戏窗口，拒绝授权可能使这次启动失败。原应用标识与存档目录保持不变；不要删除旧存档容器、修改容器元数据或关闭 Gatekeeper。这个数据访问提示与开发者验证提示相互独立，详见 [Apple 沙盒说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

启动修复的隔离路径回归 22/22 通过；本候选从下载链接安装、正常打开及旧容器系统授权的人工验收仍待完成，不能以命令行测试替代。

[合作安装与操作指南](https://github.com/9Tempest/FVM-Reborn/blob/v2.4.1-macos-coop.2/docs/COOP_MAC.md) · [原生构建说明](https://github.com/9Tempest/FVM-Reborn/blob/v2.4.1-macos-coop.2/docs/MACOS.md)

验证：同一台 Mac 上两个隔离的完整原生客户端，经本地 WS 和公网 WSS 各通过 23/23 检查，包括真实放卡、奖励只发一次、双方数据库进度一致及单人存档隔离。会话 70/70、自动存档 44/44、战斗桥接 32/32、音频 22/22。完整测试在隔离数据中触发胜利来检查结算；尚未完成两台实际异地 Mac 的人工验收或逐关验证。

房主需要保持 Mac 醒着、联网且游戏运行。主机游戏进程退出后，未结束的战斗不能从中途恢复；已确认的共同进度保留。免费测试隧道地址可能改变。当前队友端同步背景音乐与胜负提示，未转发射击等短音效。详见指南中的当前限制。

SHA-256：
```
624b97abcf6099b724e18bbbb9664310b0c00432a4218db1c95803fee09fb1ee  FVM-Reborn-macOS-universal-v2.4.1-coop.2.zip
```
