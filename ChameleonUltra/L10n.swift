import Foundation

/// Simple two-language localization. Chinese strings are taken from the
/// original project's `lib/l10n/app_zh.arb`; the English "table" is the key
/// itself, so untranslated keys fall back to English gracefully.
enum L10n {

    static var language: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    }

    static var useChinese: Bool {
        switch language {
        case "zh": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static func t(_ key: String) -> String {
        useChinese ? (zhTable[key] ?? key) : key
    }

    static func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }

    // swiftlint:disable:next function_body_length
    private static let zhTable: [String: String] = [
        // common (original: ok/cancel/close/save/delete/…)
        "OK": "确定",
        "Cancel": "取消",
        "Close": "关闭",
        "Save": "保存",
        "Delete": "删除",
        "Retry": "重试",
        "Done": "完成",
        "Yes": "是",
        "No": "否",
        "Unknown": "未知",
        "Search": "搜索",
        "Copy": "复制",
        "name, UID or type": "名称、UID 或类型",

        // tabs & titles (original: home/read_card/saved_cards/write_card/settings/tools/…)
        "Home": "首页",
        "Read": "读卡",
        "Cards": "已保存的卡片",
        "Write": "写卡",
        "Settings": "设置",
        "Tools": "工具",
        "Connect": "连接",
        "Slot manager": "卡槽管理",
        "Read card": "读卡",
        "Write card": "写卡",
        "Saved cards": "已保存的卡片",
        "Firmware update": "固件更新",
        "Device settings": "设备设置",
        "Dictionaries": "字典",
        "New dictionary": "新建字典",
        "Protocol log": "协议日志",
        "Chameleon": "Chameleon",

        // connect page
        "Bluetooth devices": "蓝牙设备",
        "Scan": "扫描",
        "Stop": "停止",
        "Searching for Chameleon devices…": "正在搜索 Chameleon 设备…",
        "No devices yet": "暂无设备",
        "Bluetooth is off or unavailable": "蓝牙已关闭或不可用",
        "Power on your Chameleon and tap Scan. The device advertises as “ChameleonUltra…” (or CU-… in DFU mode).": "请打开 Chameleon 电源后点击扫描。设备广播名为“ChameleonUltra…”（DFU 模式下为 CU-…）。",
        "NFC & RFID research tool": "NFC & RFID 安全研究工具",
        "Connecting to": "正在连接",
        "This can take a few seconds.": "首次连接可能需要一些时间。",
        "Connection cancelled": "已取消连接",

        // home dashboard (original: firmware_version/hf/lf/…)
        "Emulation slot": "模拟卡槽",
        "Firmware": "固件版本",
        "Chip ID": "芯片 ID",
        "BLE address": "蓝牙地址",
        "Emulator": "模拟器",
        "Emulator settings": "模拟器设置",
        "Mifare Classic emulator": "MIFARE Classic 模拟器设置",
        "Key detection (mfkey32)": "密钥收集 (mfkey32)",
        "Gen1a mode": "Gen1A 魔术模式",
        "Gen2 mode": "Gen2 魔术模式",
        "Use anti-collision data from block 0": "从 0 块使用 UID/SAK/ATQA",
        "Write mode": "写入模式",
        "Normal": "正常",
        "Denied": "拒绝",
        "Deceive": "欺骗",
        "Shadow": "影子",
        "Changes are applied to the device immediately.": "更改会立即应用到设备。",
        "Loading…": "加载中…",

        // slots (original: slot_manager/activate/hf/lf/…)
        "HF": "高频",
        "LF": "低频",
        "Tag type": "标签类型",
        "Not set": "未设置",
        "Load saved card…": "载入已保存卡片…",
        "Reset slot": "重置卡槽",
        "Activate": "激活",
        "active": "激活",
        "Save slot names to flash": "将卡槽名称保存到闪存",

        // read card (original: no_card_found/save_only_uid/dump_card/…)
        "Place a HF tag on the Chameleon antenna": "将 HF 标签贴近 Chameleon 天线",
        "Place a LF tag on the Chameleon antenna": "将 LF 标签贴近 Chameleon 天线",
        "Read tag": "读取标签",
        "Reading tag…": "正在读取标签…",
        "No tag found": "未找到卡片。尝试在卡片上移动 Chameleon",
        "No LF tag found": "未找到 LF 卡片",
        "Check keys & dump": "校验密钥并转储",
        "Save card": "保存卡片",
        "Key recovery": "密钥恢复",
        "Dumping…": "正在转储…",
        "Dump": "转储",
        "pages": "页",
        "Info": "信息",
        "Checking keys": "正在校验密钥",
        "Connect a Chameleon device first (Home tab).": "请先在首页连接 Chameleon 设备。",

        // saved cards
        "Card": "卡片",
        "Type": "标签类型",
        "Blocks": "块数",
        "Export as JSON": "导出为 JSON",
        "Export as binary dump": "导出为二进制转储",
        "Apply to device slot…": "写入设备卡槽…",
        "Connect a device to emulate this card": "连接设备后即可模拟此卡片",
        "Danger zone": "危险操作",
        "Delete card": "删除卡片",
        "Name": "名称",
        "Keys (one hex key per line)": "密钥（每行一个十六进制密钥）",
        "Add": "添加",
        "keys": "个密钥",

        // write card
        "Mifare dump": "Mifare 转储",
        "Write UID": "写入 UID",
        "LF clone (T55xx)": "LF 克隆 (T55xx)",
        "Source card": "来源卡片",
        "Card type": "卡片类型",
        "Gen1 (magic, no auth)": "Gen1（魔术卡，免鉴权）",
        "Gen2 (keyed)": "Gen2（密钥写入）",
        "Key A": "密钥 A",
        "Write dump to card": "将转储写入卡片",
        "No saved Mifare Classic cards. Read one first.": "暂无已保存的 Mifare Classic 卡片，请先读卡。",
        "No saved LF cards. Read one first.": "暂无已保存的 LF 卡片，请先读卡。",
        "4 or 7 byte hex UID. Block 0 is rebuilt from UID/SAK/ATQA.": "4 或 7 字节十六进制 UID。块 0 将按 UID/SAK/ATQA 重建。",
        "Write to T55xx tag": "写入 T55xx 标签",
        "Writing…": "正在写入…",
        "Clone LF card to T55xx": "克隆 LF 卡到 T55xx",

        // tools (original: tools/lf_sniffing/hf_sniffing/t55xx_password_cleaner/…)
        "Sniffing": "嗅探",
        "Tag tools": "标签工具",
        "LF sniffing (125 kHz)": "LF 嗅探 (125 kHz)",
        "HF sniffing (13.56 MHz)": "HF 嗅探 (13.56 MHz)",
        "T55xx password cleaner": "T55XX 密码清理器",
        "Start sniff": "开始嗅探",
        "Sniffing…": "正在嗅探…",
        "Captured data": "捕获的数据",
        "Nothing captured.": "未捕获到数据。",
        "Capture LF signal while a reader talks to a tag.": "在读卡器与标签通信时捕获 LF 信号。",
        "Capture HF traffic between reader and tag.": "捕获读卡器与标签之间的 HF 通信。",
        "Old password (hex, 8 chars)": "旧密码（十六进制，8 位）",
        "New password to set (hex, 8 chars)": "要设置的新密码（十六进制，8 位）",
        "Reset tag": "重置标签",
        "Reset command sent": "重置命令已发送",
        "Mifare Classic Gen4 config is not available in this build.": "此版本暂不支持 MIFARE Classic Gen4 配置。",

        // settings (original: settings/language/theme/system/light/dark/…)
        "Appearance": "外观",
        "Theme": "主题",
        "System": "系统",
        "Light": "浅色",
        "Dark": "深色",
        "Accent color": "主题色",
        "Language": "语言",
        "Device": "设备",
        "Firmware update (DFU)": "固件更新 (DFU)",
        "About": "关于",
        "License": "许可证",
        "Original project (Flutter)": "原项目 (Flutter)",
        "LED animation": "LED 动画",
        "Sleep timeout": "休眠超时",
        "never": "从不",
        "min": "分钟",
        "BLE pairing": "蓝牙配对",
        "Reset device settings": "重置设备设置",
        "Applies device defaults. Does not erase slots.": "恢复设备默认设置，不会清除卡槽。",
        "Factory reset (erases everything)": "恢复出厂设置（清除全部数据）",
        "For authorized security research and testing of RFID/NFC systems you own or have permission to test.": "仅用于对您拥有或已获授权的 RFID/NFC 系统进行安全研究与测试。",
        "Full": "完全",
        "Minimal": "简约",
        "None": "无",
        "Symmetric": "对称",

        // firmware page (original: check_updates/up_to_date/enter_dfu/flash_zip_dfu/…)
        "Device firmware": "设备固件",
        "Checking for updates…": "正在检查更新…",
        "Firmware v%@ available": "固件 v%@ 可用",
        "Up to date (latest: v%@)": "已是最新（最新版本：v%@）",
        "Download and flash v%@": "下载并刷写 v%@",
        "Re-flash v%@": "重新刷写 v%@",
        "dev channel": "开发频道",
        "View release page": "查看发布页面",
        "Flash local firmware (.zip)…": "选择本地固件 (.zip)…",
        "Downloading firmware…": "正在下载固件…",
        "Verifying firmware package…": "正在验证固件包…",
        "Rebooting device into DFU mode…": "正在重启设备进入 DFU 模式…",
        "Searching for DFU device (CU-…)…": "正在搜索 DFU 设备 (CU-…)…",
        "Device in DFU mode": "设备处于 DFU 模式",
        "Select firmware package": "选择固件包",
        "Flashing…": "正在刷写…",
        "keep the app in the foreground": "刷写期间请保持应用在前台",
        "DFU log": "DFU 日志",
        "Preparing…": "准备中…",
        "Update cancelled": "已取消更新",
        "Firmware package loaded — choose an action below.": "固件包已就绪——请在下方选择操作。",
        "Reading…": "正在读取…",
        "Slot": "卡槽",
        "Choose slot": "选择卡槽",
        "T55xx cleaner": "T55XX 密码清理器",
        "Write UID (Gen1 magic card)": "写入 UID（Gen1 魔术卡）",

        // dictionary download (original: dictionary_download)
        "Dictionary download": "字典下载",
        "Mifare Classic keys (proxmark3)": "Mifare Classic 密钥 (proxmark3)",
        "T55xx passwords (proxmark3)": "T55xx 密码 (proxmark3)",
        "Mifare Ultralight C keys (proxmark3)": "Mifare Ultralight C 密钥 (proxmark3)",
        "Download": "下载",
        "Downloaded": "已下载",
        "Download failed": "下载失败",
        "keys imported": "个密钥已导入",

        // key export
        "Export found keys": "导出找到的密钥",
        "Export keys from dump": "导出转储中的密钥",
        "Save to dictionaries": "保存到字典",
        "Share as .dic": "导出 .dic 文件",
        "No keys found yet": "尚未找到任何密钥",
        "Keys from dump": "来自转储的密钥",

        // confirmations
        "Confirm deletion": "确认删除",
        "Delete this card?": "删除这张卡片？",
        "Delete this dictionary?": "删除这个字典？",
        "This cannot be undone.": "此操作无法撤销。",
        "Factory reset?": "恢复出厂设置？",
        "Are you sure you want to factory reset your Chameleon?": "您确定要将您的 Chameleon 恢复出厂设置吗？",
        "Reset device settings?": "重置设备设置？",
        "Reset slot?": "重置卡槽？",
        "This clears the slot data on the device.": "这将清除设备上该卡槽的数据。",

        // apply feedback
        "Applying…": "正在应用…",
        "Applied to slot": "已应用到卡槽",
        "Applied to slot %d": "已应用到卡槽 %d",
        "Applied": "已应用",
        "Export": "导出",
        "Imported %d": "已导入 %d",
        "Imported": "已导入",
        "No compatible cards found in file": "文件中没有兼容的卡片",

        // firmware library
        "Downloaded firmware": "已下载的固件",
        "Delete firmware package?": "删除该固件包？",
        "Clear all": "全部清空",
        "Clear all downloaded firmware?": "清空所有已下载的固件？",

        // key check options (original: additional_key_dict)
        "Additional key dictionary": "附加密钥字典",
        "Skip default keys": "跳过默认密钥",

        // firmware validation
        "Firmware package verified": "固件包校验通过",
        "Firmware package invalid": "固件包无效",
        "downloaded package": "已下载的固件包",
        "Signed dfu-cc package": "签名的 dfu-cc 固件包",
        "firmware version": "固件版本",
        "Download SHA-256 matches GitHub asset digest": "下载内容 SHA-256 与 GitHub 资产摘要一致",
        "Zip entries CRC32 verified": "zip 内文件 CRC32 校验通过",
        "files": "个文件",
        "Firmware hash matches application.bin": "固件哈希与 application.bin 一致",
        "Manifest app size matches bin size": "清单应用尺寸与 bin 实际大小一致",
        "Download SHA-256 does NOT match GitHub digest — download corrupted": "下载内容 SHA-256 与 GitHub 摘要不符——下载已损坏",
        "Zip CRC check failed — archive corrupted": "zip CRC 校验失败——压缩包已损坏",
        "application.dat / application.bin missing": "缺少 application.dat / application.bin",
        "Package isn't signed": "固件包未签名",
        "Firmware hash mismatch — wrong or damaged file": "固件哈希不匹配——文件错误或已损坏",
        "Manifest app size does not match bin size": "清单应用尺寸与 bin 实际大小不符",
        "Firmware verification failed — nothing was flashed.": "固件校验失败——未进行任何刷写。",
        "Flash this firmware": "刷写此固件",
        "Force flash (unsafe)": "强制刷写（危险）",
        "Confirm firmware flash": "确认刷写固件",
        "Flashing the wrong firmware can permanently brick your Chameleon. Continue?": "刷写错误的固件可能使您的 Chameleon 永久变砖。确定继续吗？",
        "This package FAILED verification. Force flashing will very likely damage your device. Really continue?": "该固件包未通过校验，强制刷写极有可能损坏您的设备。真的要继续吗？",
        "Flash": "刷写",
        "Download and flash": "下载固件",
        "Re-flash": "重新刷写",
        "Timed out waiting for the DFU device. Power-cycle the Chameleon and try again.": "等待 DFU 设备超时。请重启 Chameleon 后重试。",
        "Done! Firmware updated — the device is rebooting.": "完成！固件已更新——设备正在重启。",
        "Sending init packet…": "正在发送 init packet…",
        "Flashing firmware…": "正在刷写固件…",
    ]
}
