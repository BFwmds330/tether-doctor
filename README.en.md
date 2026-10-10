# tether-doctor · Diagnostics for phone USB tethering on Windows

> **Find out why your phone's USB tethering is slow or keeps dropping — with evidence, not guesswork.**
> Read-only by default, zero dependencies, no registry writes. Anything that changes is opt-in via `-Apply` and fully revertible.
> Can't reproduce a random drop? Let `-Watch` run for hours and produce a discontinuity evidence trail.

[![CI](https://github.com/BFwmds330/tether-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/BFwmds330/tether-doctor/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4)
![powershell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

English · [中文](README.md)

---

## The problem

Almost every "USB tethering is unstable" guide tells you to open Device Manager → your network adapter → **Power Management** → uncheck *"Allow the computer to turn off this device to save power"*.

On a phone-tethered RNDIS adapter **that tab does not exist**. The generic Microsoft RNDIS driver (`wceisvista.inf`) does not implement power management at all — `Get-NetAdapterPowerManagement` fails with *"A device attached to the system is not functioning"* (System Error 31). People then spend an evening hunting for a checkbox that was never there.

This tool encodes the actual decision tree: **what to suspect, how to prove it, and what is safe to change.**

## What it checks

| # | Check | How it decides |
|---|---|---|
| 1 | Tethering adapter discovery | Finds the RNDIS / tethering NIC; prints IP, gateway, MTU, metric, DNS |
| 2 | **USB link negotiation speed** | `<100 Mbps` ⇒ cable or USB port problem (12 Mbps = USB Full Speed) |
| 3 | **Physical USB path** | Walks the parent chain: phone → composite device → hub → controller → port |
| 4 | **Does the NIC support power management?** | If not, says so plainly instead of sending you to a missing tab |
| 5 | **Global USB selective suspend** | Reported for AC and DC — the switch that actually suspends USB devices |
| 6 | Hub-level power saving | Lists every USB hub and which one to change (marks the one your phone is on) |
| 7 | Default routes / metrics | Multiple default gateways = jitter and random stalls |
| 8 | DNS | Carrier-pushed DNS is often slow and flaky |
| 9 | **MTU probing** | DF-bit probe for the real maximum MTU — fixes "pages load, files stall" |
| 10 | **Faulty devices, attributed** | Flags Error-state interfaces **belonging to this phone** (a broken interface in a composite device causes periodic re-enumeration ⇒ brief disconnects) |
| 11 | Latency / loss / jitter (`-Test`) | TCP round-trips ×N: min / median / avg / max / jitter, a few tens of KB of traffic |
| 12 | Phone-side checklist | Per-brand menu paths in [docs/PHONE-SETTINGS.md](docs/PHONE-SETTINGS.md) |

## What `-Apply` changes (5 items; #3/#5 trigger conditionally; all revertible)

| # | Change | Revert |
|---|---|---|
| 1 | Disable **global USB selective suspend** (AC + DC) | `3-revert.bat` |
| 2 | Set tethering NIC DNS to `223.5.5.5 / 119.29.29.29` (configurable) | `3-revert.bat` |
| 3 | Disable NIC power management *if* the driver supports it (usually not, for RNDIS) | `3-revert.bat` |
| 4 | Disable the phone's **Error-state non-RNDIS interface** (typically `HDB Interface`) | `3-revert.bat` |
| 5 | Only if multiple default routes exist: set the tethering NIC metric to 1 | `3-revert.bat` (restores automatic metric) |

The script deliberately does **not** touch the registry, does **not** automate hub-level power saving (there is no reliable registry equivalent — you get a checklist instead), and does **not** run bandwidth tests (it will not burn your data plan).

## Watch mode: an evidence trail for random drops

A single speed test cannot catch "it drops for a few seconds every hour". `-Watch` samples continuously and records every outage **together with the environment at that moment**:

```powershell
# Watch for 2 hours, sampling every 3 seconds; Ctrl+C any time and the report is still written
.\tether-doctor.ps1 -Watch 120 -Interval 3

# Watch a Wi-Fi link instead (or when auto-detection misses)
.\tether-doctor.ps1 -Watch 60 -AdapterName "WLAN"
```

Each sample records **TCP round-trip + adapter state + link speed + IPv4 + gateway**.
That last part matters: when a drop happens, "was the NIC still Up?" is the single most useful fact, and it is captured automatically.

Two files are produced at the end (or on Ctrl+C):

- `logs/watch-<timestamp>.md` — human-readable report
- `logs/watch-<timestamp>.csv` — raw per-sample data, easy to chart in Excel

Report sections: overview → **outage events (evidence)** → interface/address changes → 5-minute trend → **concurrent Windows system events** → **automatic conclusions**.

The key inference:

- NIC **not Up** during the outage → the problem is on the **USB side** (cable contact, power, driver reload).
- NIC **still Up** but no connectivity → the physical link is fine; suspect the **phone** (signal, radio mode switching, throttled plan, power saving) or the carrier.

## Quick start

```powershell
git clone https://github.com/BFwmds330/tether-doctor.git
cd tether-doctor
.\1-check.bat          # double-click: read-only report + latency test
```

The three `.bat` files self-elevate (one UAC prompt). Or call the script directly:

```powershell
.\tether-doctor.ps1                        # read-only report (default)
.\tether-doctor.ps1 -Test                  # report + TCP latency / loss / jitter
.\tether-doctor.ps1 -Watch 120             # 2-hour watch with outage evidence
.\tether-doctor.ps1 -Apply                 # apply the safe changes (admin)
.\tether-doctor.ps1 -Revert                # revert (admin)
.\tether-doctor.ps1 -AdapterName "WLAN"    # target a specific adapter
```

| Parameter | Purpose |
|---|---|
| `-Apply` / `-Revert` | Apply / revert the reversible changes (admin) |
| `-Test` | Second-level latency, loss and jitter test |
| `-Watch <minutes>` | Long-running monitoring |
| `-Interval <seconds>` | Sampling interval, default 3 |
| `-LogDir <dir>` | Report output directory, default `.\logs` |
| `-FailThreshold <n>` | Consecutive failures that count as one outage, default 2 |
| `-SlowMs <ms>` | Samples slower than this are marked degraded, default 500 |
| `-AdapterName` / `-InterfaceIndex` | Target a specific adapter |
| `-Dns` / `-TestCount` | DNS written by `-Apply` / probes per target for `-Test` |

## Sample output (excerpt)

```
 1. 共享网络适配器  (Tethering adapter)
  · 接口名        : 以太网 3
  · 描述          : Remote NDIS based Internet Sharing Device #2
  [OK]   USB 链路协商速率 426.0 Mbps —— 线材/USB 口没问题，瓶颈不在这里

 3. 网卡自身的电源管理
  [OK]   该驱动不支持电源管理 —— 设备管理器里没有「电源管理」标签页是正常的

 4. 全局 USB 选择性暂停
  [问题] AC：已启用（0x00000001）—— USB 空闲时会被挂起，是共享瞬断的嫌疑点

 10. 实测：TCP 往返 / 丢包 / 抖动
  [OK]   223.5.5.5:443  成功 20/20  最小 45ms  中位 49ms  平均 50ms  最大 68ms  抖动 7ms
```

## Measured on a real machine

| Sample | HTTPS round-trip | Jitter | Throughput |
|---|---|---|---|
| 1 | min 60 ms / median 66 ms / max **308 ms** | ~21 ms | 40 Mbps single, 49 Mbps over 4 connections |
| 2 (one hour later) | min 40 ms / median 51 ms / max 73 ms | **7 ms** | — |
| 1-minute `-Watch` | avg 42.8 ms | **1.4 ms** | 100% success |

Same cable, same phone, jitter dropped from 21 ms to 1.4 ms: the variance comes from the **radio side**, not USB.
Hence the rule this tool is built around — *if the phone itself speed-tests fast and the PC is slow, the bottleneck is the PC/USB; if both are slow, it is signal, cell, or a throttled data plan.*

## Phone-side settings

Full per-brand menu paths: **[docs/PHONE-SETTINGS.md](docs/PHONE-SETTINGS.md)** — Huawei/Honor, Xiaomi/Redmi/POCO, OPPO/OnePlus/realme, vivo/iQOO, Samsung, Meizu, Nubia/RedMagic, stock Android.

The three that matter most:

1. **Turn off "smart SIM/data-card switching"** — the single biggest source of drops
2. **Turn off "WLAN+ / Wi-Fi assistant / smart network switch"** — stops it flip-flopping between Wi-Fi and mobile data
3. **Turn on "keep network connection while sleeping"** — otherwise power saving kills the connection once the screen locks

Also: running a Wi-Fi hotspot at the same time splits the **same cellular link** (the phone provides no QoS), and on weak signal you can lock to 4G via `*#*#4636#*#*`.

## Automation

| File | Purpose |
|---|---|
| `build/build.ps1` | Build the distributable zip (shared by local and CI), prints `ZIP_PATH` / `ZIP_SHA256` |
| `build/get-release-notes.ps1` | Extract a version section from CHANGELOG for the release notes |
| `tests/verify-encoding.ps1` | Enforce `.ps1` = UTF-8 with BOM + CRLF, `.bat` = no BOM + CRLF |
| `tests/verify-syntax.ps1` | Parse-check every `.ps1` |
| `tests/smoke.ps1` | Really run the report and `-Watch`, assert exit code 0 and all report sections |
| `.github/workflows/ci.yml` | Run all checks + build the zip on push/PR |
| `.github/workflows/release.yml` | Pushing a `v*.*.*` tag verifies, builds, generates notes and publishes the Release |

**Contributors**: `tether-doctor.ps1` must be saved as **UTF-8 with BOM**.
Without the BOM, Windows PowerShell 5.1 decodes the Chinese text as ANSI and throws a wall of `Unexpected token` errors — a bug this project actually hit, now guarded by `tests/verify-encoding.ps1` and CI.

## FAQ

**Why is there no Power Management tab on my adapter?** Because the driver does not support it. That is normal for the generic RNDIS driver, and check #4 tells you so explicitly.

**Does `-Apply` write to the registry?** No. It uses `powercfg`, `Set-DnsClientServerAddress`, `Set-NetIPInterface` and `Disable-PnpDevice` only.

**Can I run it without admin rights?** Yes — you get the full report and `-Watch`. `-Apply` / `-Revert` report "admin required, skipping" per item and continue.

**How long can `-Watch` run?** Overnight is fine. At a 3-second interval, one hour is ~1200 CSV rows (a few hundred KB). Ctrl+C still writes the report.

**Will it use my data?** No downloads by default. `-Test` and `-Watch` only open TCP connections (tens of bytes each).

**Does it only work with phone tethering?** Point `-AdapterName` / `-InterfaceIndex` at any adapter (e.g. Wi-Fi); USB-specific checks are skipped automatically while routing, DNS, MTU, faulty-device and watch checks still apply.

## Limitations

- Windows 10 / 11 only (uses `Get-NetAdapter`, `Get-PnpDevice`, `powercfg`).
- Hub-level power saving must be changed by hand (a checklist is printed).
- The MTU suggestion is an approximation from an 8-byte-step DF probe; a restore command is provided.
- Reading the System event log may require admin rights; the report says so explicitly and other conclusions are unaffected.
- Phone menu paths vary by model and OS version.

## License

[MIT](LICENSE)
