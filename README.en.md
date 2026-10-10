# tether-doctor · Diagnostics for phone USB tethering on Windows

> **Find out why your phone's USB tethering is slow or keeps dropping — with evidence, not guesswork.**
> Read-only by default, zero dependencies, no registry writes. Anything that changes is opt-in via `-Apply` and fully revertible.

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
| 12 | Phone-side checklist | Exact menu paths for Huawei / Honor MagicOS |

## What `-Apply` changes (4 items, all revertible)

| # | Change | Revert |
|---|---|---|
| 1 | Disable **global USB selective suspend** (AC + DC) | `3-revert.bat` |
| 2 | Set tethering NIC DNS to `223.5.5.5 / 119.29.29.29` (configurable) | `3-revert.bat` |
| 3 | Disable NIC power management *if* the driver supports it (usually not, for RNDIS) | Device Manager |
| 4 | Disable the phone's **Error-state non-RNDIS interface** (typically `HDB Interface`) | `3-revert.bat` |
| 5 | Only if multiple default routes exist: set the tethering NIC metric to 1 | `Set-NetIPInterface` |

The script deliberately does **not** touch the registry, does **not** automate hub-level power saving (there is no reliable registry equivalent — you get a checklist instead), and does **not** run bandwidth tests (it will not burn your data plan).

## Quick start

```powershell
git clone https://github.com/BFwmds330/tether-doctor.git
cd tether-doctor
.\1-check.bat          # double-click: read-only report + latency test
```

The three `.bat` files self-elevate (one UAC prompt). Or call the script directly:

```powershell
.\tether-doctor.ps1                 # read-only report (default)
.\tether-doctor.ps1 -Test           # report + TCP latency / loss / jitter
.\tether-doctor.ps1 -Apply          # apply the safe changes (admin)
.\tether-doctor.ps1 -Revert         # revert (admin)
.\tether-doctor.ps1 -Dns 1.1.1.1    # custom DNS for -Apply
```

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

Same cable, same phone, jitter dropped from 21 ms to 7 ms: the variance comes from the **radio side**, not USB.
Hence the rule this tool is built around — *if the phone itself speed-tests fast and the PC is slow, the bottleneck is the PC/USB; if both are slow, it is signal, cell, or a throttled data plan.*

## Phone-side checklist (Huawei / Honor MagicOS)

1. **Turn off "Smart network switching between SIMs"**: Settings → Mobile network → SIM card management
2. **Turn off "WLAN+"**: Settings → WLAN → More settings → WLAN+
3. **Turn on "Keep network connection while sleeping"**: Settings → Battery → More battery settings
4. **USB tethering switch**: Settings → Mobile network → Personal hotspot → More sharing settings → USB tethering
5. **Lock to 4G on weak signal**: dial `*#*#4636#*#*` → Phone information → Set preferred network type → LTE only
6. **Developer options → turn off "USB debugging"** (removes the `HDB Interface` error; tethering does not need it)
7. Turn off battery saver; **do not keep a phone-side VPN on** while tethering
8. Make sure the SIM in use is **not throttled** (throttled plans drop to ~1 Mbps)

## FAQ

**Why is there no Power Management tab on my adapter?** Because the driver does not support it. That is normal for the generic RNDIS driver, and check #4 tells you so explicitly.

**Does `-Apply` write to the registry?** No. It uses `powercfg`, `Set-DnsClientServerAddress`, `Set-NetIPInterface` and `Disable-PnpDevice` only.

**Can I run it without admin rights?** Yes — you get the full report; `-Apply` / `-Revert` report "admin required, skipping" per item and continue.

**Will it use my data?** No downloads by default. `-Test` only opens TCP connections (tens of KB).

## Limitations

- Windows 10 / 11 only (uses `Get-NetAdapter`, `Get-PnpDevice`, `powercfg`).
- Hub-level power saving must be changed by hand (a checklist is printed).
- The MTU suggestion is an approximation from an 8-byte-step DF probe; a restore command is provided.
- Phone menu paths vary by model and OS version.

## License

[MIT](LICENSE)
