# tether-doctor · 手机 USB 共享网络体检工具

> **一条命令，把「手机 USB 共享网络」为什么慢、为什么断，查清楚。**
> 默认只读、零依赖、不写注册表；要落地改动必须显式 `-Apply`，且每一项都能一键回滚。
> 偶发断流抓不到？用 `-Watch` 挂机几小时，自动出断流证据链。

[![CI](https://github.com/BFwmds330/tether-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/BFwmds330/tether-doctor/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4)
![powershell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

[English](README.en.md) · 中文

---

## 它解决什么问题

用手机 USB 共享网络给电脑上网的人，几乎都遇到过这几件事：

- 用着用着**突然断一下**，几秒后又自己好了，想复现却抓不到；
- 速度**忽快忽慢**，测速一次 40Mbps、一次 8Mbps，不知道哪个是真的；
- 搜到的教程**互相矛盾**：一大票文章让你「去设备管理器 → 网卡 → 电源管理 → 取消允许计算机关闭此设备」，可你的网卡**根本没有这个标签页**；
- 不知道该怀疑数据线、USB 口、驱动、手机设置，还是运营商，只能一项一项瞎试。

`tether-doctor` 把「该怀疑什么、怎么判定、能改什么」固化下来：
**先给结论，再给证据，最后只改有把握的那几项。**

## 它能查什么

| # | 检查项 | 判定逻辑 |
|---|---|---|
| 1 | 共享网卡识别与现状 | 自动认出 RNDIS / Tethering 网卡，打印 IP、网关、MTU、跃点、DNS |
| 2 | **USB 链路协商速率** | <100Mbps 直接判定为线材或 USB 口问题（12Mbps 就是插到了 USB 全速口/劣质线） |
| 3 | **USB 物理链路还原** | 沿父设备链还原「手机 → 复合设备 → 哪个集线器 → 控制器」，定位到具体端口 |
| 4 | **网卡是否支持电源管理** | 支持才提示可改；不支持就明确告诉你「没有那个标签页是正常的」，不再瞎折腾 |
| 5 | **全局 USB 选择性暂停** | AC / DC 分开报告，这是 USB 侧真正会导致瞬断的开关 |
| 6 | 集线器层省电开关 | 列出所有 USB 集线器与该手点哪一个（并标出手机挂在哪个上） |
| 7 | 默认路由与跃点 | 多默认网关 = 忽快忽慢/偶发断流的常见根因 |
| 8 | DNS 现状 | 运营商下发的 DNS 往往又慢又不稳 |
| 9 | **MTU 探测** | 用 DF 位试探最大可过 MTU，专治「小网页正常、大文件/视频卡」 |
| 10 | **异常设备归因** | 标出**属于本手机**且处于 Error 状态的接口（复合设备里某个接口报错会引起周期性重枚举 → 共享瞬断） |
| 11 | 延迟 / 丢包 / 抖动实测 | `-Test` 开启；TCP 往返 ×N，输出最小/中位/平均/最大/抖动，只花几十 KB 流量 |
| 12 | 手机端设置清单 | 各品牌菜单路径见 [docs/PHONE-SETTINGS.md](docs/PHONE-SETTINGS.md) |

## 它能改什么（`-Apply`，共 5 项，其中 3/5 为条件触发，全部可逆）

| # | 改动 | 回滚 |
|---|---|---|
| 1 | 关闭**全局 USB 选择性暂停**（AC+DC） | `3-revert.bat` 恢复为启用 |
| 2 | 把共享网卡的 DNS 设为 `223.5.5.5 / 119.29.29.29`（可自定义） | `3-revert.bat` 恢复为自动获取 |
| 3 | 网卡**自身**支持电源管理时，禁用它（RNDIS 通常不支持，不会触发） | `3-revert.bat` 重新启用 |
| 4 | 禁用**属于本手机且报错**的非 RNDIS 接口（典型是 HDB Interface） | `3-revert.bat` 重新启用 |
| 5 | 仅当存在**多条默认路由**时，把共享网卡接口跃点设为 1 | `3-revert.bat` 恢复自动跃点 |

**脚本不做的事**：不改注册表、不代改集线器那一层的勾选框（没有可靠的注册表等价物，宁可给清单让你手点）、不做大文件测速（不偷跑你的流量）。

## 挂机监控：抓「偶发瞬断」的证据链

单次测速抓不到「偶发断一下」的问题。`-Watch` 会挂机连续采样，把每一次断流与当时的环境一起记录下来：

```powershell
# 监控 2 小时，每 3 秒采样一次；随时 Ctrl+C 结束，报告照常生成
.\tether-doctor.ps1 -Watch 120 -Interval 3

# 只监控 Wi-Fi 链路的稳定性（自动识别不中时，也可显式指定网卡）
.\tether-doctor.ps1 -Watch 60 -AdapterName "WLAN"
```

它每次采样会同时记录：**TCP 往返 + 适配器状态 + 链路速率 + IPv4 + 网关**，
于是断流发生时，「当时网卡是 Up 还是掉了」这个关键事实会被自动留存下来。
结束（或被 Ctrl+C 打断）后输出两份文件：

- `logs/watch-<时间戳>.md` —— 人类可读报告
- `logs/watch-<时间戳>.csv` —— 逐次采样原始数据，可直接用 Excel 画趋势图

报告结构：总览 → **断流事件（证据链）** → 接口状态/地址变化 → 每 5 分钟趋势 → **同期 Windows 系统事件** → **自动结论**。

节选：

```markdown
## 1. 总览
| 指标 | 值 |
| 成功率 | 99.2%（成功 1190 / 失败 10） |
| 延迟 最小/中位/P95/最大 (ms) | 34 / 45 / 96 / 812 |
| 相邻抖动均值 (ms) | 6.1 |
| 断流事件 | 2 次，累计约 14s |

## 2. 断流事件（证据链）
| 开始 | 持续 | 适配器状态 | 说明 |
| 20:14:33 | 6s | Up | 持续约 6s（2 次失败采样），期间适配器 Up |
| 21:02:11 | 8s | Up | 持续约 8s（3 次失败采样），期间适配器 Up |

## 6. 自动结论
- 有 2 次断流时适配器**仍为 Up** → 物理链路正常但无连通：指向手机侧（信号 / 制式切换 / 达量限速 / 省电策略）或运营商。
```

**为什么要记适配器状态**：断流时网卡若**掉了**（不是 Up），问题在 USB 侧——线材接触、供电、驱动重载；
网卡**仍是 Up** 却不通，说明物理链路好着，问题在手机或运营商。这一步直接把排查方向砍掉一半。

> 想看「开热点 / 接电话 / 换位置」是否与断流相关？把当时记下的时刻与报告里的时间戳对齐即可。

## 诊断包：一键导出可分享的报告

求助时最麻烦的是「描述不清症状」。`-Export` 把体检全程的判定记录（含 `-Test` 统计）导出成两份文件：

```powershell
.\tether-doctor.ps1 -Export .\to-share -Sanitize
```

- `tether-doctor-<时间戳>.html` —— 自包含静态页（无 JS），直接转发、打印都行
- `tether-doctor-<时间戳>.json` —— 结构化数据，可程序化处理

`-Sanitize` 在导出时把 MAC 打码为 XX-XX、IPv4 保留前两段（192.168.x.x）、USB VID/PID 与序列号打码——
只影响导出的文件，屏幕输出照旧。`-Watch` 模式下监控的 md/csv 也会一并导出（脱敏逐行生效）；
连「没找到共享网卡」的失败运行都能导出——跑不通时的信息恰恰最值得发给别人看。

## 快速开始

```powershell
git clone https://github.com/BFwmds330/tether-doctor.git
cd tether-doctor
.\1-check.bat          # 双击即可：只读体检 + 延迟实测，不改任何设置
```

`1-check.bat` / `2-apply.bat` / `3-revert.bat` 都会自己请求管理员权限（弹一次 UAC）。
不想提权就直接跑脚本本体：

```powershell
.\tether-doctor.ps1                        # 只读体检（默认，零写入）
.\tether-doctor.ps1 -Test                  # 体检 + TCP 往返/丢包/抖动实测
.\tether-doctor.ps1 -Watch 120             # 挂机监控 2 小时，输出断流证据链
.\tether-doctor.ps1 -Apply                 # 落地安全项（需管理员）
.\tether-doctor.ps1 -Revert                # 回滚（需管理员）
.\tether-doctor.ps1 -AdapterName "WLAN"    # 指定网卡（可监控非 USB 链路）
```

### 参数

| 参数 | 说明 |
|---|---|
| `-Apply` / `-Revert` | 落地 / 回滚可逆改动（需管理员） |
| `-Test` | 秒级延迟、丢包、抖动实测 |
| `-Watch <分钟>` | 挂机监控时长 |
| `-Interval <秒>` | 监控采样间隔，默认 3 |
| `-LogDir <目录>` | 监控报告输出目录，默认 `.\logs` |
| `-FailThreshold <次>` | 连续失败多少次算一次断流，默认 2 |
| `-SlowMs <毫秒>` | 超过该延迟记为劣化样本，默认 500 |
| `-AdapterName` / `-InterfaceIndex` | 显式指定网卡（默认自动识别 USB 共享网卡） |
| `-Dns` / `-TestCount` | `-Apply` 写入的 DNS / `-Test` 每目标探测次数 |
| `-Export <目录>` | 导出诊断包（JSON + 自包含 HTML）；`-Watch` 时连监控 md/csv 一起导出 |
| `-Sanitize` | 导出前脱敏：MAC→XX-XX、IPv4 保留前两段、USB VID/PID 与序列号打码（只影响导出文件） |

## 示例输出（节选）

```
==================================================================
 1. 共享网络适配器
==================================================================
  · 接口名        : 以太网 3
  · 描述          : Remote NDIS based Internet Sharing Device #2
  · ifIndex / MAC : 4 / FE-8D-4C-XX-XX-XX
  · IPv4 / 网关   : 192.168.x.x / 192.168.x.x
  · MTU / 跃点    : 1500 / 25
  [OK]   USB 链路协商速率 426.0 Mbps —— 线材/USB 口没问题，瓶颈不在这里

==================================================================
 3. 网卡自身的电源管理（能不能勾那两项）
==================================================================
  [OK]   该驱动不支持电源管理 —— 设备管理器里没有「电源管理」标签页是正常的，不是你没找到
  ·   （实测报错：A device attached to the system is not functioning.）
  ·   微软通用 RNDIS 驱动（wceisvista.inf）就属于这种，Windows 无法对它做省电挂起，因此这一项无需处理。

==================================================================
 4. 全局 USB 选择性暂停（这才是 USB 侧真正会瞬断的开关）
==================================================================
  [问题] AC：已启用（0x00000001）—— USB 空闲时会被挂起，是共享瞬断的嫌疑点

==================================================================
 9. 异常设备（手机复合设备里有接口报错会周期性重枚举 → 共享瞬断）
==================================================================
  [问题] HDB Interface  [Error]  USB\VID_339B&PID_108A&MI_02\...   ← 属于本手机，优先处理

==================================================================
 10. 实测：TCP 往返 / 丢包 / 抖动（不发大文件，仅几十 KB）
==================================================================
  [OK]   223.5.5.5:443  成功 20/20  最小 40ms  中位 45ms  平均 46ms  最大 60ms  抖动 7ms
  [OK]   www.baidu.com:443  成功 20/20  最小 34ms  中位 44ms  平均 43ms  最大 47ms  抖动 5ms
```

## 关键坑（为什么网上的通用教程对你没用）

1. **微软通用 RNDIS 驱动根本不支持电源管理。**
   `Get-NetAdapterPowerManagement` 会直接报 `A device attached to the system is not functioning`（Windows System Error 31），设备管理器里的「电源管理」标签页压根不会渲染。所以「取消允许计算机关闭此设备」这类建议，对手机 USB 共享**无效**——脚本会自动识别这种情况并明确告诉你跳过，而不是让你去点一个不存在的勾选框。

2. **USB 链路速率会出卖你。**
   `LinkSpeed` 显示 426Mbps / 480Mbps 说明线材和端口没问题；显示 12Mbps 就是掉到 USB 全速了，换线换口立刻见效。这一步能把「网络慢」和「USB 慢」当场分开。

3. **复合设备里有一个接口报错，就会拖垮整条链路。**
   华为/荣耀机型在开启 USB 调试时会出现 `HDB Interface`，没装官方驱动时它常年处于 Error 状态；Windows 会周期性重试枚举，表现就是共享网络毫无规律地瞬断。这类问题的正确解法是补齐驱动、关掉调试接口，或者直接禁用那个报错接口——而不是去改网络设置。

4. **USB 侧真正会挂起设备的是「全局 USB 选择性暂停」。**
   它在默认电源计划里是**启用**的，`powercfg` 一条命令就能改，而且对整条 USB 链路生效。

5. **多默认路由 = 抖动。**
   Wi-Fi 和 USB 共享同时在线时，两条默认路由会互相抢，表现出来就是忽快忽慢。

6. **MTU 不对，症状是「能开网页、传不动文件」。**
   脚本用 ICMP DF 位按 8 字节步进试探出真实可过 MTU，并给出对应的 `netsh` 命令。

## 实测数据（同一台机器，两个时间点）

| 时间 | HTTPS 往返 | 抖动 | 吞吐 |
|---|---|---|---|
| 采样 1 | 最小 60ms / 中位 66ms / 最大 **308ms** | ~21ms | 单连接 40Mbps，4 并发 49Mbps |
| 采样 2（1 小时后） | 最小 40ms / 中位 51ms / 最大 73ms | **7ms** | — |
| 挂机 1 分钟（`-Watch 1 -Interval 3`） | 平均 42.8ms | **1.4ms** | 成功率 100% |

同一个 USB 链路、同一部手机，抖动从 21ms 掉到 1.4ms——说明**波动主要来自无线侧**（信号、制式切换、基站调度），而不是 USB。
这也正是本工具强调「先判定瓶颈在哪一侧」的原因：**如果手机端直接测速很快、电脑端很慢，瓶颈才在电脑/USB。**

## 手机端设置

完整的多品牌菜单路径见 **[docs/PHONE-SETTINGS.md](docs/PHONE-SETTINGS.md)**，覆盖华为/荣耀、小米/Redmi/POCO、OPPO/一加/realme、vivo/iQOO、三星、魅族、努比亚/红魔、原生 Android。

其中收益最大的三项：

1. **关「智能切换上网卡 / 自动切换数据卡」**——掉线第一大来源
2. **关「WLAN+ / WLAN 助理 / 智能网络切换」**——避免在 WLAN 与移动数据间反复切换
3. **开「休眠时始终保持网络连接」**——否则锁屏后省电策略会掐掉数据连接

另外：同时开 Wi-Fi 热点时，电脑侧带宽会被热点设备分走（**同一条蜂窝链路，手机内部没有 QoS**）；弱信号时可用拨号盘 `*#*#4636#*#*` 锁 4G。

## 自动化与开发

| 文件 | 用途 |
|---|---|
| `build/build.ps1` | 打包成可分发 zip（本地与 CI 共用），打印 `ZIP_PATH` / `ZIP_SHA256` |
| `build/get-release-notes.ps1` | 从 CHANGELOG 抽取指定版本，生成 Release 说明 |
| `tests/verify-encoding.ps1` | 强制 `.ps1` = UTF-8 with BOM + CRLF、`.bat` = 无 BOM + CRLF |
| `tests/verify-syntax.ps1` | 用 PowerShell 解析器校验所有 `.ps1` 的语法 |
| `tests/smoke.ps1` | 真跑只读体检与 `-Watch`，断言退出码 0 且报告含全部小节 |
| `.github/workflows/ci.yml` | 推送/PR 时跑上述检查并打包 |
| `.github/workflows/release.yml` | 推 `v*.*.*` tag 即自动校验 → 打包 → 生成说明 → 发布 Release |

```powershell
# 本地跑一遍 CI 的全部检查
./tests/verify-encoding.ps1
./tests/verify-syntax.ps1
./tests/smoke.ps1
./build/build.ps1
```

**贡献者注意**：`tether-doctor.ps1` 必须以 **UTF-8 with BOM** 保存。
少了 BOM，Windows PowerShell 5.1 会按 ANSI 解码中文并抛出一堆 `Unexpected token`——
这不是洁癖，是本项目真实踩过的坑，`tests/verify-encoding.ps1` 和 CI 会把它挡住。

## 常见问题

**Q：为什么我的网卡没有「电源管理」标签页？**
A：因为驱动不支持。微软通用 RNDIS（`wceisvista.inf`）就是这种，属于正常现象，无需处理。脚本第 3 节会直接给出这个结论。

**Q：`-Apply` 会改注册表吗？**
A：不会。全部通过 `powercfg`、`Set-DnsClientServerAddress`、`Set-NetIPInterface`、`Disable-PnpDevice` 这些官方接口完成。

**Q：没有管理员权限能用吗？**
A：能体检（大部分信息可读），也能 `-Watch`。但 `-Apply` / `-Revert` 会逐项提示「需要管理员权限，跳过」并继续跑完，不会中途崩。

**Q：`-Watch` 要跑多久？跑一晚上行吗？**
A：行。采样间隔 3 秒时，1 小时约 1200 条记录，CSV 只有几百 KB。中途 Ctrl+C 会照常生成报告。
想抓「偶发断一下」，建议至少覆盖一个完整的「手机发热 + 长时间在线」周期（1～2 小时起）。

**Q：会消耗我的流量吗？**
A：默认不做任何下载。`-Test` 与 `-Watch` 都只做 TCP 建连（每次几十字节）。工具刻意不做带宽测速，避免在按流量计费的链路上偷跑。

**Q：只支持手机 USB 共享吗？**
A：用 `-AdapterName` / `-InterfaceIndex` 可以指向任意网卡（例如 Wi-Fi），此时 USB 专属判定会自动跳过，路由、DNS、MTU、异常设备与挂机监控仍然有用。

## 限制

- 仅支持 Windows 10 / 11（依赖 `Get-NetAdapter`、`Get-PnpDevice`、`powercfg`）。
- 集线器层省电开关无法可靠地程序化修改，需要按清单手点。
- MTU 建议值是 ICMP DF 试探的**近似结果**（步进 8 字节），改与不改都不影响正常使用，且给了还原命令。
- 读取系统事件在部分机器上需要管理员权限；无权限时报告会注明「未能读取」，其余结论不受影响。
- 手机端菜单路径因机型/系统版本而异，以 [docs/PHONE-SETTINGS.md](docs/PHONE-SETTINGS.md) 的语义为准。

## 目录结构

```
tether-doctor/
├── tether-doctor.ps1              主脚本（体检 / -Test / -Watch / -Apply / -Revert）
├── 1-check.bat                    双击：只读体检（自动提权）
├── 2-apply.bat                    双击：落地安全项 + 实测（自动提权）
├── 3-revert.bat                   双击：回滚 + 实测（自动提权）
├── docs/
│   ├── DESIGN.md                  实现原理与每一项判定的依据
│   └── PHONE-SETTINGS.md          全品牌手机菜单路径
├── build/
│   ├── build.ps1                  打包脚本
│   └── get-release-notes.ps1      从 CHANGELOG 生成发布说明
├── tests/
│   ├── verify-encoding.ps1        编码校验（BOM / CRLF）
│   ├── verify-syntax.ps1          语法校验
│   └── smoke.ps1                  冒烟运行（含 -Watch）
├── .github/workflows/
│   ├── ci.yml                     持续集成
│   └── release.yml                自动发版
├── README.md / README.en.md
├── CHANGELOG.md
└── LICENSE                        MIT
```

## License

[MIT](LICENSE)
