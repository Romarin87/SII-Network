# 上海创智学院有线网自动重连

已确认该门户使用标准 SRun/深澜认证流程：先查询 `/cgi-bin/rad_user_info`，离线后从 `/cgi-bin/get_challenge` 取得 challenge，再向 `/cgi-bin/srun_portal` 发起加密登录。因此可以在断线后自动重新认证。

脚本只使用 Python 3 标准库。菜单栏应用当前通过 `/usr/bin/python3` 调用它，因此需要安装 Xcode Command Line Tools。账号写入本地配置，密码由 macOS 钥匙串工具直接交互读取并保存，不会出现在命令参数、脚本、配置文件或日志中。

在每次访问认证接口前，脚本会同时检查：

1. 认证服务器的当前路由接口是否被 macOS 识别为 Ethernet、USB LAN 或 Thunderbolt Ethernet；
2. 该接口的物理链路是否为 `active`；
3. 该接口是否已经取得有效 IPv4 地址。

三项都满足才会检查认证状态或执行登录。拔掉网线、只连接 Wi-Fi，或网卡尚未取得地址时，后台服务只等待，不访问认证服务器。

## 1. 首次配置

在仓库根目录运行：

```bash
python3 Tools/sii_srun_autologin.py setup
```

按提示输入校园网账号和密码。密码输入时终端不会显示字符。

## 2. 先做一次手动测试

查看认证状态：

```bash
python3 Tools/sii_srun_autologin.py status
```

离线时尝试一次重连：

```bash
python3 Tools/sii_srun_autologin.py once
```

作为其他应用的 helper 调用时，可获得稳定 JSON：

```bash
python3 Tools/sii_srun_autologin.py once --json
```

持续监测（前台运行，按 `Control-C` 停止）：

```bash
python3 Tools/sii_srun_autologin.py watch --interval 15
```

## 3. 安装为 macOS 登录自启服务

确认 `once` 可正常重连后运行：

```bash
python3 Tools/sii_srun_autologin.py install-agent --interval 15
```

服务会在用户登录 macOS 后启动。日志位置：

```text
~/Library/Logs/SII-SRun/autologin.log
~/Library/Logs/SII-SRun/autologin.error.log
```

检查服务状态：

```bash
launchctl print "gui/$(id -u)/cn.edu.sii.srun-autologin"
```

## 行为与限制

- 在线时只做状态查询，不会重复登录。
- 只有有线网卡已连接、链路激活且认证站点路由走该网卡时，才会访问认证接口。
- 如果当前在线的是另一个账号，脚本保持现状，不会把它顶掉。
- 物理网线断开或认证服务器不可达时，脚本按指数退避重试，最长等待 5 分钟。
- 门户要求图形验证码时，脚本会暂停频繁重试并提示先在网页手动登录一次；它不会尝试绕过验证码。
- 检查间隔下限为 10 秒，建议保持默认 15 秒，避免给校园认证服务器造成过多请求。

所有认证请求都会使用系统信任库验证 HTTPS 证书。若证书校验失败，请检查系统时间、系统信任库或联系校园网络管理员。
