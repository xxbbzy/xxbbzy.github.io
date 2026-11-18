---
title: "PVE VLAN 99 网络不通故障复盘：H3C Trunk Native VLAN 剥离 Tag 导致 ARP 回复丢失"
date: 2026-11-18T14:17:00+08:00
tags: ["Proxmox VE", "PVE", "VLAN", "H3C", "Linux Bridge", "网络排障"]
categories: ["知识库"]
summary: "PVE 管理口 ping 不通网关，从怀疑 PVE 配置错误出发，逐层抓包定位到 H3C Trunk 端口的 Native VLAN（PVID）被设为 99，导致回程报文被剥离 VLAN Tag、vmbr0.99 收不到 ARP 回复；把 PVID 改回 1 即恢复。"
draft: false
---

> 注：文中 IP 地址已替换为 RFC 5737 文档示例地址（192.0.2.0/24），结构与真实环境一致。

## 一、故障概况

| 项目 | 配置 |
|---|---|
| 宿主机 | PVE pve02 |
| 物理网卡 | nic3 |
| Linux Bridge | vmbr0（VLAN-aware） |
| 管理 VLAN 接口 | vmbr0.99 |
| 管理 IP | 192.0.2.20/24 |
| 网关 | 192.0.2.1 |
| 交换机 | H3C |
| 连接端口 | Gi7（Trunk） |
| 允许 VLAN | 2–200 |
| 故障根因 | Gi7 Native VLAN 设置为 99 |

故障现象：

```bash
ping 192.0.2.1
From 192.0.2.20
Destination Host Unreachable
```

同时：

```bash
ip neigh show dev vmbr0.99
```

输出：

```text
192.0.2.1 FAILED
```

说明 PVE 无法完成网关 MAC 地址解析。

## 二、根因：Native VLAN 99 导致回程报文丢失标签

故障时的实际通信过程：PVE 发出的 ARP 请求带 VLAN 99 标签，网关的 ARP 回复却没有标签。示意图简化了交换机与网关之间的路径，突出 Gi7 的出站 VLAN Tag 处理。

关键抓包证据：

PVE 向网关发送 ARP：

```text
ethertype 802.1Q
vlan 99
Request who-has 192.0.2.1
tell 192.0.2.20
```

网关返回 ARP：

```text
ethertype ARP
Reply 192.0.2.1
is-at 90:3f:86:ed:dd:82
```

请求带 VLAN 99 标签，回复没有 VLAN 标签。

结合 H3C Gi7 的实际配置：

```text
Link Type:    TRUNK
Native VLAN:  99
Permit VLAN:  2-200
```

可以确定，Gi7 把 VLAN 99 当作 Native VLAN，在向 PVE 发送 VLAN 99 报文时剥除了 VLAN Tag。

而 PVE 使用 vmbr0.99 接收 VLAN 99 的 Tagged 报文，因此无法正常处理这些未打标签的回复。

## 三、最终修复方案

将 H3C Gi7 的 Native VLAN 从 99 修改为 1，保持 VLAN 99 在 Permit 列表中。

| 参数 | 修复前 | 修复后 |
|---|---|---|
| Link Type | TRUNK | TRUNK |
| Native VLAN | 99 | 1 |
| Permit VLAN | 2–200 | 2–200 |
| VLAN 99 出站 | Untagged | Tagged |
| PVE 网关通信 | 失败 | 正常 |

H3C Comware CLI 示例：

```text
system-view
interface GigabitEthernet 1/0/7
port trunk pvid vlan 1
quit
```

实际修复后，PVE 成功与网关通信。

如果交换机使用启动配置持久化机制，还应在验证无误后保存配置，避免重启后恢复旧的 PVID。

## 四、这次排查最值得记住的技术知识

### 1. VLAN-aware 不等于自动打 Tag

PVE 的：

```text
bridge-vlan-aware yes
```

只是让 Linux Bridge 支持 VLAN 过滤与转发。

真正让宿主机管理流量归属 VLAN 99 的，是：

```text
vmbr0.99
```

### 2. Trunk 放行 VLAN 不代表一定携带 Tag

H3C Trunk 端口通常：

- 对非 PVID 的允许 VLAN，出站保留 VLAN Tag。
- 对 PVID 所属 VLAN，出站去掉 VLAN Tag。

因此，Permit VLAN 和 Native VLAN 是两个不同的配置概念。

### 3. ARP FAILED 是非常重要的排查线索

当网关属于同一个子网时：

```text
Destination Host Unreachable
```

结合：

```text
192.0.2.1 FAILED
```

首先应该排查 ARP 和二层通信，而不是立即怀疑默认路由或 DNS。

### 4. 抓包应当逐层进行

这次的定位过程：

- 检查 IP、路由
  `ip -br addr`、`ip route get`
  确认路由走 vmbr0.99。
- 检查网桥 VLAN
  `bridge link show`、`bridge vlan show`
  确认 nic3 属于 vmbr0，且允许 VLAN 99。
- 检查邻居表
  `ip neigh show dev vmbr0.99`
  发现网关 ARP 解析失败。
- 在 VLAN 接口抓包
  `tcpdump -eni vmbr0.99 arp`
  发现 ARP 请求发出，但没有收到回复。
- 在物理网卡抓包
  `tcpdump -eni nic3 'arp or vlan'`
  发现 ARP Request 带 VLAN 99，Reply 未携带标签。
- 检查 H3C Native VLAN
  发现 Gi7 PVID 为 99，修改为 1 后恢复正常。

## 五、以后如何避免类似问题？

对于 PVE、ESXi、其他虚拟化宿主机或交换机互联场景，建议统一一条规范：

**需要通过 Tagged VLAN 子接口访问的网络，不要同时将其设置为交换机对应 Trunk 端口的 Native VLAN。**

例如：

| 用途 | VLAN | 交换机发送方式 |
|---|---|---|
| Native VLAN | 1 | Untagged（若允许） |
| PVE 管理网络 | 99 | Tagged |
| 虚拟机业务网络 | 10 | Tagged |
| 其他业务网络 | 20、50 | Tagged |

另外，生产环境可以考虑专门使用一个不承载业务的 VLAN 作为 Native VLAN，并限制不必要的 Untagged 流量。

这次故障最核心的一句话：

> PVE 发出的是 Tagged VLAN 99，H3C Gi7 因 Native VLAN 也是 99，将回程 VLAN 99 报文剥离了标签，导致 vmbr0.99 无法收到 ARP 回复。将 Gi7 Native VLAN 改为 1 后，通信恢复正常。

以后遇到 VLAN 不通，除了检查 VLAN 是否放行，还要检查 PVID、出站 Tag 行为，以及 ARP 请求和回复是否对称。这就是这次最值得积累的排障经验。
