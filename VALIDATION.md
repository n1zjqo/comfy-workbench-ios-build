# 验证记录

## 当前版本：0.3.0（build 3）

- 构建出处：[GitHub Actions](https://github.com/n1zjqo/comfy-workbench-ios-build/actions/runs/39984099647)。
- 构建源码提交：`2e74abb1174b03c8b4530db7469e7144a5fa76bf`。
- Xcode 16.4 / iOS 18.5 SDK，Release arm64 iPhone 构建成功，最低系统版本 iOS 15.0。
- 55 项 XCTest 零失败；14 个 Swift 源文件的工程结构检查通过。
- 新增 13 项测试覆盖坐标与尺寸、默认名称、两种连线表示、循环图自动布局、UInt64、参数双份同步、保存与导出重导入、歧义拒绝、连接保护、类型与范围校验。
- CI ad-hoc 签名验证通过；下载后 ZIP CRC、SHA-256、版本号、bundle ID、arm64 与 Mach-O 最低系统版本再次核对通过。
- bundle ID 保持 `com.comfyworkbench.ios`，build 3 可用于更新已有同标识的安装。
- 公开源文件共 42 个，不含用户工作流、提示词、服务器地址或凭据；测试数据均为合成。
- 本地独立 HTML 设计预览已检查 375×812 画面、参数保存、搜索定位和总览。该预览不是原生截图，不能代替 iPhone 手势和渲染验收。
- 仍需在 iPhone XS / iOS 15 实测 TrollStore 安装、画布缩放性能、键盘和实际工作流运行；未声称已进行 GPU 生成或 DDNSTO 联调。

IPA SHA-256：

```text
5e43132fa3d97d7e7747d21d1eff36f5db8712aa450b5d62e4af76d09cfe29ac
```

## 历史版本：0.2.0（build 2）

- 修复文件类型筛选导致的导入限制并加入内容校验；新增 DDNSTO 手动网页验证入口与服务器工作流列表。
- 构建出处：[GitHub Actions run 39974336324](https://github.com/n1zjqo/comfy-workbench-ios-build/actions/runs/39974336324)。
- 构建源码提交：`5354d9de8f08101afe58b4138f81f0beb559756c`。
- Xcode 16.4 / iOS 18.5 SDK，Release arm64 iPhone 构建成功；最低系统版本为 iOS 15.0。
- 42 项 XCTest 执行完成，零失败；本地结构检查通过。
- CI 的 ad-hoc 签名验证和 IPA 包体校验通过。下载后再次核对 ZIP CRC、SHA-256、版本号、bundle ID、arm64 架构、Info.plist 与 Mach-O 最低系统版本，均符合预期。
- bundle ID 维持 `com.comfyworkbench.ios`，与已交付的公开构建 0.1.0 一致。
- 新增测试覆盖 DDNSTO 响应识别、路径编码和越界拒绝、用户与工作流列表、文件编码和内容检查、标准节点位置参数转换。
- 尚未在 iPhone XS / iOS 15 上复测文件选择器、服务器工作流读取或实际 DDNSTO 域名。自动化通过不代表这些实机操作已经验收。

0.2.0 IPA SHA-256：

```text
50b59e29a952af4227a56977a7eaa56df44b2017226db716b24e29dd1640acfd
```

## 历史版本：0.1.0（build 1）

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
