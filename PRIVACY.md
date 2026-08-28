# 隐私说明

NetWatch SII 不包含统计 SDK、广告 SDK 或远程日志服务。项目不会把校园网账号、密码、进程列表或连接列表写入仓库。

## 本机处理的数据

- 网卡名称、接口计数和传输速率只在应用内存中处理。
- 进程名称、PID 和网络速率来自 macOS 的 `nettop`，只在本机界面显示。
- TCP/UDP 端点来自 macOS 的 `lsof`，只在本机界面显示。
- 显示偏好保存在 macOS `UserDefaults`，不包含校园网密码。

应用当前没有把上述监测数据持久化，也不会把它们发送给项目维护者或第三方分析服务。

## 外部 IP 查询

应用默认不发起外部 IP 请求。用户手动刷新，或明确启用“自动查询外部 IP”后，应用会立即请求；启用期间每 10 分钟刷新一次：

```text
https://api64.ipify.org?format=json
```

该请求仅用于取得出口 IP。和任何网络请求一样，ipify 会看到请求的源 IP。应用不会随请求附带账号、进程列表或连接列表。

## SRun 校园网认证

首次在应用设置中保存凭据，或运行 `Tools/sii_srun_autologin.py setup` 时：

- 校园网账号及非秘密协议设置写入 `~/Library/Application Support/SII-SRun/config.json`，文件权限设置为仅当前用户可读写；
- 应用使用 Security.framework，helper 使用 macOS 钥匙串工具，将密码保存到 service `cn.edu.sii.srun-autologin`；密码不会出现在命令参数中；
- 密码不会写入仓库、配置文件或日志。

只有认证站点的路由实际经过已连接并取得 IPv4 地址的有线接口时，helper 才会访问 `https://auth.sii.edu.cn`。认证时会把账号、客户端 IP 和协议要求的认证派生数据通过 HTTPS 发给该门户；这些是完成登录所必需的数据。helper 始终使用系统信任库验证门户证书，拒绝跨站重定向，也不允许改成其他认证主机。

独立运行 `watch` 或安装 LaunchAgent 后，状态日志位于 `~/Library/Logs/SII-SRun/`。日志不记录密码、challenge、认证查询串或完整服务器响应。

## 发布仓库边界

`.gitignore` 排除了本地配置、日志、抓包、构建缓存、应用包和压缩包。提交前仍应运行 README 中的隐私扫描命令，并仅提交 `git status` 明确列出的源码和文档。
