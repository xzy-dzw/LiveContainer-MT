<div align="center">
   <img width="160" height="160" src="./screenshots/livecontainer_icon.png" alt="Logo">
</div>

<div align="center">
  <h1><b>LiveContainer 多任务版</b></h1>
  <p><i>在 LiveContainer 上实现一主三副虚拟窗口，同屏多开多个 App</i></p>
</div>

<p align="center">
  <a href="https://github.com/xzy-dzw/LiveContainer-MT/releases">📦 下载地址（Releases）</a>
</p>

---

## 这是什么

本项目是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的非官方分支，在官方 nightly 源码之上构建了虚拟窗口多任务内核。多个 App 以远程 scene hosting 方式同屏运行，通过底部 Dock 切换、全屏、关闭。

两个 IPA 构建产物：

| 文件 | 说明 |
|---|---|
| **LiveContainer.ipa** | 单文件版（约 4.5 MB） |
| **LiveContainer+SideStore.ipa** | 内置 SideStore 自动重签（约 34 MB） |

## 功能

- **一主三副虚拟窗口**：最多 4 个 App 同屏，点副窗切主位，弹性分屏动画
- **窗口控制条**：全屏 / 关闭 / 镜像切换，玻璃质感设计
- **冷启动占位**：大 App 加载时显示图标 + 名称 + 转圈，首帧渲染后自动淡入
- **后台保活**：定位 + 混音音频 + 画中画三重保活通道，舞台期间 App 不被系统挂起
- **页面状态保持**：锁屏/切后台时 escalating re-pin 维持 scene 前台，返回后不刷新、不回首页
- **进程看门狗**：基于 getpgid 检测崩溃窗口并自动回收，不误杀主线程卡顿的健康 App
- **FPS 显示**：等宽数字 OSD，实时帧率

## 技术实现

多任务代码集中在两个目录：

```
MultitaskSupport/          host 侧
├── AppSceneViewController      基于 _UISceneHostingController 的远程 scene 承载
├── DecoratedAppSceneViewController  窗口卡片、启动占位、控制条
├── MultitaskDockView           舞台管理：布局、看门狗、保活、re-pin
├── MultitaskStage              分屏布局与 FPS 芯片
└── LCStageIPC.h                host↔guest Darwin 通知与共享 defaults 通道

TweakLoader/
└── UIKit+GuestHooks.m        guest 侧：生命周期屏蔽、backdrop 采样、触摸隔离
```

核心技术点：
- 复用 iOS 私有 `_UISceneHostingController` 跨进程托管 App（与 Xcode Previews 同一套机制）
- host 在 willResignActive 启动 escalating re-pin 定时器（0.2s/0.5s/1s/每 1s），靠定位保活在后台持续运行
- guest 端通过 Darwin 通知接收 backdrop 采样指令，仅全屏时启动离屏渲染
- 窗口回收基于 getpgid 进程存活检测，无需 guest 心跳

## 系统要求

- iOS / iPadOS 16.0+（推荐 iOS 17+，主要在 iOS 26 上验证）
- 侧载安装需开启开发者模式
- 升级 IPA 时选择「保留 App 扩展」

## 使用

1. App 列表点开 App 即进入多任务舞台，最多 4 个
2. 点副窗切主位，控制条按钮全屏/关闭
3. 底部 Dock 可继续启动新 App
4. 设置页可切换保活通道、默认多任务启动、锁定页面状态等

## 从源码构建

CI 跟随官方流程：push 到 `main` 自动构建两个 IPA。手动执行「构建 IPA」workflow 并勾选发布即可发 Release。

## 致谢

- 基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer) nightly
- 二合一版内置 [SideStore](https://github.com/SideStore/SideStore)
- 爱好者非官方分支，仅供学习交流
