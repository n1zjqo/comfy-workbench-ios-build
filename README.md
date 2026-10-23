# Comfy Workbench for iOS

面向 iPhone / iOS 15.0+ 的非官方原生 SwiftUI 客户端，参考 [Mimikkoro1/comfy-workbench-android](https://github.com/Mimikkoro1/comfy-workbench-android) 的直连 ComfyUI 与工作流参数映射思路，提供对话式生成、AI 应用式参数面板及右滑清屏。界面设计参考 [Anthropic frontend-design](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md)。

版本 **0.2.0（build 2）** 已通过 [GitHub Actions 构建](https://github.com/n1zjqo/comfy-workbench-ios-build/actions/runs/39974336324)：42 项 XCTest 零失败，并已生成 arm64 IPA。构建使用 Xcode 16.4 / iOS 18.5 SDK，部署目标为 iOS 15.0；下载后的 IPA 已独立核对 SHA-256、arm64 架构、Info.plist 与 Mach-O 最低系统版本。尚未完成新版在 iPhone XS / iOS 15 上的实机验收及真实 ComfyUI / DDNSTO 联调。详细出处与文件哈希见 `VALIDATION.md`。

## 0.2.0 更新

- 文件导入改用 iOS 系统文档选择器，允许选择文件提供器未正确标为 JSON 的文件，再按实际内容检查。加入云端文件协调读取、后台读取、大小限制、BOM / UTF-16 兼容及明确的进度和错误信息。iPhone XS 上的原问题仍需安装新版后复测。
- “应用”页右上角“+”增加“从服务器读取”，列出 ComfyUI 用户目录下已保存的 JSON，支持子文件夹、搜索、多用户选择。读取后保存为手机副本，不修改服务器文件。普通画布导入仍需要服务器的节点定义。
- “连接”页支持手动输入 DDNSTO HTTPS 地址，并提供“打开网页验证”。常见 DDNSTO 域名返回验证页面时会提示；关闭系统浏览器后只重新检查连接与查询任务，不自动重发生成。
- 增加标准节点画布参数转换；无法确认对应关系的第三方节点会要求导出 API JSON，不猜测参数。

0.2.0 已通过工程结构检查、全部 42 项 XCTest、Xcode Release 编译、ad-hoc 签名校验与下载后包体检查。自动化验证不能代替 iPhone XS 上的文件选择、服务器读取和 DDNSTO 实际验证。

## 功能

- 导入、保存与导出 ComfyUI API JSON，保留输入类型、完整 UInt64 种子及节点连接。
- AI 应用式参数面板，可固定常用参数并查看编辑字面值输入。通过 `/object_info` 获取模型、枚举和数值范围。
- 节点关系页使用默认节点类型名，显示上游连接，并支持进入参数编辑。
- 对话内容发送到明确选定的提示词入口，记录任务状态、文字、图片与视频结果。
- 右滑清屏、左滑恢复；保留底图与毛玻璃边框，并提供恢复按钮。
- 相册底图、作品底图、系统分享以及按输入字段上传素材。
- HTTP、WebSocket、Basic Auth、Keychain、代理子路径及任务恢复。
- 取消属于当前任务的待执行队列项；不能确认定向中断能力时不调用全局中断。
- 前台恢复后查询队列和历史。iOS 后台挂起期间不保证持续下载。
- 按需随机种子；可将具名参数中的 `control_after_generate=randomize` 转成每次生成随机种子配置。

画布 JSON 转换需要从用户自己的服务器读取节点定义。转换器支持具名 widget、Set/Get、Reroute、类型明确的旁路、V3 动态参数及 VHS 编码选项。遇到缺失节点、未知参数、断开输入或不确定旁路会停止并解释原因；也可在 ComfyUI 中导出 API 格式后导入。位置参数只支持明确列出的标准节点布局，并核对参数数量和服务器定义；不保证支持任意第三方扩展或子图。

## 使用

1. 构建并安装应用后，进入“连接”，填写手机可以访问的 ComfyUI 地址。地址默认留空；`http://192.168.1.20:8188` 仅为格式示例，需替换为自己的地址。
2. 如服务器需要 Basic Auth，填写用户名与密码。选择“测试连接并保存”，并允许本地网络访问。
3. 在“应用”点“+”，选择“从文件导入”或“从服务器读取”。导入后编辑参数，通过“配置面板”固定常用字段并指定聊天提示词入口。
4. 在“应用”运行当前参数，或在“对话”发送新提示词。
5. 打开、分享生成结果，或将图片设为底图。右滑清屏，左滑或点“恢复”返回。

本仓库不提供用户工作流、模型、提示词、生成素材或服务器凭据。`Preview.html` 是无需联网的交互设计预览，使用虚构示例及 CSS 图形，不是原生 App 截图，不会提交生成任务。

## DDNSTO 与服务器工作流

DDNSTO 地址由用户手动填写，代码不预设外网域名。“打开网页验证”打开当前配置的 HTTPS 地址；App 不读取浏览器密码或 Cookie。按 [DDNSTO 官方说明](https://doc.linkease.com/zh/guide/ddnsto/scenarios/authentication.html)，验证可能因到期或公网 IP 改变失效；浏览器与 App 需要相同网络出口。本版没有真实 DDNSTO 域名可测试，不能保证所有代理配置均兼容。

服务器工作流列表使用 ComfyUI 的 `/users`、`/userdata` 只读接口，只显示 ComfyUI 工作流管理中已保存的文件。浏览器临时画布、任意磁盘目录或未启用此接口的旧服务器不会自动显示。多用户环境需选择已有用户；不会创建账号或修改服务器配置。

## 构建

工程无需第三方 Swift 依赖。GitHub Actions 仅手动触发，不自动发布 Release。

1. 将工程内容放在自己的 GitHub 仓库根目录，保留 `.github/workflows/ios-build.yml`。
2. 在 Actions 中选择 **Build iOS 15 IPA** → **Run workflow**。
3. 工作流将执行结构检查、`swift test` 和 arm64 iPhone 构建，进行 ad-hoc 签名并核对包结构与最低系统版本。
4. 只有构建成功后，才会出现包含 `ComfyWorkbench.ipa` 的 `ComfyWorkbench-iOS15` artifact。

构建脚本配置为 macOS 15 / Xcode 16.4。IPA 面向已有兼容 [TrollStore](https://github.com/opa334/TrollStore) 环境，不用于 App Store 分发，不添加私有权限、JIT 或越狱功能。请自行确认设备与安装环境兼容性。

在具备相应 Xcode 环境的 Mac 上：

```bash
swift test
bash scripts/build-ipa.sh
```

结构检查：

```bash
python3 scripts/verify-source.py
```

结构检查仅验证文件、JSON、plist、源文件引用与构建配置。0.2.0 CI 的 42 项 XCTest 已通过。测试覆盖 JSON/大整数/连接保持、画布转换、HTTP 错误、任务恢复、认证/路径和取消范围。自动化测试使用合成数据，不代替真实服务器和设备验收。

## 验证范围与限制

仍需完成 TrollStore 安装、iPhone XS / iOS 15 实机启动和使用验收，以及真实 ComfyUI / GPU 服务器联调，包括键盘与滑动、自定义节点转换、媒体播放和网络恢复。系统不支持的媒体格式可通过分享交给其他应用。原 Android 客户端的词库抽卡服务、自动局域网扫描、内置模板和全部主题尚未移植。

源码采用 GPL-3.0，完整许可见 `LICENSE`。Android 参考版本：`9c76c644895e50a9f3bc02e6c9fc2d13dffe4249`。本项目独立开发且非官方；原创图标不包含 ComfyUI 商标图案。
