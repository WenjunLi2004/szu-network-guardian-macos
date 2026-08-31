# 与 Windows 原版的核心功能对照

对照基线：`Georgeupup/szu-network-guardian`，提交
`d2cbd908625ad501fae8a2f0056329b65cf2b235`。

| 功能 | Windows 原版 | macOS 版 | 结论 |
| --- | --- | --- | --- |
| 教学/办公区 SRun | 支持 | 支持，且强制 TLS 验证 | macOS 更严格 |
| 宿舍 ePortal | 支持 | 支持 JSON/JSONP，禁止重定向 | 一致并加固 |
| 手动区域选择 | 支持，默认教学区 | 支持，默认教学区 | 一致 |
| 自动模式 | 教学区后宿舍区 | 同顺序，并先无凭据探测宿舍入口 | 一致并降低误发风险 |
| 正常联网不认证 | 支持 | 支持，且不会读取 Keychain | 一致 |
| 直连检测 | Baidu HTTPS + Microsoft HTTP | Apple HTTPS + Baidu HTTPS | 一致并去除 HTTP 检测 |
| 认证后复查 | 2/4/8 秒 | 2/4/8 秒 | 一致 |
| 凭据保存 | Windows DPAPI | macOS Keychain | 平台等价 |
| 首次凭据录入 | 主窗口 | 安装脚本或菜单栏折叠编辑器 | 平台等价 |
| 后台运行 | Windows 托盘线程 | SwiftUI MenuBarExtra + 独立守护 | 平台等价 |
| 登录启动 | 注册表 Run | 用户 LaunchAgent | 平台等价 |
| 异常恢复 | 依赖应用进程 | LaunchAgent KeepAlive | macOS 更强 |
| 单实例 | 应用进程内监控线程 | `fcntl` 守护锁 + LaunchAgent | macOS 更强 |
| 日志 | 7 天、UI 3 小时 | 7 天、菜单显示最近事件 | 核心一致 |
| 构建 | PyInstaller EXE | Swift + Python 本地构建 | 平台实现不同 |
| 遥测/更新 | 无 | 无 | 一致 |

## 已修正的原版风险

- 原版 SRun 使用 `verify=False`；macOS 版始终验证证书。
- 原版宿舍认证允许重定向；macOS 版禁止重定向。
- 原版监控层可能把异常文本写入日志，而 `requests` 异常可能包含完整 URL；macOS 版只写固定事件。
- 原版备用联网检测使用 HTTP；macOS 版的两个检测目标均为 HTTPS。
- 自动模式明确标为实验性，固定设备推荐手动选择实际区域。
