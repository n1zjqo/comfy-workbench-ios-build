# 工作流开关兼容范围

0.6.7 / build 16 已构建。以节点功能类型和原始数据结构识别，不绑定节点编号或工作流名称。以下为已实现且通过回归测试的范围；测试与构建结果见 VALIDATION.md。

| 控制类型 | 处理方式 |
| --- | --- |
| rgthree Fast Groups Muter / Bypasser | 从当前图或所有已保存子图读取分组，按位置、名称正则、颜色和排序规则显示；支持 default / max one / always one |
| rgthree Fast Muter / Bypasser | 按实际连接显示目标，经过 Node Collector、Node Combiner、Reroute 收集目标；支持相同互斥规则 |
| rgthree Mute / Bypass Relay / Repeater | 按保存的 ACTIVE / MUTE / BYPASS / NOTHING 映射传播；Repeater 控制连接的节点，无输入时控制所在分组；冲突或循环整体回滚 |
| Impact Switch / Inversed Switch、Latent / SEGS Switch、Image Mask Switch | 编辑 select / sel_mode，保留服务器执行语义；按服务器模板校验动态端口；旧 Latent / SEGS 别名在新版服务器上仅对派生执行图适配 inputN 和明确的默认 sel_mode |
| Easy Use imageSwitch、textSwitch、ab、anythingInversedSwitch、anything/image/text/conditioningIndexSwitch、ifElse、blocker | 根据实际 schema 显示布尔或索引参数，原分支连线完整提交给服务器 |
| KJ LazySwitchKJ | 编辑布尔选择，保留原来的 lazy 分支输入 |
| 其他服务器节点 | 支持命名参数或服务器明确的 input_order；不能确定的位置控件不猜顺序 |
| ComfyUI 原生子图 definitions.subgraphs | 递归处理内部控制、独立作用域、功能分组；子图作为切换目标时传播到内部节点；保留边界连线 |
| 子图提升控件 | 支持带 widget 元数据的接口值和明确的旧版 proxyWidgets 对应；同一子图的各实例保留独立覆盖值 |

在画布点选快捷开关即可编辑；子图内部的控制集中在外层子图节点的参数区，可以手动加入常用参数。模式菜单支持“启用”“旁路”“停用”。更改只影响后续提交，不中断已运行的任务。

原生子图定义可能被多个实例共用。内部节点模式按共享定义保存，界面有“共享定义”提示；实例外层参数仍按各自的覆盖值执行。内部参数若已被实例代理覆盖，编辑入口指向实例外层，避免出现内部值改了但执行仍使用旧覆盖值的误导。

已知边界：

- 原生子图和早期插件的内嵌 LiteGraph 子图不是同一格式。未知内嵌格式、跨子图边界的特殊控制线、无法还原的代理控件会明确报错，不会假装已执行。
- Random Unmuter、Fast Actions Button 等依赖浏览器定时器、随机选择或队列操作的 JavaScript 行为未实现。普通 API JSON 本身也不含前端分组元数据。
- 颜色名称使用上游默认色表；自定义主题改写命名颜色时应在原工作流用明确十六进制颜色。分组边缘折叠节点若无法从保存尺寸确定归属，会要求展开后重新保存。
- 无法保证未来任意插件版本自动兼容。缺失节点、未知控件、冲突控制和不明确的旁路会保留原始数据并说明原因；不删除节点或连接来掩盖问题。

实现依据（2026-10-31 查阅）：[rgthree 前端控制](https://github.com/rgthree/rgthree-comfy/tree/main/src_web/comfyui)、[ComfyUI 子图边界与提升控件](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/docs/architecture/subgraph-boundaries-and-promotion.md)、[Impact 节点](https://github.com/ltdrdata/ComfyUI-Impact-Pack/blob/Main/modules/impact/util_nodes.py)及[注册别名](https://github.com/ltdrdata/ComfyUI-Impact-Pack/blob/Main/__init__.py)、[Easy Use 逻辑节点](https://github.com/yolain/ComfyUI-Easy-Use/blob/main/py/nodes/logic.py)、[KJ 节点](https://github.com/kijai/ComfyUI-KJNodes/blob/main/nodes/nodes.py)。
