
# CLIProxyAPI Tray

A lightweight Windows tray manager for **CLIProxyAPI** and **CLIProxyAPI Plus**.

> This is an **unofficial community tool**, not the core CLIProxyAPI project.

---

## 简介 / Introduction

**CLIProxyAPI Tray** 是一个基于 Windows 系统的轻量级托盘管理工具，用于管理  
**CLIProxyAPI（Main）** 和 **CLIProxyAPI Plus（Plus）** 两个版本。

无需安装第三方依赖，仅使用系统自带的 PowerShell，即可实现：
- 托盘运行
- 通道切换（Main / Plus）
- 自动下载与更新
- 版本隔离管理
- WebUI 快速访问
- 配置文件与密码管理

**CLIProxyAPI Tray** is a lightweight Windows tray manager for  
**CLIProxyAPI (Main)** and **CLIProxyAPI Plus (Plus)**.

It requires **no third-party dependencies** and runs purely on built-in PowerShell, providing:
- Tray icon management
- Main / Plus channel switching
- Automatic download & update
- Version-isolated binaries
- Quick WebUI access
- Configuration & password management

---

## 功能特性 / Features

- 🧷 Windows 托盘图标（单实例运行）
- 🔁 Main / Plus 通道切换（互斥运行）
- ⬇️ 从 GitHub Releases 自动下载与更新
- 🗂️ 二进制版本隔离管理（`versions/<version>/`）
- 🔐 自动检测并设置 `secret-key`
- 🌐 WebUI 快捷打开
- 🔘 启动时自动打开 WebUI 开关（Auto Open WebUI）
- 🧾 共享同一份 `config.yaml`
- 🪶 零第三方依赖，仅需 Windows + PowerShell

---

## 系统要求 / Requirements

- Windows 10 / Windows 11
- PowerShell 5.1 或更高版本
- 网络访问 GitHub Releases

---

## 目录结构 / Folder Structure

```text
CLIProxyAPI_Tray/
├─ cli-proxy-api.ps1
├─ config.example.yaml
├─ README.md
├─ LICENSE
└─ .gitignore
````

运行后会自动生成：

```text
CLIProxyAPI_Tray/
├─ config.yaml
├─ state.json
└─ versions/
   └─ v6.7.37/
      ├─ cli-proxy-api.exe
      └─ cli-proxy-api-plus.exe
```

* **方式一：Git clone**
* **方式二：手动下载 + 一键生成桌面快捷方式**

下面是**可直接整体替换 README 中对应部分的版本**（我保持了你之前 README 的整体结构，只改了 Quick Start 相关内容）。

---

## 快速开始 / Quick Start

CLIProxyAPI Tray 提供 **两种使用方式**，适合不同用户习惯。

CLIProxyAPI Tray provides **two ways to get started**, depending on your preference.

---

### 方法一：使用 Git Clone

```bash
git clone https://github.com/kitephp/CLIProxyAPI_Tray.git
cd CLIProxyAPI_Tray
````

将主仓库的示例配置复制到当前目录：

```text
config.example.yaml
```

然后运行托盘脚本：

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File cli-proxy-api.ps1
```

---

### 方法二：手动下载 + 一键生成桌面快捷方式

1️⃣ 从 GitHub 下载以下文件，并放入同一目录：

* `cli-proxy-api.ps1`
* `config.example.yaml`
* `create-shortcut.bat`

2️⃣ **双击运行 `create-shortcut.bat`**

* 会自动在桌面创建快捷方式：
  **CLIProxyAPI Tray**
* 快捷方式会以隐藏窗口方式运行托盘脚本
* 工作目录自动指向脚本所在目录

3️⃣ 双击桌面快捷方式启动托盘

---

### 首次运行行为 / First Run Behavior

首次运行时，CLIProxyAPI Tray 会自动执行以下操作：

* 如果 `config.yaml` 不存在：

  * 自动从 `config.example.yaml` 复制生成
* 如果 `remote-management.secret-key` 为空：

  * 自动弹窗要求输入密码
* 如果未安装 CLIProxyAPI：

  * 自动检测最新版本
  * 询问是否下载并安装

On first launch, CLIProxyAPI Tray will:

* Create `config.yaml` from `config.example.yaml` if missing
* Prompt for `remote-management.secret-key` if empty
* Detect and download the latest CLIProxyAPI version if not installed

---

### 启动方式总结 / Launch Summary

* **开发者**：直接运行 `cli-proxy-api.ps1`
* **普通用户**：运行一次 `create-shortcut.bat`，以后只需双击桌面快捷方式
