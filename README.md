# Restly

Restly 是一个轻量的原生 macOS 菜单栏健康提醒工具。它根据真实键盘、鼠标 Idle 状态计算电脑使用时间，并提醒喝水、休息眼睛和站起来活动。

## 系统要求

- macOS 13 或更高版本
- App 运行不依赖 Xcode 或开发环境
- 构建需要 Xcode Command Line Tools

## 安装和使用

打开：

```text
dist/Restly.dmg
```

将 `Restly.app` 拖到 DMG 中的 `Applications` 快捷方式。启动后 Restly 不显示 Dock 图标，入口位于屏幕右上角菜单栏的眼睛图标。

首次启动时，macOS 会请求通知权限。喝水与站立使用系统通知，护眼提醒使用覆盖所有显示器的沉浸式全屏界面。

## 功能

- 三种提醒共享一个低频调度器
- 喝水通知：已喝水、10 分钟后提醒
- 全屏护眼界面：系统背景模糊、圆形倒计时、`Esc` 跳过、稍后提醒、自动关闭
- 久坐通知：我起来了、10 分钟后提醒
- 根据键盘和鼠标 Idle 时间暂停连续使用计时
- 离开电脑后重新开始护眼和久坐计时
- 正确处理锁屏、睡眠、合盖与唤醒，不补发历史提醒
- 暂停 30 分钟、1 小时或 2 小时
- UserDefaults 本地设置
- 使用系统登录项服务自动启动
- 无账号、后端、网络服务或数据库

## 构建

```bash
./scripts/build.sh
```

该命令会生成：

```text
dist/Restly.app
dist/Restly.dmg
```

App 使用 ad-hoc 本地签名，适合个人本机使用，不包含 Developer ID 或公证流程。

## 开发模式

开发模式使用护眼 30 秒、喝水 60 秒、站立 90 秒，不会修改正式设置：

```bash
swift run Restly --development-mode
```

也可以运行已构建的 App：

```bash
RESTLY_DEVELOPMENT_MODE=1 ./dist/Restly.app/Contents/MacOS/Restly
```

开发模式的设置页还提供“立即测试护眼浮层”按钮。

要在启动后立即显示护眼浮层，可以使用：

```bash
./dist/Restly.app/Contents/MacOS/Restly --development-mode --show-eye-rest
```

要直接检查设置窗口，可以附加 `--show-settings`。

## 测试

```bash
swift test
```
