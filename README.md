# Chameleon Ultra GUI for iOS (Native Swift 重制版)

原生 SwiftUI 重写的 [ChameleonUltraGUI](https://github.com/GameTec-live/ChameleonUltraGUI)（Flutter 原版），面向 Chameleon Ultra / Chameleon Lite NFC·RFID 安全研究设备。界面遵循 Apple 最新的 **Liquid Glass（iOS 26/27）** 设计语言：标准 `TabView` / `NavigationStack` 在 iOS 26+ 上自动获得液态玻璃外观，卡片采用 `.ultraThinMaterial` 玻璃材质，兼容 iOS 17+。

> 本项目是原 GPL-3.0 项目的衍生作品，同样以 **GPL-3.0** 授权，协议命令层按原 Dart 实现逐行移植。仅用于对自有或获得授权的 RFID/NFC 系统做安全研究。

## 功能（对齐原版）

| 模块 | 说明 |
|---|---|
| 连接 | BLE 扫描/连接（Nordic UART 服务），识别 Ultra/Lite 及 DFU 模式（CU-/CL- 前缀），自动握手（固件版本、电量、芯片 ID、BLE 地址） |
| 首页仪表盘 | 设备信息、电量轮询、8 槽位切换器、模拟器设置（mfkey32 检测 / Gen1a / Gen2 / 反碰撞数据 / 写入模式） |
| 槽位管理 | 8 槽位 HF/LF 独立启用、标签类型设置、默认数据、昵称、激活、载入已存卡、重置、保存到闪存 |
| 读卡 | HF：ISO14443A UID/SAK/ATQA/ATS、Mifare Classic 容量识别（Mini/1K/2K/4K）、EV1 检测、PRNG 强度、内置 49 密钥 + 自定义字典分块校验（密钥网格实时显示）、全卡转储；Ultralight/NTAG 类型识别与整页转储；LF：EM410X（含 Electra）、HID Prox（含 FC/IL/OEM 解析）、Viking、PAC、ioProx |
| 已存卡片 | 与原版 JSON 格式互通的保存/搜索/编辑/删除、十六进制转储查看、JSON/BIN 导出、JSON 导入、一键写入设备槽位 |
| 写卡 | Mifare dump 写入（Gen1 免鉴权 magic 卡：40/43 解锁 + A0 写；Gen2 密钥写入）、UID 写入（4/7 字节 Block0 重建）、LF T55xx 克隆 |
| 工具 | T55xx 密码清理重置、LF/HF 嗅探（原始数据捕获）、密钥字典管理（导入 .dic/.txt、导出） |
| 固件升级 | Nordic Secure DFU 完整流程：**在线检测新固件（GitHub Releases）+ 引导刷写**，或选择本地 zip；刷写前三重校验：zip 逐项 CRC32、（在线包）SHA-256 与 GitHub 资产摘要比对、dfu-cc 签名清单解析 + 固件哈希（SHA-1/256/512）与 application.bin 一致性 + 尺寸核对 |
| 设置 | 主题色、深色模式、设备设置（LED 动画、休眠超时、BLE 配对、恢复出厂）、协议日志查看器 |

### 与原版的差异（平台限制 / 未实现）

- **仅 BLE 连接**：iOS 不允许非 MFi 配件的 USB 串口访问（原版在 iOS 上同样只有 BLE）。
- **密钥恢复攻击（nested/darkside/mfkey32 求解）**：设备端采集命令已实现，但本版不含离线密钥求解计算，密钥校验走字典方式。
- **Gen4 卡配置**：原版也是 WIP，未移植。
- **NDEF 编辑器 / QR 码导入导出**：未移植。
- USB / 桌面平台特性自然不适用。

## 目录结构

```
ChameleonUltra-iOS/
├── ChameleonUltra.xcodeproj        # Xcode 16+ 工程（文件系统同步组）
├── ChameleonUltra/                 # 全部 Swift 源码 + 资源
│   ├── ChameleonDefinitions.swift  # 命令码/标签类型（对应原版 definitions.dart）
│   ├── ChameleonFrame.swift        # 帧编解码（11 EF SOF + LRC）
│   ├── ChameleonCommunicator.swift # 全部高层命令（对应 chameleon.dart）
│   ├── BLEManager.swift            # CoreBluetooth（NUS + DFU 特征）
│   ├── MifareClassic.swift         # 密钥表 + 扇区数学 + 恢复流程（recovery.dart）
│   ├── MifareUltralight.swift      # UL/NTAG 探测与读写
│   ├── DFUCommunicator.swift       # Nordic Secure DFU（dfu.dart）
│   ├── ZipArchive.swift            # 固件包解压
│   ├── CardStore.swift             # 卡片/字典持久化（与原版 JSON 互通）
│   └── *View.swift                 # 各功能页面
└── .github/workflows/build-ipa.yml # 云端打包 ipa
```

## 本地构建（需要 macOS + Xcode 16+）

1. `open ChameleonUltra-iOS/ChameleonUltra.xcodeproj`
2. 选择你的开发团队（Signing & Capabilities → Team），插真机 Build & Run。
3. 免费个人证书即可（仅用到蓝牙权限，无特殊 entitlement）。

## 生成 ipa（三种方式）

### 方式 A：GitHub Actions（推荐，无需 Mac）

把本目录推到任意 GitHub 仓库，Actions 会自动跑 `build-ipa.yml`：
- macOS 26 runner + 最新 Xcode
- Release 构建、关闭代码签名
- ad-hoc 重签名后打包 `ChameleonUltra.ipa` 上传为 artifact
- 也可在 Actions 页手动 **Run workflow** 触发

### 方式 B：本地 Xcode 归档导出

Xcode → Product → Archive → Distribute App → Custom → Ad Hoc（或 Development）。

### 方式 C：本地命令行

```bash
cd ChameleonUltra-iOS
xcodebuild -project ChameleonUltra.xcodeproj -scheme ChameleonUltra \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
codesign -f -s - build/Build/Products/Release-iphoneos/ChameleonUltra.app
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/ChameleonUltra.app Payload/
zip -qry ChameleonUltra.ipa Payload
```

## 安装未签名/ad-hoc ipa

- **TrollStore**：直接安装（已 ad-hoc 签名）。
- **AltStore / SideStore / Sideloadly**：用你的 Apple ID 重签后安装（7 天有效，免费账号）。
- **TestFlight / 正式分发**：需要 Apple 开发者账号，用方式 B 带 Team 签名。

## BLE 协议说明

- 应用通道：Nordic UART Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`（写 `…0002`，通知 `…0003`）
- DFU 通道：服务 `FE59`，控制点 `8EC90001-F315-4F60-9FB8-838830DAEA50`，数据 `8EC90002-…`
- 帧格式：`11 EF | cmd(2,BE) | status(2,BE) | length(2,BE) | headLRC | data | fullLRC`
- 命令码与原版 `definitions.dart` 完全一致

## 致谢与许可

- 原项目：[GameTec-live/ChameleonUltraGUI](https://github.com/GameTec-live/ChameleonUltraGUI)（GPL-3.0）
- 设备固件：[RfidResearchGroup/ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra)
- 本项目 LICENSE 为完整 GPL-3.0 文本。
