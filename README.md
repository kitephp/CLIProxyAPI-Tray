# CLIProxyAPI Tray

> 一个给 Windows 用的托盘管理工具，用来启动和管理 `CLIProxyAPI`。
>
> 这是社区项目，不是 CLIProxyAPI 官方核心仓库。

## 这项目能做什么

- 托盘脚本版本：`2.0.0`
- 托盘常驻，单实例运行
- 启动、停止、重启 CLIProxyAPI
- 自动检测并下载最新可用版本
- 版本隔离
- 一键打开管理页面（WebUI）
- 托盘个性化设置

## 环境要求

- Windows 10 / Windows 11
- Windows PowerShell 5.1 或 PowerShell 7
- 能访问 GitHub Releases

## 快速开始

### 方式 A：克隆仓库使用

克隆后在仓库目录双击：

```text
create-shortcut.bat
```

安装目录就是当前仓库目录。脚本会创建或更新桌面快捷方式。

### 方式 B：一行命令安装

```powershell
irm https://raw.githubusercontent.com/kitephp/CLIProxyAPI-Tray/main/install.ps1 | iex
```

安装目录为：

```text
%USERPROFILE%\cli-proxy-api-tray
```

安装器不会覆盖已有的 `config.yaml`、`settings.json`、`versions/`、`logs/`。

## 使用说明

### 托盘菜单

- `Running (vX.Y.Z)` / `Not Running`：当前服务状态，只读显示
- `Start`：启动 CLIProxyAPI
- `Restart`：重启当前服务
- `Stop`：停止 CLIProxyAPI 进程
- `Open`：`WebUI`、`Folder`、`Config`
- `Settings`：`Auto Open WebUI`、`Auto Update`、`Reset Password`
- `Update`：检查并安装最新版本
- `About`：打开项目 GitHub 页面
- `Exit`：退出托盘并停止进程

### 托盘双击行为

- 当前有服务在运行：直接打开 WebUI
- 当前没有服务在运行：启动服务

## Auto Open WebUI 开关说明（重要）

当前实现里，这个开关只影响“自动打开”行为：

- 会影响：
  - 通过 `Start` 启动后是否自动开页
  - `Restart` 后是否自动开页
  - `Update` 安装完成后重启时是否自动开页
  - 脚本启动时（检测到已运行）是否自动开页
- 不会影响：
  - 手动点击 `Open` -> `WebUI`
  - 托盘双击且当前已运行时的开页动作

## Auto Update 开关说明

- 默认关闭
- 开启后，每次托盘启动时会检查最新 CLIProxyAPI 版本
- 发现新版本时会自动下载并安装，不再弹出确认框
- 更新失败时会恢复到之前记录的版本信息
- 不会后台定时检查；手动点击 `Update` 仍然可以随时检查更新

## 目录结构

```text
CLIProxyAPI_Tray/
├─ cli-proxy-api.ps1
├─ cli-proxy-api.vbs
├─ install.ps1
├─ create-shortcut.bat
├─ cli-proxy-api.ico
├─ config.example.yaml
├─ README.md
└─ LICENSE
```

## 状态文件与数据路径

- 主状态文件：`<脚本目录>\settings.json`
- 回退状态文件：`%LOCALAPPDATA%\CLIProxyAPI_Tray\settings.json`
  - 当脚本目录不可写时会自动回退
- 版本目录：`<脚本目录>\versions\<version>\`

`settings.json` 主要字段：

- `version`
- `arch`
- `autoOpenWebUI`
- `autoUpdate`
- `updatedAt`

旧版本遗留的其他字段会在下一次保存状态时自动移除。


## 更新与版本管理机制

- 点击 `Update` 才会检查更新，不会后台定时更新
- 开启 `Settings` -> `Auto Update` 后，托盘启动时会自动检查并安装更新
- 更新只处理 CLIProxyAPI 发布包
- 已下载版本会保留，不会自动清理旧版本目录
- 下载失败时只清理临时目录，不会删已有版本

## 常见问题（FAQ）

### 1. 托盘没出现

- 先确认没有重复实例在运行
- 用 PowerShell 手动执行一次脚本，看是否有安全策略或权限提示

### 2. WebUI 打不开

- 确认服务已启动（托盘状态不是 `Not Running`）
- 确认 `config.yaml` 里的 `port`，再访问 `http://127.0.0.1:<port>/management.html`

### 3. 首次启动一直让输密码

- 检查 `config.yaml` 是否可写
- 确认 `remote-management.secret-key` 已成功写入

### 4. 更新下载失败

- 检查网络是否可访问 GitHub Releases
- 若在公司网络环境，检查代理或防火墙策略

### 5. settings.json 保存失败

- 把项目放到当前用户有写权限的目录
- 脚本也会尝试自动回退到 `%LOCALAPPDATA%\CLIProxyAPI_Tray\settings.json`

## 重置与卸载

1. 托盘菜单点 `Exit`
2. 删除桌面快捷方式
3. 按需删除以下文件/目录：
   - `config.yaml`
   - `settings.json`
   - `versions/`
   - `logs/`

一行命令安装的默认目录是 `%USERPROFILE%\cli-proxy-api-tray`，卸载时可以一并删除该目录。

## 许可证

本项目采用 [MIT License](./LICENSE)。

## 反馈

有问题或建议，欢迎提 Issue：

- https://github.com/kitephp/CLIProxyAPI-Tray/issues
