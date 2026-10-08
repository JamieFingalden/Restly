# Restly

[![CI](https://github.com/JamieFingalden/Restly/actions/workflows/ci.yml/badge.svg)](https://github.com/JamieFingalden/Restly/actions/workflows/ci.yml)
[![下载](https://img.shields.io/github/v/release/JamieFingalden/Restly)](https://github.com/JamieFingalden/Restly/releases/latest)

[English](README.md)

Restly 是一个轻量的原生 macOS 菜单栏健康提醒工具，提醒你喝水、休息眼睛和站起来活动，还带一个专注工作用的番茄钟。

它不监测键盘鼠标。「人在不在电脑前」这个判断整个交给 macOS —— 锁屏、息屏、合盖、切换用户就是离开。好处是播放器和会议软件会主动阻止关屏，所以看视频、开视频会议时不会被误判成离开，而这恰恰是最需要护眼提醒的时候。

## 系统要求

- macOS 13 或更高版本
- Apple Silicon 或 Intel Mac，同一个通用安装包即可
- App 运行不依赖 Xcode 或开发环境
- 源码构建需要 Xcode 26.2 或更高版本，并通过 `xcode-select` 选中

## 安装和使用

1. 从[最新版本](https://github.com/JamieFingalden/Restly/releases/latest)下载 [Restly.dmg](https://github.com/JamieFingalden/Restly/releases/latest/download/Restly.dmg)。
2. 打开 DMG，将 `Restly.app` 拖到 `Applications` 快捷方式。
3. 从「应用程序」打开 Restly。Apple Silicon 和 Intel Mac 都使用同一个安装包。

发布包使用临时签名，尚未经过 Apple 公证。如果首次打开被 macOS 拦截，先尝试打开一次，再到「系统设置 → 隐私与安全性 → 仍要打开」确认。这是 [Apple 官方提供的打开方式](https://support.apple.com/zh-cn/102445)。

如需核验下载文件，可从同一个 Release 下载 `SHA256SUMS.txt`，在两个文件所在目录运行：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

启动后 Restly 不显示 Dock 图标，入口位于屏幕右上角菜单栏的心形图标；暂停时图标会变成划掉的心形。当前界面为中文，无需账号或订阅。

Restly 不使用系统通知，也不会请求通知权限。喝水和站立用自绘的浮窗，护眼用覆盖所有显示器的全屏界面。

## 功能

- 三种提醒共用一个定时器，直接定到最近的触发时刻，常态下每几十分钟才唤醒一次 CPU
- 喝水浮窗：已喝、5 分钟后提醒
- 站立浮窗：我起来了、5 分钟后提醒，可选点击后锁定屏幕（走系统原生锁屏，和 Ctrl+Cmd+Q 同一条路，带淡入动画）
- 全屏护眼：纯黑背景、圆形倒计时、`Esc` 跳过、10 分钟后提醒、倒计时结束自动关闭
- 番茄钟：专注/短休息/长休息循环，时长和长休息间隔都可配置；计时中菜单栏心形图标旁直接显示倒计时
- 专注结束自动开始休息（可配置）；休息结束后停下等手动开始，防止无意识地连刷番茄
- 锁屏冻结进行中的番茄钟，解锁后自动续上；计时进度在应用重启后恢复（若重启耗时超过剩余时间，该番茄按已完成计）
- 锁屏 / 息屏 / 合盖 / 切换用户即视为离开，期间不计时也不弹提醒
- 离开超过设定时长（默认 2 分钟）后回来，护眼和站立计时从零开始；喝水不重置，因为离开不代表喝了水
- 离开时间短于阈值当作没发生，冻结的时间会补回来
- 暂停 30 分钟、1 小时、2 小时，或暂停到手动恢复
- 改设置只影响对应的那一项，不会清空正在走的计时
- UserDefaults 本地设置，使用系统登录项服务自动启动
- 无账号、后端、网络服务或数据库

## 设置

- **提醒**：三种提醒各自的开关与间隔、护眼时长、浮窗是否 5 秒自动消失、离开重置阈值
- **番茄钟**：专注/短休息/长休息时长、长休息间隔、阶段流转方式、菜单栏是否显示倒计时
- **通用**：登录启动

## 构建

```bash
./scripts/build.sh
```

该命令会生成：

```text
dist/Restly.app
dist/Restly.dmg
dist/SHA256SUMS.txt
```

构建同时包含 `arm64` 和 `x86_64` 两种架构，并统一使用临时签名。分发前校验安装包：

```bash
./scripts/verify-release.sh
```

## 开发模式

开发模式使用护眼 30 秒、喝水 60 秒、站立 90 秒，番茄钟缩短为 30/10/20 秒，不会修改正式设置：

```bash
swift run Restly --development-mode
```

也可以运行已构建的 App：

```bash
RESTLY_DEVELOPMENT_MODE=1 ./dist/Restly.app/Contents/MacOS/Restly
```

开发模式的设置页还提供「立即测试全屏护眼」按钮。

可用的调试参数：

| 参数 | 作用 |
| --- | --- |
| `--development-mode` | 缩短三种提醒的间隔和番茄钟的各段时长 |
| `--show-eye-rest` | 启动 1 秒后直接显示全屏护眼 |
| `--show-settings` | 启动后打开设置窗口 |
| `--show-menu-preview` | 把菜单栏面板作为独立窗口显示 |
| `--show-water-preview` | 直接弹出喝水浮窗 |
| `--show-stand-preview` | 直接弹出站立浮窗 |
| `--show-pomodoro-preview` | 直接弹出番茄钟转段浮窗 |
| `--open-menu` | 启动 2 秒后自动点开真实的菜单栏面板（调试/截图用） |

## 测试

```bash
swift test
```

## CI 与发布

推送到 `main` 或提交 Pull Request 时，GitHub Actions 会分别在 Intel/macOS 15 和 Apple Silicon/macOS 26 上运行测试，再构建并校验通用 DMG。安装包保存在工作流的 Artifacts 中。

发布新版本时，更新 `Support/Info.plist` 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`，提交后推送匹配的标签，例如 `v0.2.0`。同一工作流会测试并打包标签对应的源码，核对标签与应用版本，全部通过后自动发布 DMG 和 SHA-256 校验和。重新运行工作流不会覆盖已发布版本的安装包。

## 参与贡献

欢迎提交 Issue 和 Pull Request！较大的改动请先开 Issue 讨论一下。

## 许可证

[MIT](LICENSE)
