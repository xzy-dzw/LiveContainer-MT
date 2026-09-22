<div align="center">
   <img width="160" height="160" src="./screenshots/livecontainer_icon.png" alt="Logo">
</div>

<div align="center">
  <h1><b>LiveContainer 多任务版</b></h1>
  <p><i>在 LiveContainer 官方预发行版上打造的虚拟窗口多任务分支：一主三副，同屏多开</i></p>
</div>

<p align="center">
  <a href="https://github.com/xzy-dzw/LiveContainer-MT/releases">📦 下载地址（Releases）</a>
</p>

---

## 这是什么

本项目是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的非官方中文分支，在官方预发行版（nightly，基线提交 `4dbe0f9`）完整源码之上，加入了虚拟窗口多任务内核。所有多任务代码集中在 `MultitaskSupport/` 目录和 guest 侧的 `TweakLoader/UIKit+GuestHooks.m`，构建脚本与 GitHub Actions 编译流程跟随官方，每次发布都产出与官方同名的两个 IPA：

| 文件 | 说明 | 适合谁 |
|---|---|---|
| **LiveContainer.ipa** | 单文件版，只含 LiveContainer 本体（约 4.5 MB） | 用证书自签、AltStore、TrollStore 等方式安装的用户 |
| **LiveContainer+SideStore.ipa** | 二合一版，内置 SideStore（约 34 MB） | 想免电脑签名、7 天自动重签的用户 |

> 两个包的**多任务功能完全一致**，区别只是是否内置 SideStore。用 SideStore 二合一版时，安装升级请选择「保留 App 扩展（Keep App Extensions）」。

## 多任务功能特性

- **一主三副虚拟窗口舞台**：最多 4 个小 App 同屏运行，点副窗即切主位，带弹性分屏动画与玻璃控制条
- **冷启动占位封面**：大 App 加载时显示「图标 + 名称 + 转圈」而不是黑屏，首帧渲染后自动淡入揭开
- **切后台不闪黑**：副窗全程保活不挂起；每个 App 失活时自动冻结最后一屏，回前台先盖真画面再换新帧
- **锁屏/息屏保活**：多任务舞台期间屏幕常亮，并通过混音播放会话让宿主与小 App 锁屏后不被系统冻结
- **看门狗兜底**：每秒健康检查，基于真实进程号（getpgid）收尸崩溃窗口，**不会误杀主线程暂时卡顿的健康 App**；孤儿进程与容器锁自动回收
- **电竞风帧数显示**：SF Mono 等宽数字 + 霓虹绿 OSD 芯片，跳帧不抖动
- 支持点击链接跳转宿主、画中画最小化、多任务设置项（默认多任务启动、首次启动最大化等）

## 系统要求

- iOS / iPadOS 16.0 及以上（推荐 iOS 17+，真机主要在 iOS 26 上验证）
- 侧载安装需开启「设置 → 隐私与安全性 → 开发者模式」
- 安装或升级 IPA 时选择「保留 App 扩展」，否则多任务 guest 进程无法拉起

## 安装方法

1. 前往 [Releases](https://github.com/xzy-dzw/LiveContainer-MT/releases) 下载需要的 IPA
2. 用你常用的侧载工具安装（证书签名 / AltStore / SideStore / TrollStore 等）
3. 首次打开多开的 App 前，在 LiveContainer 设置里确认多任务模式为「虚拟窗口」
4. 二合一版的 SideStore 签名配置（Apple ID、自动刷新）属于 SideStore 功能，请参考 [SideStore 官方文档](https://docs.sidestore.io/)

## 使用方法

- 在 App 列表点开任意 App，即自动进入多任务舞台；连续打开最多 4 个
- 点任意副窗口卡片：切到主位；点玻璃条上的按钮：全屏 / 关闭
- 从屏幕底部 Dock 可以再启动其他 App；第 5 个窗口会被中文提示拦下（请先关闭一个）
- 同一 App 重复启动不会再开一个窗口，而是把已有窗口提到主位

## 目录结构（多任务代码在哪）

```
LiveContainer/
├── MultitaskSupport/              ★ 多任务内核（host 侧）
│   ├── MultitaskDockView.swift      舞台管理器：窗口、布局、看门狗、保活
│   ├── MultitaskStage.swift         分屏布局与 FPS 计数芯片
│   ├── MultitaskManager.swift       容器锁与孤儿进程回收
│   ├── AppSceneViewController.*     guest 场景承载（_UISceneHostingController）
│   ├── DecoratedAppSceneViewController.*  窗口卡片、启动封面、冻结帧
│   ├── LCStageIPC.h                 host 与 guest 的 Darwin/IPC 通道
│   └── UIKitHooks.m                 host 侧触摸与通知钩子
├── TweakLoader/
│   └── UIKit+GuestHooks.m         ★ guest 侧：心跳、冻结帧截图、首帧上报
└── LiveContainerSwiftUI/Views/Settings/
    └── LCMultitaskSettingView.swift  多任务设置页
```

## 从源码构建

项目包含官方全部源码与三个子模块（fishhook / OpenSSL / litehook），CI 流程与官方一致：

- 推送到 `main` 或提交 PR：自动构建两个 IPA 作为构建产物（不发布 Release）
- 手动执行「构建 IPA」工作流并勾选「发布中文 Release」：构建成功后自动创建中文 Release 并上传两个 IPA

本地复现官方打包：安装 Xcode 26.2 后直接使用工程根目录的 `.github/build_github.sh`；仓库外层提供的 `build.sh` 用于补丁链整合与静态校验。

## 致谢与声明

- 内核基于 [LiveContainer](https://github.com/LiveContainer/LiveContainer)（nightly，`4dbe0f9`）
- 二合一版内置 [SideStore](https://github.com/SideStore/SideStore)
- 本项目为爱好者非官方分支，与 LiveContainer / SideStore 官方无关；遇到问题请先在本仓库 Issues 反馈
- 仅供学习交流与个人备份使用，请遵守所在地法律法规及相关软件许可
