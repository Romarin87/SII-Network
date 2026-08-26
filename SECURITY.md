# 安全说明

## 报告问题

请优先使用 GitHub 的 Private vulnerability reporting。若仓库尚未启用该功能，可提交一个不含账号、密码、IP、MAC 地址、日志原文或认证响应的 Issue，说明需要私下沟通安全细节。

不要在公开 Issue、Pull Request、截图或日志中粘贴校园网凭据、Keychain 内容、完整认证 URL 或活动连接列表。

## 本地凭据

- 通过交互式 `setup` 配置账号，不要把真实账号或密码写进源码、命令脚本、测试数据或 `.env`。
- 密码由 macOS 钥匙串保存；配置文件只包含账号和非秘密门户设置。
- 不要同时运行菜单栏应用和 helper 的 `watch`/LaunchAgent，以免产生并发认证。
- helper 始终验证 HTTPS 证书；若门户证书异常，应修复系统信任链或联系网络管理员。

## 发布检查

公开提交前至少检查：

```bash
git status --short
git add .gitignore Package.swift PRIVACY.md README.md SECURITY.md Resources Sources Tests Tools docs scripts
git diff --cached --name-status
git diff --cached --check
git grep --cached -n -I -E '(BEGIN .*PRIVATE KEY|github_pat_|ghp_|AKIA[0-9A-Z]{16})'
git ls-files --cached | grep -E '(^|/)(\.build|build|DerivedData|__pycache__)(/|$)' && exit 1 || true
```

若任何命令显示真实账号、访问令牌、私钥、构建目录或本机配置，请在提交前移除，并在已经推送过秘密时立即轮换相关凭据。
