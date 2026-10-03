# macOS coop.4：按难度增加通关奖励

下载 [FVM-Reborn-macOS-universal-v2.4.1-coop.4.zip](https://github.com/9Tempest/FVM-Reborn/releases/download/v2.4.1-macos-coop.4/FVM-Reborn-macOS-universal-v2.4.1-coop.4.zip)，解压后将 `FVM Reborn.app` 放入应用程序目录。[发行页](https://github.com/9Tempest/FVM-Reborn/releases/tag/v2.4.1-macos-coop.4)提供最终验收结果与 SHA-256。

- 美味级（0）、火山级（1）、浮空级（2）、星际级（3）的通关金币与材料分别为 **1 / 1.25 / 1.5 / 2 倍**。以所选关卡 JSON 原有奖励为基数，逐项乘倍率并向下取整；困难关卡已有的专属奖励保留后再应用本倍率。
- 普通关卡、蛋糕塔的首通与复刷均适用，单人与双人一致。奖励难度在战斗开始时固定，中途更改设置不改变本局奖励；预览与结算显示实际数量。
- 双方获得完整共同奖励，不平分、不按战斗火苗的 60% 分配。解锁、任务领奖、Boss 战中掉落和金币拾取不变；旧格式、实验室关卡保留原规则。
- 保留独立选卡、双方准备、个人火苗与冷却、房主菜单画面同步和启动修复。本版服务协议与服务运行代码未变，已安装 coop.3 服务无需重装。

双方请更新到 coop.4 客户端。需要 macOS 13+，包含 Apple Silicon / Intel 通用二进制；Intel 完整游戏仍待实机验收。队友无需 GameMaker、Python 或开发账号。

更新前正常退出旧版，再替换应用。原应用标识和存档位置保持不变；合作进度与单人槽分开保存，继续合作请选择「重连上次的房间」。本包为 ad-hoc 签名、未经 Apple 公证；若 macOS 提示开发者验证或重新授权访问原有数据，请核对来源及 SHA-256 后按系统提示处理。详见 [安装与合作指南](https://github.com/9Tempest/FVM-Reborn/blob/v2.4.1-macos-coop.4/docs/COOP_MAC.md)。

## 验收状态

- 已通过：通关奖励原生测试 **165/165**，战斗桥接测试 **53/53**，覆盖难度倍率、首通与复刷、幂等及主客奖励数据一致性。
- 待完成：完整公网 WSS 连续两场，以及本次 GitHub 发布包实际下载、安装和旧存档启动验证。发布包 SHA-256 待最终打包后记录。
- coop.3 的完整双客户端及下载验收保留在[历史记录](https://github.com/9Tempest/FVM-Reborn/blob/v2.4.1-macos-coop.4/docs/COOP_MAC.md#coop3-发布包与升级验收)，不代替 coop.4 的验收。两台实际异地 Mac 的人工合作、Intel 完整游戏及逐关验证仍未完成。

房主需保持 Mac 醒着、联网且游戏运行。主机进程退出后不能从未结束战斗的中途恢复；已确认保存的共同进度保留。免费公网隧道地址可能改变。完整限制与恢复方法见合作指南。
