# SII Network

一个面向 macOS 13 及以上版本的非官方原生菜单栏网络监测应用，并提供上海创智学院 SRun 有线网断线自动重连功能。

## 功能

- 在菜单栏实时显示总下载和上传速度；
- 提供可缩放、可选始终置顶的详情窗口；
- 支持字节/秒与比特/秒切换；
- 显示外部 IPv4/IPv6 地址；
- 使用 `SMAppService.mainApp` 设置登录 Mac 时自动启动；
- 支持跟随 macOS 外观，也可手动固定浅色或深色主题；
- 同时监测以太网和 Wi-Fi 适配器；
- 可选在有线网络连接时自动关闭 Wi-Fi，并在拔线后安全恢复由本程序关闭的 Wi-Fi；
- 使用 `nettop` 显示每进程网络速率与累计流量，并支持按列排序；进程与连接详情只在对应标签页可见时采样，关闭或最小化详细窗口后自动暂停；
- 使用 `lsof` 显示当前用户可查看的 TCP/UDP socket；
- 仅在检测到活动有线接口时检查 SRun 状态，并在掉线后尝试重新认证。

## 系统要求

- macOS 13 Ventura 或更高版本；
- Xcode 15 或相应 Command Line Tools（提供 Swift 5.9 构建工具）；
- 当前 SRun helper 需要 Python 3。应用内调用路径为 `/usr/bin/python3`，安装 Xcode Command Line Tools 后可用。

## 构建应用

```bash
git clone https://github.com/Romarin87/SII-Network.git
cd SII-Network
./scripts/build-app.sh
```

应用包生成在：

```text
build/NetWatchSII.app
```

构建脚本使用 ad-hoc 签名，适合本机开发和测试。若要分发给其他用户，需要使用 Apple Developer ID 签名并完成 notarization。把应用移动到 `/Applications` 后，再启用“登录 Mac 时自动启动”。

## 配置 SRun 自动重连

双击应用后，点击菜单栏中的实时速度，选择“打开详细窗口”，进入“设置 → 校园网自动重连”，填写校园网账号和密码并点击“保存凭据”。密码会直接写入 macOS 钥匙串，不会进入命令参数、UserDefaults、配置文件或日志。

如需单独测试 helper，也可以在仓库根目录运行：

```bash
python3 Tools/sii_srun_autologin.py setup
python3 Tools/sii_srun_autologin.py once --json
```

`setup` 会交互式读取校园网账号和密码。它与应用内设置使用相同的配置目录和钥匙串项目。

保存凭据后，在应用设置中启用“SRun 有线网自动重连”。应用每次只调用包内 helper 的 `once --json`，并成为认证检查的唯一调度者。不要同时运行 helper 的 `watch` 或旧 LaunchAgent。

helper 的独立使用方法见 [SRun helper 文档](docs/SRunHelper.md)。

## 测试

```bash
swift build
python3 -m unittest discover -s Tests/Python -p 'test_*.py'
```

默认测试不访问校园认证站点。只有明确需要在校内网络做只读协议检查时，才运行：

```bash
SRUN_LIVE_TEST=1 python3 -m unittest discover -s Tests/Python -p 'test_*.py'
```

## 隐私与安全

- 网卡计数、进程速率和连接列表仅在本机内存中处理，不写入日志，也不发送到分析服务。
- 外部 IP 默认不联网查询；手动刷新或明确启用自动查询后才访问 `https://api64.ipify.org?format=json`。ipify 会看到请求的出口 IP，但请求不附带账号、进程或连接数据。
- SRun helper 只在认证站点路由实际经过活动有线接口时访问官方门户 `https://auth.sii.edu.cn`。
- 密码仅保存在 macOS 钥匙串。日志不会记录密码、challenge、认证查询串或完整认证响应。
- SRun 请求始终使用系统信任库验证 HTTPS 证书，不提供关闭 TLS 校验的选项。
- 应用只执行构建时打包进自身 Resources 的 helper，并通过 Python 隔离模式启动。

完整说明见 [PRIVACY.md](PRIVACY.md) 和 [SECURITY.md](SECURITY.md)。发布前可运行：

```bash
git status --short
git add .gitignore Package.swift PRIVACY.md README.md SECURITY.md Resources Sources Tests Tools docs scripts
git diff --cached --name-status
git diff --cached --check
git grep --cached -n -I -E '(BEGIN .*PRIVATE KEY|github_pat_|ghp_|AKIA[0-9A-Z]{16})'
```

## 实现与权限边界

- 网卡总速率通过 `NET_RT_IFLIST2` 读取 64 位接口累计计数，不需要管理员权限。
- `nettop` 和 `lsof` 以当前用户权限运行，因此部分系统进程或其他用户的连接可能不可见。
- 应用未启用 App Sandbox。进程检查、socket 列表和 Python helper 均不适合当前的沙盒架构。
- 当前版本用 Python 实现 SRun 协议。后续可把协议和密码访问迁移到原生 Swift，去掉 Python 运行时依赖。

## 目录结构

```text
Sources/NetWatchSII/       SwiftUI 应用源码
Tools/                     SRun Python helper
Tests/Python/              helper 单元测试
Resources/Info.plist       macOS 应用信息
scripts/build-app.sh       .app 构建脚本
docs/SRunHelper.md         helper 使用说明
```
