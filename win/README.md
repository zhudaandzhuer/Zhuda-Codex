# Zhuda-Codex Windows

这里放 Windows 版本的 Web 启动器、远程接入脚本、日志转发脚本，以及 portable 构建脚本。

## 当前进度

Windows 已经追上这些能力：

- Web 启动器。
- Gemini、Xiaomi MiMo、DeepSeek 供应商选择。
- 本次会话 API key 注入，不把 key 写入源码目录。
- 真实上游模型选择和 adapter 映射。
- portable 构建脚本。
- 局域网日志转发和远程接入脚本。

Windows 暂时还没完全追上 macOS 的部分：

- macOS 有模型菜单注入脚本，可以把 Codex 前端菜单尽量改成真实模型名。
- Windows 目前主要依赖 adapter 映射；菜单里可能仍显示 Codex 内置 GPT 名称，但实际请求会按启动器注入的映射走。
- Windows portable 包需要从已安装的 Codex AppX 复制 `Codex.exe`，GitHub 源码本身不会包含这个文件。

## 源码启动

```powershell
cd C:\path\to\ZhudaCodex
.\win\Zhuda-Codex-Launcher.cmd
```

源码启动适合开发和测试。它要求本机已经能运行 Codex Desktop，并且本地 adapter 脚本存在。

## 构建 portable 包

```powershell
cd C:\path\to\ZhudaCodex
powershell -NoProfile -ExecutionPolicy Bypass -File .\win\windows_zhuda_make_portable.ps1 -Zip
```

输出位置默认是：

```text
C:\Users\YOU\Documents\ZhudaCodex\portable\Zhuda-Codex\
C:\Users\YOU\Documents\ZhudaCodex\portable\Zhuda-Codex-Portable.zip
```

portable 包入口：

```text
Zhuda-Codex-Launcher.cmd
Start-Zhuda-Codex.cmd
Start-Zhuda-Codex-Local.cmd
Open-Zhuda-Logs.cmd
```

如果只是从 GitHub 拉源码，然后直接把源码目录当 portable 包运行，可能会报错，因为源码目录没有：

```text
app\Codex.exe
profile\
tools\windows_zhuda_local_adapter.ps1
```

这些是构建 portable 时生成或复制出来的运行时文件。

## 远程接入

如果 macOS 接收器已经启动，在 Windows 机器上执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'http://YOUR_MAC_IP:4100/download/windows_zhuda_connect.ps1' -OutFile \"$env:TEMP\zhuda_connect.ps1\"; powershell -NoProfile -ExecutionPolicy Bypass -File \"$env:TEMP\zhuda_connect.ps1\" -Mode local -Model gemma-31b"
```

远程 agent 会把脱敏后的日志和状态发回接收器，方便从一台机器统一排查问题。

## 常见问题

### 为什么 GitHub 下载后会喷错？

因为仓库是源码，不是正式 portable 成品包。源码不包含 Windows Codex 应用本体。请先安装 Codex Desktop，再运行源码 launcher；或者先用 `windows_zhuda_make_portable.ps1` 生成 portable 包。

### Windows 和 macOS 完全一样吗？

还没有。核心 adapter 和 Web 启动器方向一致，但 macOS 已经有独立 App 包和模型菜单注入；Windows 目前更像“源码启动 + portable 构建器”。后续可以补 Windows 菜单注入或更完整的一键打包。

### API key 会保存吗？

不会。Web 启动器输入的 key 只注入本次进程环境。源码和 portable profile 都不应该持久保存真实 API key。

## 开源前不要提交

```text
portable/
downloads/
*.log
*.jsonl
*.zip
.env
```
