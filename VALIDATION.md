# 验证记录

版本 **0.1.0（build 1）** 已完成 macOS CI 编译、自动化测试与 IPA 生成。以下结果不代表 TrollStore 安装或 iOS 15 实机验收已经通过。

## 已通过的 CI 与产物检查

- 构建出处：[GitHub Actions run 39949930078](https://github.com/n1zjqo/comfy-workbench-ios-build/actions/runs/39949930078)。
- 构建源码提交：`746f64eb767378627e76dfa9598b06031206ee9b`。
- 工具链：Xcode 16.4、iOS 18.5 SDK；部署目标为 iOS 15.0。
- Swift 编译成功，30 项 XCTest 执行完成，零失败。
- 已生成并下载 `ComfyWorkbench.ipa`，版本 0.1.0，build 1。
- 下载后独立核对：SHA-256 与预期一致；主程序为 arm64；Info.plist 的最低系统版本与 Mach-O 最低部署版本均为 iOS 15.0。

IPA SHA-256：

```text
70f4e7fefb9185e97a01b67c3b3d28b774ec26a373976fa9c69d691eb841ca73
```

自动化测试覆盖 JSON / 大整数 / 连接保持、画布转换、HTTP 错误、任务恢复、认证与代理路径、取消范围等逻辑，使用合成数据。iOS 18.5 SDK 是编译所用 SDK；本产物声明的最低运行系统为 iOS 15.0，实际设备行为仍需验证。

## 已通过的本地静态检查

- `python3 scripts/verify-source.py`：Swift 源文件引用、Xcode 工程对象、Info.plist、scheme、iOS 15.0 配置、原创图标及手动 CI 配置。
- `bash -n scripts/build-ipa.sh`：构建脚本的 shell 语法。
- JavaScript 语法检查：`Preview.html` 内嵌脚本；不等同于视觉或交互验收。

公开源码共 39 个文件，已进行内容审计，不包含用户工作流、原始提示词、生成素材、真实服务器地址、私人账号历史或实际凭据。测试中的示例地址和虚构凭据仅用于验证输入处理。上述公开构建链接用于标明本次产物出处。

## 尚需完成

- TrollStore 安装，以及 iPhone XS / iOS 15 实机启动与使用验收。
- 连接真实 ComfyUI / GPU 服务器，验证节点定义、工作流转换和生成结果。
- 原生 UI 截图、键盘与滑动手势、辅助功能、媒体播放及断线恢复。

`Preview.html` 只用于设计演示，不连接服务器、不提交任务，也不是原生运行截图。目前尚未报告真实服务器或设备端的成功结果；CI 和包内最低系统声明不能替代实机兼容性验收。
