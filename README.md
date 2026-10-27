# Chameleon Ultra GUI for iOS（原生 Swift 重制版）

原生 SwiftUI 重写的 [ChameleonUltraGUI](https://github.com/GameTec-live/ChameleonUltraGUI)（Flutter 原版），面向 Chameleon Ultra / Chameleon Lite NFC·RFID 安全研究设备。界面采用 Apple **Liquid Glass** 设计语言（iOS 26+ 自动获得液态玻璃效果，兼容 iOS 17+），协议命令层按原 Dart 实现逐行移植，与设备固件完全兼容。

> 本项目是原 GPL-3.0 项目的衍生作品，同样以 **GPL-3.0** 授权。仅用于对自有或已获授权的 RFID/NFC 系统进行安全研究。

## ✅ 已实现功能

### 连接与设备
- BLE 扫描/连接（Nordic UART Service），自动识别 Ultra / Lite / DFU 模式（CU- / CL- 前缀）
- 设备仪表盘：固件版本、Git 提交、芯片 ID、蓝牙地址、电量（周期轮询）
- 模拟卡槽快速切换器；连接中断/超时可手动取消
- 自动扫描设备、自动连接首个发现的设备（可开关）

### 卡槽管理
- 8 槽位独立管理：HF/LF 启用开关、标签类型设置（含默认数据）、昵称（点击名称区载入/清除）
- 槽位激活切换；载入已保存卡片（自动写入数据 + 反碰撞信息）
- 导出卡槽数据（长按槽位）：保存为 JSON 文件 / 导出到新卡片 / 更新已保存卡片
- 未配置槽位显示"无卡片"
- **主屏小组件**：8 槽位快捷切换，点按直达应用并激活对应卡槽（iOS 17+ 交互式小组件）
- **设备状态小组件**：电量、电压、当前卡槽与名称；连接/切换卡槽后自动刷新（经 App Group 共享快照；若第三方重签名剥离 App Group 权限，小组件会保持"离线"占位，不影响应用本身）

### 读卡（HF 13.56 MHz / LF 125 kHz）
- ISO14443A 反碰撞信息（UID/SAK/ATQA/ATS）
- MIFARE Classic：容量识别（Mini/1K/2K/4K）、EV1 检测、PRNG 强度、**批量密钥校验**（内置 49 密钥 + proxmark3/Flipper 下载字典 + 自定义字典，支持跳过默认密钥）、全卡转储、密钥网格实时进度、可随时停止
- MIFARE Ultralight / NTAG：型号识别、版本信息、整页转储
- LF：EM410X（含 Electra）、HID Prox（FC/IL/OEM 解析）、Viking、PAC、ioProx
- **连续扫描**（去重列表 + 单卡保存）、**仅保存 UID**

### 已保存卡片
- 与原项目 JSON 格式互通；支持 **.bin 二进制转储导入**（按尺寸推断卡型、从块 0 提取 UID/SAK/ATQA）
- 编辑卡片（名称/UID）、复制、另存为（JSON/二进制）、删除（二次确认）
- 转储编辑器：**按扇区分组、字节级颜色编码**（厂商块/数值块/尾块分段：密钥A·访问位·GPB·密钥B），**五种视图**（HEX / ASCII / ACL / 值 / 对比），改完写回卡片或设备
- **转储对比**：任选另一张同型卡，逐块并排显示两份数据，差异字节红色高亮，统计差异块数/字节数
- 导出：JSON、二进制转储、密钥 .dic（存入字典或分享）
- **导入 .dic 字典文件**（支持 `#` / `:` 注释与 `key:tagType` 写法，自动入库）

### 写卡
- MIFARE 转储写入：Gen1 魔术卡（免鉴权解锁）与 Gen2（密钥写入），128 字节分批传输
- UID 写入（4/7 字节，块 0 重建）、LF 卡 T55xx 克隆

### 固件更新
- 在线检测官方 Releases 新固件（匹配 ultra/lite-dfu-app.zip，稳定版与 dev 频道）
- 刷写前**三重校验**：zip 逐项 CRC32、SHA-256 与 GitHub 资产摘要比对、dfu-cc 签名清单（哈希 SHA-1/256/512 + 尺寸核对）
- 分段 LED 进度条（百分比、呼吸头格）；引导式流程（下载 → 校验 → 重启 DFU → 自动重连 → 刷入）
- 本地 .zip 固件刷写（同样先校验）；固件下载库（离线复刷、单删/清空）
- 手动进入 DFU 模式

### 工具
- 字典下载：与原项目同源的 5 个字典（proxmark3 MFC/T55XX/ULC/MFP + Flipper Unleashed MFC，支持 `#` 与 `:` 两种注释格式）
- T55xx 密码清理重置；LF / HF 嗅探（原始数据捕获与复制）

### 设置与其他
- 外观：主题色（6 色）、深浅模式、**中文/英文切换**（译文大量取自原项目 app_zh.arb）
- **应用图标**：明亮版设计（信号弧背冠 + 卷尾 + RFID 芯片眼）
- 设备设置：LED 动画、休眠超时、长按阈值、按键配置（A/B × 短按/长按）、BLE 配对、恢复出厂（均有二次确认）
- **触感反馈 / 点按声效开关**：所有功能点按均可独立开关震动与"咔哒"提示音（触感默认开、声效默认关），随设置一同导入导出
- 统一的点按视觉反馈：主题色高亮 + 微缩放
- 协议日志实时查看 + **自动归档**（超 1500 行滚动为 .log 文件，可分享/删除）
- 设置导入/导出（专属 .cusettings 格式，含应用与设备设置项）
- 危险操作全部二次确认 + 触觉反馈；按钮按压视觉反馈

## ❌ 无法实现（iOS 平台限制）

| 功能 | 原因 |
|---|---|
| USB / 串口连接 | iOS 不开放非 MFi 配件的 USB 串口访问，仅 BLE（原项目桌面/Android 版可用） |
| 备用图标切换 | 备用图标在 iOS 27 侧载环境渲染空白（actool 不编译备用集 + 系统查找失败），已移除，固定使用明亮版主图标 |
| 刷写时锁定屏幕常亮后台完成 | iOS 后台 BLE 限制，刷写需保持前台（应用内有提示） |
| 读取手机自身 NFC | 与原项目一致，通过 Chameleon 设备读写，不使用 Core NFC |

## 🔜 未来计划

- [ ] 密钥恢复攻击离线计算：Nested / Darkside / mfkey32（设备端采集已具备，补齐端上求解器与 Static Nested / Static Encrypted 路径）
- [ ] MIFARE Classic Gen4 魔术卡配置（原项目同为 WIP）
- [ ] NDEF 编辑器
- [ ] 二维码卡片导入/导出（与原项目互通）
- [ ] HF 嗅探帧解码与 MIFARE 认证交换分析（对齐原版 hf_sniff 工具集）
- [ ] iPad / 横屏多栏布局优化
- [ ] ~~备用图标切换~~（iOS 27 侧载环境下备用图标渲染空白，已移除该功能）
- [ ] 固件新版本发布通知

## 📦 构建与安装

### 本地构建（macOS + Xcode 16+）
1. `open ChameleonUltra.xcodeproj`
2. Signing & Capabilities 选择开发团队，真机 Build & Run（免费证书即可）

### 生成 ipa（GitHub Actions，无需 Mac）
推送到 GitHub 后 `build-ipa.yml` 自动构建：Release + 关闭签名 + ad-hoc 重签，产物为 Artifact `ChameleonUltra-ipa`。

### 安装
- **TrollStore**：直接安装
- **AltStore / SideStore / Sideloadly**：Apple ID 重签后安装（免费账号 7 天有效）
- 正式分发需 Apple 开发者账号

## 📡 BLE 协议

- 应用通道：Nordic UART `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`（写 `…0002`，通知 `…0003`）
- DFU 通道：服务 `FE59`，控制点/数据 `8EC90001/0002-F315-4F60-9FB8-838830DAEA50`
- 帧格式：`11 EF | cmd(2,BE) | status(2,BE) | length(2,BE) | headLRC | data | fullLRC`
- 命令码与原项目 `definitions.dart` 完全一致；固件包校验逻辑对齐 `flash.dart`

## 🗂 目录结构

```
ChameleonUltra-iOS/
├── ChameleonUltra.xcodeproj

├── tools/                           # 图标渲染/生成脚本
└── ChameleonUltra/                  # Swift 源码 + 资源
    ├── ChameleonDefinitions.swift   # 命令码/标签类型（definitions.dart）
    ├── ChameleonFrame.swift         # 帧编解码（SOF + 双 LRC）
    ├── ChameleonCommunicator.swift  # 全部高层命令（chameleon.dart）
    ├── BLEManager.swift             # CoreBluetooth（NUS + DFU）
    ├── MifareClassic.swift          # 密钥表/扇区数学/恢复流程（recovery.dart）
    ├── MifareUltralight.swift       # UL/NTAG 探测读写
    ├── DFUCommunicator.swift        # Nordic Secure DFU（dfu.dart）
    ├── FirmwareService.swift        # Releases 检测/下载
    ├── FirmwareValidator.swift      # dfu-cc 解析 + 三重校验（flash.dart）
    ├── FirmwareStore.swift          # 下载库管理
    ├── ZipArchive.swift             # 内置 ZIP 解压（含 CRC32 校验）
    ├── CardStore.swift              # 卡片/字典持久化（与原版 JSON 互通）
    ├── L10n.swift                   # 中英双语（译文源自原项目 app_zh.arb）
    ├── DumpEditorView.swift         # 转储编辑器
    └── …                            # 各功能页面
```

## 🙏 致谢与许可

- 原项目：[GameTec-live/ChameleonUltraGUI](https://github.com/GameTec-live/ChameleonUltraGUI)（GPL-3.0）
- 设备固件：[RfidResearchGroup/ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra)
- 中文译文大量取自原项目 `lib/l10n/app_zh.arb`
- 本项目 LICENSE 为完整 GPL-3.0 文本
