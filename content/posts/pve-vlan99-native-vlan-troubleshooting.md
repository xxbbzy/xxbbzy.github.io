---
title: "PVE VLAN 99 网络不通故障复盘：H3C Trunk Native VLAN 剥离 Tag 导致 ARP 回复丢失"
date: 2026-11-18T14:17:00+08:00
tags: ["Proxmox VE", "PVE", "VLAN", "H3C", "Linux Bridge", "网络排障"]
categories: ["知识库"]
summary: "PVE 管理口突然 ping 不通网关，第一反应是 PVE 配错了，顺着 ARP 和抓包一层层往下查，最后发现问题出在对面：H3C Trunk 口的 Native VLAN 被设成了 99，回程报文被剥了标签，vmbr0.99 根本收不到 ARP 回复。把 PVID 改回 1，网络立刻恢复。"
draft: false
---

> 注：文中 IP 地址已替换为 RFC 5737 文档示例地址（192.0.2.0/24），结构与真实环境一致。

## 事情是这样的

一台 PVE 宿主机 pve02，管理网走 VLAN 99，某天突然连不上网关了。第一反应自然是怀疑 PVE 自己的配置——桥接错了？VLAN 没放行？子接口建错了？但顺着线索一层层往下查，真相却在对面的交换机上：H3C 的 Trunk 口把 VLAN 99 设成了 Native VLAN，回程报文被剥掉了标签，PVE 的 `vmbr0.99` 根本收不到 ARP 回复。

这是一次很典型的二层排障：现象在三层，根因在二层，证据在抓包里。

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

当时看到的现象很直接：

```bash
ping 192.0.2.1
From 192.0.2.20
Destination Host Unreachable
```

再看邻居表：

```bash
ip neigh show dev vmbr0.99
```

```text
192.0.2.1 FAILED
```

网关就在同一个子网里，ping 不通、ARP 解析失败，这说明问题不在路由也不在 DNS，而在二层——PVE 和网关之间，MAC 地址根本就没学到。

## 二、根因：Native VLAN 99 把回程报文的标签剥掉了

定位的关键一步，是在两个位置同时抓 ARP 包：VLAN 子接口 `vmbr0.99` 上抓一次，物理网卡 `nic3` 上再抓一次。两边一对比，问题就现形了。

PVE 发出的 ARP 请求是正常的，带着 VLAN 99 的标签：

```text
ethertype 802.1Q
vlan 99
Request who-has 192.0.2.1
tell 192.0.2.20
```

但网关返回的 ARP 回复，到达 PVE 时却没有标签：

```text
ethertype ARP
Reply 192.0.2.1
is-at 90:3f:86:ed:dd:82
```

请求带标签、回复不带标签——这就是不对称的地方。`vmbr0.99` 只收 VLAN 99 的 Tagged 报文，一份没打标签的回复到了它手里，自然就被丢掉了，ARP 永远解析不出来。

再看 H3C Gi7 的配置，原因就清楚了：

```text
Link Type:    TRUNK
Native VLAN:  99
Permit VLAN:  2-200
```

Trunk 口对 PVID 所属 VLAN 的出站报文是要剥离标签的。Gi7 把 VLAN 99 当成了 Native VLAN，所以网关的回复经过它发往 PVE 时，标签就被去掉了。PVE 发出去的是 Tagged VLAN 99，回来的是 Untagged，两边对不上，通信就断了。

## 三、修复：把 Gi7 的 Native VLAN 改回 1

修复本身很简单：把 Gi7 的 PVID 从 99 改成 1，VLAN 99 继续留在 Permit 列表里，改完 PVE 立刻就能和网关通信了。

| 参数 | 修复前 | 修复后 |
|---|---|---|
| Link Type | TRUNK | TRUNK |
| Native VLAN | 99 | 1 |
| Permit VLAN | 2–200 | 2–200 |
| VLAN 99 出站 | Untagged | Tagged |
| PVE 网关通信 | 失败 | 正常 |

H3C Comware CLI：

```text
system-view
interface GigabitEthernet 1/0/7
port trunk pvid vlan 1
quit
```

改完之后记得确认一件事：如果交换机用启动配置做持久化，验证无误后要保存配置，否则重启后 PVID 又会回到 99，故障会重演。

## 四、这次排查留下的四个经验

### 1. VLAN-aware 只是开了 VLAN 过滤，不是自动打 Tag

PVE 里这行配置：

```text
bridge-vlan-aware yes
```

它的作用只是让 Linux Bridge 支持 VLAN 过滤与转发。真正决定宿主机管理流量属于 VLAN 99 的，是子接口本身：

```text
vmbr0.99
```

把这两个概念混在一起，是很多人第一次配 PVE VLAN 时会踩的坑。

### 2. Trunk 放行了 VLAN，不等于出站一定带 Tag

H3C 的 Trunk 口有个容易忽略的行为差别：对非 PVID 的允许 VLAN，出站保留 VLAN Tag；对 PVID 所在的 VLAN，出站去掉 Tag。

所以 Permit VLAN 和 Native VLAN 是两套独立的配置，检查的时候要分开看——只看放行列表，很容易漏掉 PVID 这一项。

### 3. 看到 ARP FAILED，先查二层

网关在同一个子网里，出现 `Destination Host Unreachable`，再加上邻居表里的 `FAILED`，第一反应应该是 ARP 和二层通信出了问题，而不是去怀疑默认路由或 DNS。这次如果一开始就往路由和 DNS 上想，会绕不少弯路。

### 4. 抓包要逐层抓，对比着看

这次的定位顺序值得留下来：

- 查 IP 和路由：`ip -br addr`、`ip route get`，确认路由确实走 `vmbr0.99`，排除三层配置问题。
- 查网桥 VLAN：`bridge link show`、`bridge vlan show`，确认 nic3 在 vmbr0 里、VLAN 99 已放行。
- 查邻居表：`ip neigh show dev vmbr0.99`，发现网关 ARP 解析失败，把范围锁定在二层。
- 在 VLAN 接口抓包：`tcpdump -eni vmbr0.99 arp`，看到请求发出了、回复没回来。
- 在物理网卡抓包：`tcpdump -eni nic3 'arp or vlan'`，看到请求带 VLAN 99 标签、回复没带标签，不对称出现了。
- 查交换机 Native VLAN：发现 Gi7 的 PVID 是 99，改成 1 后恢复。

只在 `vmbr0.99` 上抓包，只能看到"回复没回来"；只有下到物理网卡那一层，才能看到回复其实回来了，只是标签被剥掉了。

## 五、以后怎么避免

给 PVE、ESXi 这类虚拟化宿主机和交换机互联的场景，定一条规矩就够了：**凡是宿主机要用 Tagged VLAN 子接口访问的网络，就不要把它同时设为对端 Trunk 口的 Native VLAN。**

| 用途 | VLAN | 交换机发送方式 |
|---|---|---|
| Native VLAN | 1 | Untagged（若允许） |
| PVE 管理网络 | 99 | Tagged |
| 虚拟机业务网络 | 10 | Tagged |
| 其他业务网络 | 20、50 | Tagged |

生产环境还可以更进一步：专门拿一个不承载业务的 VLAN 做 Native VLAN，并限制不必要的 Untagged 流量。

## 写在最后

这次故障的本质，是两边对"VLAN 99 的报文该不该带标签"理解不一致：PVE 这边认为管理流量永远是 Tagged 的，交换机那边却因为 PVID 也是 99，把回程报文当成 Native 流量剥了标签。一边在等带标签的回复，一边发回来的是没标签的回复，ARP 永远对不上，网络就这么断了。

所以下次再遇到 VLAN 不通，除了确认 VLAN 放没放行，不妨多问一句：这个 VLAN 是不是同时被设成了 PVID？出站的 Tag 还在不在？请求和回复对称吗？这三个问题，往往比反复检查 IP 和路由更快找到答案。
