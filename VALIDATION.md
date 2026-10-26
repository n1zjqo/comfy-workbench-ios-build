# 0.5.0 验证记录

- 构建提交：`5abb5d5b98de4fb60a2655b4c4a6bf0ac7b04139`。
- [GitHub Actions 40296679020](https://github.com/n1zjqo/comfy-workbench-ios-build/actions/runs/40296679020)：成功。
- Xcode 16.4，iOS 18.5 SDK；原生测试在 iOS 18.5 / iPhone 16 Pro 模拟器运行，视图检查使用 375×812 尺寸。
- 76 项核心/网络测试通过，7 项原生测试通过，零失败。硬件文件保护检查单独跳过 1 项：模拟器没有返回保护属性，需在真机核验，不能视为已验证加密。
- 新增检查覆盖局域网优先、公网回退、中心不匹配时不发送凭据、HTML 验证页处理、剪贴板持久化、历史分页、队列上限和重复内容抑制。
- IPA：0.5.0 / build 5，arm64，最低 iOS 15.0。macOS CI 校验 ad-hoc 签名；下载后独立核对 SHA-256、Mach-O、版本、ZIP CRC 和未混入 XCTest。
- IPA SHA-256：`dd8d90f5eaf326ef0da1158c5fe8d8243e27c957021c88e22951e188ed2beb8d`。
- Windows Companion：.NET 10 Release x64，零警告；30 项本地断言通过。已渲染并检查原生界面示例。此项目源文件不包含 Windows 伴侣程序，交付包另附。
- 2026-10-26 经用户明确批准，使用交付版 Windows 程序在 `127.0.0.1:18999` 完成本机 HTTP 联调：5 项检查通过（设备配对、虚构文字收发、重试去重、设备移除、拒绝带 Origin 的网页请求）。测试结束进程退出，端口无残留监听。
- 正式同步中心尚未启动，未读取真实剪贴板，未修改防火墙或替换旧 LanAI。
- 未完成 iPhone XS / iOS 15 / TrollStore 的安装、性能与系统剪贴板实测；未配置公网 HTTPS 域名，未做真实内外网切换和 DDNSTO 验证联调。

实现使用 [Apple 的完整文件保护写入选项](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)。[文件保护属性的值类型](https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey)为 NSString；锁屏后的实际保护行为需要物理设备测试。
