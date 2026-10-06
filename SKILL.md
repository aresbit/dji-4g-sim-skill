---
name: dji-4g-sim-skill
description: 在大疆第一代 4G 模块（佰旺 QDC507 / Quectel EG25-G，USB 2ca3:4006）上拉起完整的管理与上网环境——纯 macOS、不用虚拟机、不用 sudo、不用改 USB ID。只要用户提到"大疆 4G 模块""DJI 4G""EG25G""QDC507""2ca3:4006""4G 上网卡""这块卡怎么用""ModemCat""短信模式/上网模式""eSIM 卡管理"，或者在一块插了该模块的新机器上要求"拉起/部署/装好/看看能不能上网"，就使用本 skill——即使用户没有说出"skill"两个字，也要主动用它。也适用于诊断"模块能不能上网""为什么浏览器不走这张卡""AT/eSIM 读不到"这类问题。
---

# 大疆 4G 模块（EG25-G / QDC507）拉起与诊断

## 这个 skill 解决什么

大疆第一代 4G 模块在 macOS 上有个反直觉的地方：**它不生成 `/dev/tty.*`**。
macOS 没有 Qualcomm 的 GobiSerial/QMI 驱动，所以任何依赖 `/dev/ttyUSB*`
的工具（包括 VoHive 本体）在这台 Mac 上都是哑的。

绕过去的办法是**直接对 USB 端点收发 AT 指令**。本 skill 把这个已经验证过的
路径固化下来，依赖 [ModemCat](https://github.com/SuInk/modemcat)（第三方，
以固定版本 + SHA-256 校验引入，不 vendor 源码）：

- 便携安装到 `~/.local/share/dji-4g-sim`，**不写 `/usr/local`，不需要 sudo**；
- 出问题的地方都有对应脚本和排错条目，不用现场重新摸索。

> 适用范围：Apple Silicon / macOS 13+。Intel 版上游未发布；Linux 路径
> （VoHive 本体、Docker、路由器）不在本 skill 覆盖内。

## 新设备上的三步

**第一步——先检测，什么都不改：**

```sh
<skill>/scripts/bootstrap.sh --check
```

它会看平台、看模块在不在 USB 上。如果这里就报"未检测到模块"，别往下走，
去读 `references/troubleshooting.md` #5——**最常见的原因是 USB-C 线只供电
不传数据**，换根线往往就好了。

**第二步——拉起：**

```sh
<skill>/scripts/bootstrap.sh
```

做的事情：检测 → 下载依赖（校验 SHA-256，不通过就中止）→ 解压清隔离属性 →
启动 → 打开 `http://127.0.0.1:7575`。幂等，重复跑不会重复下载。
首次进网页要设管理员账号（账号 3–64 位，密码 ≥12 字节）。

**第三步——确认链路：**

```sh
<skill>/scripts/status.sh
```

只读，随时可跑。它回答四个问题：模块在不在、现在是哪种模式、
默认出口是不是模块、**这张卡真能出网吗**。

## 两种模式：动手前必须先理解这件事

模块侧 `AT+QCFG="usbnet"` 决定一切，改完要重启模块才生效：

| 值 | 界面里叫 | macOS 上发生什么 |
|---|---|---|
| `0` | **短信模式** | 无网卡。可读状态 / 收发短信 / **管 eSIM** / 发 AT |
| `1` | **上网模式** | 免驱出网卡 `EG25G-QDC507`（网关 `192.168.225.1`），可用卡流量上网 |

**关键约束：macOS 上两种模式不能同时好用。** 切到上网模式后
macOS 的 ECM 驱动会占住 USB 接口，ModemCat 的 AT 桥开始报
`LIBUSB_ERROR_ACCESS/PIPE`，于是**短信 / eSIM / AT 调试全部失效**——
界面上会显示"未发现任何 eUICC"，但那不代表卡里没有 eSIM。

所以：

- 用户要**管卡**（看/切 eSIM Profile、收发短信、读信号）→ 短信模式
- 用户要**上网** → 上网模式
- 用户要**边管边用** → macOS 单机做不到，说明这个限制，并指出换平台才是解

切换在网页里做。**切到上网模式前，先念一遍资费**（见下）。

## 常见场景怎么接

| 用户说 | 怎么做 |
|---|---|
| "新机器上把这个模块跑起来" | `bootstrap.sh --check` → `bootstrap.sh` → `status.sh` |
| "能通过这个模块上网吗" | `status.sh`，重点看第 4、5 节 |
| "浏览器怎么不走这张卡" | 看 `status.sh` 第 4 节。多半是代理 TUN 抢了默认路由 → `troubleshooting.md` #3 |
| "eSIM 读不出来" | 先分清是实体 SIM 还是 eUICC，再看当前是不是上网模式 → `troubleshooting.md` #6 |
| "短信功能没了" | 几乎一定是当前在上网模式 → `troubleshooting.md` #2 |
| "有 192.168.225.x 但上不了网" | `troubleshooting.md` #4 |

## 判定"能不能上网"的正确方法

不要只看 IP。`192.168.225.x` **只证明模块自己的 DHCP 在工作**，
不证明它附着上了运营商。三层都要看，缺一不可：

1. `AT+CPIN?` → `READY`
2. 注册状态 `1`(本网) 或 `5`(漫游)
3. **实际出网**——`status.sh` 第 5 节用 `curl --interface <网卡>` 绑源地址
   绕过代理 TUN，直接问"这块网卡自己通不通"

一个很强的旁证：网卡上有**运营商网段的 IPv6 全局地址**（中国移动 `2409:` / `240e:`）
时，基本可以断定已附着蜂窝网。

## 动手前的两条红线

1. **资费**：切到上网模式 = Mac 多了一个真实计费的出口。先确认套餐余量、
   是否漫游、漫游单价；**IoT/漫游卡的 APN 常与消费级不同，不要猜**。
   注意模块可能已经成为系统默认路由——也就是说用户没意识到时，普通流量
   已经在走这张卡。切模式前后都跑 `status.sh` 确认出口。

2. **AT 写入类指令**（`AT+QCFG="usbnet",…` 等）能改网络注册、PDP、USB 模式
   和 SIM 状态，切错可能"既上不了网也切不回来"。只读指令随便发，写入类
   先想清楚再说。不要照搬来源不明的刷机/写卡命令。

## 文件地图

```
dji-4g-sim-skill/
├── SKILL.md                       # 本文件：流程、模式决策、红线
├── manifest/dependencies.json     # 依赖锁定表（版本 + SHA-256），升级只改这里
├── scripts/
│   ├── bootstrap.sh               # 检测 → 安装依赖 → 启动（--check / --start / --no-open）
│   ├── status.sh                  # 只读诊断（--no-egress 可省流量）
│   └── uninstall.sh               # 清理（--purge 连运行数据一起删）
└── references/
    ├── modemcat.md                # 依赖的操作要点：模式、界面功能区、命令行、AT 速查
    └── troubleshooting.md         # 9 条已验证故障：LIBUSB、TUN 抢占、eUICC 读不到…
```

排查问题时：先看 `status.sh` 输出，再按现象去 `troubleshooting.md` 找对应条目，
需要界面操作细节时读 `modemcat.md`。

## 上游、许可与出处

- 依赖：`SuInk/modemcat`（非商业许可 PolyForm Noncommercial 1.0.0，
  基于 VoHive / iniwex5 与 DJOneHub 的既有工作独立维护）
- 本 skill 只把上游当依赖，固定版本 + 校验引入，不修改其代码
- 相关生态：VoHive 本体（`iniwex5/vohive`，Linux）、vodjive（macOS 原生 Go 工具）
- 硬件：佰旺 QDC507 / Quectel EG25-G，USB `2ca3:4006`

## 隐私

共享日志或截图前先抹掉 **EID、ICCID、IMSI、完整手机号、短信验证码**。
`status.sh` 会提醒这一点。
