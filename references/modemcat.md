# ModemCat 操作要点

上游：<https://github.com/SuInk/modemcat> · 非商业许可（PolyForm Noncommercial 1.0.0）
本 skill 只把它当依赖用（固定版本 + SHA-256），不改它的代码。

## 目录

- [它是什么](#它是什么)
- [两种模式：核心心智模型](#两种模式核心心智模型)
- [模式怎么选](#模式怎么选)
- [界面里有什么](#界面里有什么)
- [命令行](#命令行)
- [数据与日志位置](#数据与日志位置)
- [AT 指令速查](#at-指令速查)

## 它是什么

面向**大疆第一代 4G 模块（佰旺 QDC507 / Quectel EG25-G，USB `2ca3:4006`）**和
合宙 Air780 系列的第三方 macOS 管理工具：短信收发、eSIM Profile 管理、
AT 调试、USB 上网，全部通过一个本机网页（`127.0.0.1:7575`）。

关键实现点：macOS 没有 Qualcomm 的 GobiSerial/QMI 驱动，所以这个模块在
macOS 上**不生成 `/dev/tty.*`**。ModemCat 的做法是不走串口，**直接用
libusb 对 USB 端点收发 AT 指令**（日志里那句
`USB AT bridge opened on USB AT … interface 2 out 0x03 in 0x84` 就是它）。
这正是它在 macOS 上能跑而 VoHive 本体（依赖 `/dev/ttyUSB*`）不能的原因。

## 两种模式：核心心智模型

由模块侧的 `AT+QCFG="usbnet"` 决定，改完要重启模块才生效：

| 模式 | 协议 | 界面里叫 | macOS 上发生什么 |
|---|---|---|---|
| `0` | QMI / RMNET | **短信模式** | 无网卡。可读状态/收发短信/管 eSIM/发 AT |
| `1` | CDC-ECM | **上网模式** | 免驱出网卡（硬件端口名 `EG25G-QDC507`，网关 `192.168.225.1`），可用卡的流量上网 |
| `2` | MBIM | 界面不提供 | macOS 无原生驱动 |
| `3` | RNDIS | 界面不提供 | macOS 无原生驱动 |

**这是本 skill 最重要的一条约束：macOS 上两种模式不能同时好用。**
切到上网模式后，macOS 的 ECM 驱动会占住 USB 接口，ModemCat 的 libusb
开始报 `LIBUSB_ERROR_ACCESS/PIPE`，**短信 / eSIM / AT 调试会失效**。
切回短信模式它们才回来（见 `troubleshooting.md` #2）。

## 模式怎么选

- 要**管卡**（看 eSIM Profile、收发短信、读信号/运营商）→ 短信模式
- 要**上网**（把这张卡的流量给 Mac 或转发出去）→ 上网模式
- 要**边管边用** → macOS 单机做不到；需要换平台（Linux 主机 / 路由器，
  VoHive 本体在那儿能同时干两件事）

切换时机与资费强相关，动手前先读 `troubleshooting.md` #1。

## 界面里有什么

| 功能区 | 说明 |
|---|---|
| 模块状态 | 运营商、信号、网络制式、SIM 状态、当前工作模式 |
| 短信模式 | 收发/轮询/验证码提取、清理旧短信、定时短信、来电提醒 |
| eSIM Profile | 读取、下载、启用、改名、删除兼容 eUICC 的 Profile |
| 上网模式 | 切 CDC-ECM，显示实时速度与本次流量 |
| 网络与流量 | USB 网卡、默认出口、代理连通性 |
| AT 调试 | 直接发 AT 指令（危险，见下） |
| 转发渠道 | Bark / Telegram / 企业微信 / 钉钉 / 飞书 / Server 酱 / PushPlus / ntfy / Gotify / Webhook |

**流量统计只算当前 ModemCat 进程运行期间、macOS 明确识别为
Baiwang/DJI 那块网卡的数据，不等于运营商账单。**

## 命令行

本 skill 的依赖以**便携模式**装在
`~/.local/share/dji-4g-sim/modemcat/<version>/`，在那里执行：

```sh
./modemcat start           # 启动并自动打开管理页
./modemcat status          # 看进程与端口
./modemcat logs            # 实时日志（Ctrl+C 退出）
./modemcat open            # 重开网页
./modemcat stop            # 停止
./modemcat service install # 装成开机自启（会写 LaunchAgent）
./install                  # 装到 /usr/local，这一步才需要管理员密码
```

## 数据与日志位置

```
~/Library/Logs/ModemCat/modemcat.log          # 日志
~/Library/Application Support/ModemCat/       # 运行状态、账号、SQLite
```

排查问题时先看日志——它比界面更早暴露 USB 层的问题。

## AT 指令速查

**AT 调试页能改网络注册、PDP、USB 模式、短信存储和 SIM 状态。
不了解作用的指令不要执行，也不要照搬来源不明的刷机/写卡命令。**

只读排查常用（安全）：

```
AT                    # 存活探测，回 OK 即通路正常
AT+CPIN?              # SIM 是否 READY
AT+CSQ                # 信号质量（第一个值 0-31，越大越好；99 = 无信号）
AT+COPS?              # 当前运营商
AT+CREG?  AT+CGREG?   # 语音/分组域注册状态（1 = 本网，5 = 漫游）
AT+QCFG="usbnet"      # 当前 USB 网络模式（0=QMI，1=ECM）
AT+CGDCONT?           # PDP 上下文 / APN
AT+CNUM               # 本机号码（运营商常不提供）
AT+QNWINFO            # 制式与频段
```

写入类（**先想清楚再动**）：

```
AT+QCFG="usbnet",1    # 切上网模式（CDC-ECM），需重启模块
AT+QCFG="usbnet",0    # 切回短信模式（QMI），需重启模块
```

> 模式 2/3 在 macOS 上大概率既出不了网卡、又可能把 AT 通路一起弄丢，
> 届时"既上不了网也切不回来"。界面只提供 0 和 1 是有意为之。
