# SZU Network Guardian for macOS

深圳大学校园网断线检测与自动重连工具的原生 macOS 菜单栏版本。

支持教学/办公区 SRun、宿舍区 ePortal、macOS Keychain、LaunchAgent 登录启动、
异常退出恢复和单实例守护。项目只发布源码，由每位用户在自己的 Mac 上构建。

## 功能

- 教学/办公区：`https://net.szu.edu.cn`，完整 TLS 证书验证
- 宿舍区：ePortal 自动登录
- 手动选择教学区或宿舍区，默认教学/办公区
- 可选“自动尝试（实验性）”模式
- 两个 HTTPS 直连检测目标，禁用环境代理避免误判
- 正常联网时不读取凭据、不重复认证
- 认证成功后按 2、4、8 秒分阶段复查
- 密码和账号只保存于当前用户的 macOS Keychain
- 菜单栏修改区域、间隔和 Keychain 凭据
- LaunchAgent 登录启动，守护和菜单异常退出后自动恢复
- `fcntl` 文件锁保证后台守护单实例
- 日志权限为 `0600`，保留 7 天，不记录请求 URL、服务器正文或异常详情
- 无监听端口、无遥测、无远程更新

## 系统要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 或 Intel Mac
- Xcode Command Line Tools
- Python 3.10 或更高版本（Homebrew 或 python.org 版本；不使用旧版系统 Python）

安装 Command Line Tools：

```bash
xcode-select --install
```

如尚未安装现代 Python，可使用：

```bash
brew install python
```

## 本地构建

```bash
git clone <你的仓库地址>
cd szu-network-guardian-macos
./scripts/build.sh
```

输出位于：

```text
build/SZU Network Guardian.app
build/keychain
```

构建脚本会创建隔离环境、安装锁定版本依赖、运行自动化测试、按本机架构编译 Swift，
并进行 ad-hoc 签名。自己从源码构建和使用不需要付费 Apple Developer 账号。

## 安装

```bash
./scripts/install.sh
```

首次安装会在终端安全读取账号和密码。密码通过标准输入写入 Keychain，不会进入命令行
参数、plist、JSON 或日志。更新已有安装时会保留 Keychain 凭据；需要重新录入可运行：

```bash
./scripts/install.sh --reconfigure
```

安装位置：

- App：`~/Applications/SZU Network Guardian.app`
- 后台文件：`~/Library/Application Support/SZUNetworkGuardian`
- LaunchAgent：`~/Library/LaunchAgents/com.wenjun.szu-network-guardian*.plist`
- 日志：`~/Library/Application Support/SZUNetworkGuardian/logs`

## 使用

点击菜单栏盾牌图标：

1. 固定在教学楼、实验室或办公室时选择“教学区”。
2. 固定在宿舍时选择“宿舍区”。
3. 只有设备确实会跨区域使用时才选择“自动（实验）”。
4. 推荐检测间隔为 3～5 分钟。

修改账号密码时展开“更新校园网凭据”，保存后输入框会立即清空。
区域或间隔修改后，保存按钮会显示 `保存*`；后台状态刷新不会覆盖尚未保存的选择。

## 卸载

保留 Keychain 凭据、配置和日志：

```bash
./scripts/uninstall.sh
```

彻底删除项目数据和对应 Keychain 条目：

```bash
./scripts/uninstall.sh --purge
```

## 网络与安全边界

程序声明的外部目标只有：

| 用途 | 地址 |
| --- | --- |
| 教学/办公区认证 | `https://net.szu.edu.cn` |
| 宿舍区认证 | `http://172.30.255.42:801/eportal/portal/login/` |
| 联网检测 | `https://captive.apple.com/hotspot-detect.html` |
| 备用联网检测 | `https://www.baidu.com/favicon.ico` |

更多说明见 [SECURITY.md](SECURITY.md) 和 [核心功能对照](docs/CORE_PARITY.md)。

## 测试

```bash
python3 -m venv .venv-build
.venv-build/bin/python -m pip install -r requirements.txt
.venv-build/bin/python -m unittest discover -s Tests -v
xcrun swiftc -parse-as-library -typecheck Sources/MenuBarApp.swift
```

## 上游与许可证

本项目参考并移植了 MIT 许可的
[Georgeupup/szu-network-guardian](https://github.com/Georgeupup/szu-network-guardian)，
SRun 算法还参考了 Sleepstars/SZU-login 和 vidar-team/srun-login。

项目采用 MIT License，第三方归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
