---
title: "Windows 绿色版 OpenSSH 服务端安装与配置：局域网 SSH 访问全流程"
date: 2026-11-11T13:20:00+08:00
tags: ["Windows", "OpenSSH", "SSH"]
categories: ["知识库"]
summary: "用官方独立二进制包（绿色版）在 Windows 上手动部署 OpenSSH 服务端：注册服务、生成主机密钥、放行防火墙 22 端口，让局域网内可以 SSH 登录这台机器。"
draft: false
---

## 适用场景

Windows 自带的 OpenSSH 服务端（可选功能）装不上或版本不符合要求时，可以直接用官方发布的独立二进制包部署，也就是俗称的“绿色版”：解压即用，没有安装程序，但注册服务、生成主机密钥、放行防火墙这几步要手动做。

本文基于 OpenSSH_for_Windows_9.5p1（LibreSSL 3.8.2）实测记录。不同版本步骤基本一致，版本号按实际下载的为准。

## 准备

1. 从 Win32-OpenSSH 的官方发布页下载对应版本（`OpenSSH-Win64.zip`），解压到一个固定位置。
2. 准备一个管理员权限的 PowerShell：右键开始菜单 → “Windows PowerShell（管理员）”或“终端（管理员）”，之后所有命令都在这个窗口里执行。
3. 确认 22 端口没有被其他程序占用。

## 关于安装路径：先选好，就不要再动

本次部署用的路径是：

```text
C:\Users\Administrator\Desktop\OpenSSH-Win64\
```

路径可以根据实际情况变更，但有两点要先想清楚：

- 安装脚本注册服务时，服务指向的就是这个路径下的 `sshd.exe`。**装好之后不要移动、重命名或删除这个文件夹**，否则服务找不到程序，无法启动。
- 桌面只是本次的实际位置，不是最推荐的位置。如果是全新部署，建议放在一个固定的、不会被清理的目录，例如 `C:\Tools\OpenSSH-Win64\`；一旦选定，同样不要再动。

下文所有命令都以本次的桌面路径为例，换路径时把 `cd` 的那一行改掉即可。

## 步骤一：绕过执行策略，注册服务

Windows 默认禁止执行未签名的 PowerShell 脚本，安装脚本需要用 `Bypass` 参数临时放行。只影响这一次执行，不会永久改掉系统的执行策略。

```powershell
cd "C:\Users\Administrator\Desktop\OpenSSH-Win64\"
PowerShell.exe -ExecutionPolicy Bypass -File .\install-sshd.ps1
```

安装脚本会做两件事：把 `sshd` 和 `ssh-agent` 注册为系统服务，并把当前目录写入系统 `PATH` 环境变量。重启电脑后，在任意路径的命令行里都能直接调用 `ssh` 或 `sshd`。

## 步骤二：手动生成主机密钥

绿色版不会自动生成主机密钥。没有主机密钥就直接启动服务，会出现服务闪退、`Start-Service` 报错。先在当前目录下生成：

```powershell
.\ssh-keygen.exe -A
```

这条命令会生成服务端所需的全部主机密钥（`ssh_host_*_key`）。只在首次安装时需要做一次；密钥生成后不要删除或覆盖，除非明确要更换服务端身份。

## 步骤三：设为开机自启并启动服务

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'
```

两句命令的顺序可以互换，但都要做：前者是立即启动，后者是保证重启后自动启动。

验证状态：

```powershell
Get-Service sshd
```

`Status` 显示为 `Running`，代表本地 SSH 服务已准备就绪。

## 步骤四：放行防火墙 22 端口（局域网互通的关键）

绿色版安装脚本**不会**自动修改防火墙策略。不放行 22 端口时，本机 `ssh localhost` 可能正常，但局域网内其他机器连不上，表现通常是连接超时。

在管理员 PowerShell 里创建一条入站放行规则：

```powershell
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (Inbound)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22
```

如果只想让局域网访问，可以在规则上加 `-RemoteAddress` 限定来源网段，只放行自己的局域网段，不要放行到整个互联网。需要撤销时，用同一名称删除：

```powershell
Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
```

## 步骤五（备用）：网络类型改成“专用”

如果放行了防火墙仍旧连不上或 Ping 不通，检查当前网络的分类。Windows 把网络归类为“公用网络”时策略更严格，一条命令可以切换为“专用网络”：

```powershell
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
```

注意：这条命令会把本机所有网络连接都改成专用。如果机器同时连着多个网络（例如有线 + 无线），建议先用 `Get-NetConnectionProfile` 看清每个连接的名称，只对目标连接执行切换，不要一股脑全改。

## 远程连接测试

确认服务运行、防火墙放行后，在局域网内另一台机器上测试：

```bash
ssh Administrator@<服务器 IP>
```

首次连接会提示确认服务端主机指纹，核对无误后输入 `yes`，再输入该 Windows 账户的密码即可登录。登录后看到的命令行就是这台 Windows 机器的 shell。

如果连接失败，先在服务端本机跑 `ssh localhost`：本机能通、局域网不通，问题基本在防火墙或网络类型；本机也不通，先看服务状态和主机密钥（见下节排错）。

## 排错：服务起不来，先查这三处

1. **主机密钥缺失**：服务一启动就退出。回到安装目录重新执行 `.\ssh-keygen.exe -A`，确认生成了 `ssh_host_*_key` 文件，再启动服务。
2. **配置文件语法错误**：改过 `sshd_config` 之后起不来，先用自检命令验证配置（在安装目录下执行）：
   ```powershell
   .\sshd.exe -t
   ```
   有输出就按提示改配置，没输出代表配置通过。改配置后要重启服务才生效：`Restart-Service sshd`。
3. **端口被占或服务注册异常**：用 `Get-Service sshd` 看状态，到事件查看器（Windows 日志 → 应用程序和服务日志 → OpenSSH）看 sshd 的报错原文，按原文处理，不要凭猜测反复重装。

## 注意事项

- **路径强绑定**：服务和安装目录强绑定，移动或重命名文件夹会导致服务无法启动。真要换位置，先用 `.\uninstall-sshd.ps1` 卸载服务，挪好位置再重新执行安装脚本。
- **账户与权限**：默认用 Windows 账户密码登录，登录的账户有什么权限，SSH 进来就有什么权限。管理员账户登录后可以执行管理操作，日常使用建议用权限最小的够用账户。
- **不要直接暴露到公网**：本文只解决局域网访问。如果要从外网访问，先换成密钥登录、关掉密码登录，并通过 VPN 或跳板机接入，不要把 22 端口直接映射到公网。
- **卸载**：不需要时，在安装目录下以管理员身份执行 `.\uninstall-sshd.ps1`，再删除前面建的防火墙规则，服务和规则就都清理干净了。
