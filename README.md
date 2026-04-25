# CLIProxyAPI Tray

> 一个给 Windows 用的托盘管理工具，用来启动和管理 `CLIProxyAPI`。
>
> 这是社区项目，不是 CLIProxyAPI 官方核心仓库。

## 这项目能做什么

- 托盘常驻，单实例运行
- 自动检测并下载最新可用版本
- 版本隔离存放在 `versions/<version>/`
- 一键打开管理页面（WebUI）
- 自动检查并写入 `remote-management.secret-key`
- 支持开关控制“启动/重启后是否自动打开管理页面”

## 环境要求

- Windows 10 / Windows 11
- PowerShell 5.1 或更高版本
- 能访问 GitHub Releases

## 快速开始（推荐）

### 方式 A：普通用户（桌面快捷方式）

1. 下载并放到同一目录：
   - `cli-proxy-api.ps1`
   - `cli-proxy-api.vbs`
   - `create-shortcut.bat`
   - `config.example.yaml`
2. 双击运行 `create-shortcut.bat`
3. 桌面会生成 `CLIProxyAPI Tray` 快捷方式
4. 以后直接双击桌面快捷方式启动

### 方式 B：开发者（直接运行脚本）

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File .\cli-proxy-api.ps1
```

## 首次运行会发生什么

首次启动时，脚本会按顺序做这些事：

1. 检查是否已有实例在运行（避免多开）
2. 若 `config.yaml` 不存在，则从 `config.example.yaml` 自动复制
3. 检查 `remote-management.secret-key`
   - 为空时会弹窗让你输入密码，并写回 `config.yaml`
4. 检查当前版本是否已安装
   - 未安装时会询问是否下载最新版本
5. 启动服务并更新托盘状态

## 日常使用说明

### 托盘菜单

- `Start`：启动 CLIProxyAPI
- `Open -> WebUI`：打开 `http://127.0.0.1:<port>/management.html`
- `Open -> Folder`：打开脚本目录
- `Reset Password`：重置 `secret-key`
- `Auto Open WebUI`：切换“启动/重启后自动开页”
- `Update`：检查并安装最新版本
- `Restart`：重启 CLIProxyAPI
- `Stop`：停止 CLIProxyAPI 进程
- `Exit`：退出托盘并停止进程

### 托盘双击行为

- 当前有服务在运行：直接打开 WebUI
- 当前没有服务在运行：启动 CLIProxyAPI

## Auto Open WebUI 开关说明（重要）

当前实现里，这个开关只影响“自动打开”行为：

- 会影响：
  - 启动后是否自动开页
  - `Restart` 后是否自动开页
  - `Update` 安装完成后重启时是否自动开页
  - 脚本启动时（检测到已运行）是否自动开页
- 不会影响：
  - 手动点击 `Open -> WebUI`
  - 托盘双击且当前已运行时的开页动作

## 目录结构

```text
CLIProxyAPI_Tray/
├─ cli-proxy-api.ps1
├─ cli-proxy-api.vbs
├─ create-shortcut.bat
├─ config.example.yaml
├─ README.md
└─ LICENSE
```

运行后通常会出现：

```text
CLIProxyAPI_Tray/
├─ config.yaml
├─ state.json
├─ versions/
│  └─ vX.Y.Z/
│     └─ cli-proxy-api.exe
└─ logs/                     # 仅在 config 开启 logging-to-file 时写入
```

## 状态文件与数据路径

- 主状态文件：`<脚本目录>\state.json`
- 回退状态文件：`%LOCALAPPDATA%\CLIProxyAPI_Tray\state.json`
  - 当脚本目录不可写时会自动回退
- 版本目录：`<脚本目录>\versions\<mainTag>\`

`state.json` 主要字段：

- `version`
- `arch`
- `autoOpenWebUI`
- `updatedAt`

## 最小配置建议

建议至少确认这几个配置项：

```yaml
port: 8317
show-update-progress: true
remote-management:
  allow-remote: false
  secret-key: "请设置一个强密码"
```

说明：

- `port`：WebUI 与服务监听端口
- `show-update-progress`：是否显示下载进度窗口
- `remote-management.secret-key`：管理接口密钥，不能为空

## 更新与版本管理机制

- 点击 `Update` 才会检查更新，不会后台定时更新
- 已下载版本会保留，不会自动清理旧版本目录
- 下载失败时只清理临时目录，不会删已有版本

## 常见问题（FAQ）

### 1. 托盘没出现

- 先确认没有重复实例在运行
- 用 PowerShell 手动执行一次脚本，看是否有安全策略或权限提示

### 2. WebUI 打不开

- 确认服务已启动（托盘状态不是 `Not Running`）
- 确认 `config.yaml` 里的 `port`，再访问 `http://127.0.0.1:<port>/management.html`

### 3. 更新提示 "GitHub API rate limit exceeded"

- 未认证的 GitHub API 每小时只能请求 60 次
- 解决方案：
  1. 在 [GitHub Settings](https://github.com/settings/tokens) 创建一个 Personal Access Token（不需要任何权限）
  2. 设置环境变量 `GITHUB_TOKEN`：
     - 临时生效：PowerShell 中运行 `$env:GITHUB_TOKEN = "ghp_xxxxxxxxxxxx"`
     - 永久生效：在系统环境变量中添加 `GITHUB_TOKEN=ghp_xxxxxxxxxxxx`

### 4. 首次启动一直让输密码

- 检查 `config.yaml` 是否可写
- 确认 `remote-management.secret-key` 已成功写入

### 4. 更新下载失败

- 检查网络是否可访问 GitHub Releases
- 若在公司网络环境，检查代理或防火墙策略

### 5. state.json 保存失败

- 把项目放到当前用户有写权限的目录
- 脚本也会尝试自动回退到 `%LOCALAPPDATA%\CLIProxyAPI_Tray\state.json`

## 重置与卸载

1. 托盘菜单点 `Exit`
2. 删除桌面快捷方式（如果你是用 bat 创建的）
3. 按需删除以下文件/目录：
   - `config.yaml`
   - `state.json`
   - `versions/`
   - `logs/`

## 许可证

本项目采用 [MIT License](./LICENSE)。

## 反馈

有问题或建议，欢迎提 Issue：

- https://github.com/kitephp/CLIProxyAPI_Tray/issues
