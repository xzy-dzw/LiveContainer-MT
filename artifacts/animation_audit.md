# MultitaskSupport 动效代码审计报告

审计范围：
- `MultitaskSupport/MultitaskDockView.swift`（2843 行，全文逐行读完）
- `MultitaskSupport/DecoratedAppSceneViewController.m`（575 行，全文）
- `MultitaskSupport/AppSceneViewController.m`（557 行，全文）
- `MultitaskSupport/MultitaskStage.swift`（771 行，纯计算部分确认；玻璃按钮/FPS 计数器里确实藏了动效，一并计入）

审计日期：2026-09-27。结论只说"现在代码长什么样、会出什么事"，不改仓库。

---

## 一、完整动画点清单表

| # | 位置（文件:行号） | 动画目标（什么 view/什么属性） | 当前用的 API | 时长/曲线 | 是否可中断 | 问题/风险 |
|---|---|---|---|---|---|---|
| 1 | MultitaskDockView.swift:1231-1241 | 卡片 view.frame、cornerRadius、borderWidth、shadowCaster.frame、stageBackdrop.alpha、blockPlate.frame、chrome 按钮 frame/alpha、dock alpha/frame（全部塞在同一个 `update` 闭包里） | `UIView.animate(withDuration:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:)` | 0.4s，damping=1.0，velocity=0，`.beginFromCurrentState`+`.allowUserInteraction` | 是（beginFromCurrentState） | 主布局弹簧。damping=1.0 是临界阻尼，没有回弹，本质上是个"长得像弹簧的缓动"；0.4s 偏长。completion 里调 `settleAfterAnimation()` 又跑一遍 `performLayout(animated:false)`，等于动画落地后再瞬写一次全部 frame。 |
| 2 | MultitaskDockView.swift:1208-1217 | Reduce Motion 分支：整个 windowHostingView 内容 | `UIView.transition(with:duration:options:animations:)` + 第二个独立 `UIView.animate(withDuration:0.2)` 改 alpha | 0.2s 交叉溶解 + 0.2s alpha，两条独立动画 | 否（transition 不支持 beginFromCurrentState 续接） | 两个动画块不是一组：一个管内容溶解、一个管 alpha，节奏靠"刚好都是 0.2s"对齐。 |
| 3 | MultitaskDockView.swift:1218-1221 | Reduce Motion 分支结束时机 | `DispatchQueue.main.asyncAfter(deadline: .now()+0.25)` 调 `settleAfterAnimation()` | 固定 0.25s | 否（时钟到了就跑，不管动画真结束没） | 手搓时序：动画标称 0.2s，延时 0.25s 纯属拍脑袋。设备慢一帧就 settle 早了；快一帧就白等。 |
| 4 | MultitaskDockView.swift:1175-1198 | mirroring 分支：所有卡片 view.frame、layer.maskedCorners、shadowCaster.frame | `UIView.performWithoutAnimation { ... view.frame = ...; caster.frame = ...; view.layoutIfNeeded() }` | 0s（瞬时跳变） | 否 | **手搓瞬移**。左右对调时卡片直接从左半屏啪一下跳到右半屏，没有飞行。注释里写"cards fly through the spring"是过期注释，代码实际不飞。这就是黑闪/跳帧的根源——跨进程 surface 在这一帧撕裂重建，又没有遮罩盖住的话就露黑底。 |
| 5 | MultitaskDockView.swift:1095-1099 | mirroring 分支里 stageBackdrop.frame/alpha、blockPlate.frame | `UIView.performWithoutAnimation(backdropUpdates)` | 0s | 否 | 同上，背景板跟着瞬移。 |
| 6 | MultitaskDockView.swift:1168-1172 | mirroring 分支里 chrome 按钮 frame/alpha、dock frame/alpha | `UIView.performWithoutAnimation(chromeUpdates)` | 0s | 否 | 同上。 |
| 7 | MultitaskDockView.swift:1072-1079 | z 序：把所有卡片按反序 `bringSubviewToFront`，`sendSubviewToBack(stageBackdrop)`，`insertSubview(blockPlate, aboveSubview: stageBackdrop)` | 直接调 UIView 方法，**不在任何动画块里** | 瞬时 | 否 | z 序瞬变。虽然这些 z 序在布局前后基本一致，但 mirror 分支里 frame 跳了、z 序也在同一帧重排，一旦顺序和预期差一帧就会看到卡片互相压。 |
| 8 | MultitaskDockView.swift:1265-1269 | z 序：所有 chrome 按钮、fpsCounter、dock 拉到 window 最前 | `window.bringSubviewToFront(...)`，在动画块**外面** | 瞬时 | 否 | 同上。每跑一次 performLayout 都重排 z 序。 |
| 9 | MultitaskDockView.swift:1290-1339 | shadowCaster 的 `layer.shadowPath` | `CATransaction.begin/setDisableActions(true)/shadowPath=/commit` 写模型值，再 `CABasicAnimation(keyPath:"shadowPath")` 从 `presentation().shadowPath` 补间到新路径 | duration=0.4s，timingFunction 手写 `cubic-bezier(0.42,0,0.2,1)` | **否**（CABasicAnimation 不走 UIKit 动画引擎，被新动画顶掉时不会从当前呈现值续接——虽然它手动取了 presentation 作为 fromValue，但下次替换时旧的 CABasicAnimation 被静默移除，没有 completion 协作） | **手搓硬拼**。阴影路径本来应该跟着卡片 frame 一起在 UIView.animate 块里自动动画，作者却因为"shadowPath 不是可动画的 NSLayoutConstraint 属性"而绕到 CA 层手写补间。曲线是手写的 ease-in-out，和卡片用的弹簧曲线根本对不上，眼睛能看出阴影"跟不上"卡片。 |
| 10 | MultitaskDockView.swift:1337 | shadowCaster.frame = cardFrame | 直接赋值，靠外层 UIView.animate 块兜着 | 同 #1 的 0.4s 弹簧 | 是 | 本身没问题，但和 #9 的 CABasicAnimation 是两条独立时间线。 |
| 11 | MultitaskDockView.swift:1246-1263 | 首次进舞台：windowHostingView.alpha、dock alpha、fpsCounter alpha、所有 chrome 按钮 alpha | `UIView.animate(withDuration:0.22, delay:0, options:.allowUserInteraction)` | 0.22s 线性 | 否 | 进舞台淡入。原生 API，但和 #1 的 0.4s 弹簧不是一组——alpha 0.22s 就到 1 了，卡片还在弹簧里滑。 |
| 12 | MultitaskDockView.swift:1713-1727 | 最后一个窗口关掉：windowHostingView/dock/chrome/fps alpha → 0 | `UIView.animate(withDuration:0.2, animations:completion:)` | 0.2s 线性 | 否 | 退场淡出。completion 里才把 isHidden=YES。原生用法，但 completion 里没判断"动画是否被新一次进舞台打断"，只靠 `guard !self.isStagePresented` 兜。 |
| 13 | MultitaskDockView.swift:1668-1681 | settle 之后 0.35s 再 commit 一次主窗几何 | `DispatchQueue.main.asyncAfter(deadline: .now()+0.35)` | 固定 0.35s | 否 | **手搓时序**。作者自己注释说"iOS 19 系统在动画落地后会再改一次 hosting view 几何"，所以用 0.35s 延时去撞系统的下一轮 layout。这是在跟系统赛跑，没有任何保证。 |
| 14 | MultitaskDockView.swift:2386-2391 | mirror 之后 0.6s 收起 swap cover | `DispatchQueue.main.asyncAfter(deadline: .now()+0.6)` | 固定 0.6s | 否 | **手搓时序**。cover 什么时候该掀，本来应该等跨进程 surface 重连完成的回调；这里写死 0.6s。surface 重连慢于 0.6s 就露黑底；快了就提前掀。 |
| 15 | MultitaskDockView.swift:2394-2400 | swap 按钮 glyph 的 `transform.rotation.y` 翻半圈 | `CASpringAnimation(keyPath:"transform.rotation.y")`，fromValue=0，toValue=π，damping=12，stiffness=180，duration=0.4，`swapButton.layer.add(flip, forKey:"swapFlip")` | 0.4s 自定义弹簧 | **否** | **手搓硬拼（最典型）**。直接操作 CALayer，不经过 UIView 动画引擎：(a) 不能被 UIView 动画组取消/续接；(b) 动画结束后 layer 的模型值还是 0，靠 CA 动画自己消失时 snap 回 0——这是"播完就回弹"的把戏，不是真的状态；(c) 没有 completion 回调，不能接后续动作；(d) Reduce Motion 只在外层判断了一次（line 2393），但 CASpringAnimation 本身不响应系统减弱动效设置。 |
| 16 | MultitaskDockView.swift:2413-2430 | returnToLauncher：所有舞台表面 alpha → 0 | `UIView.animate(withDuration:0.22, delay:0, options:.allowUserInteraction, animations:completion:)` | 0.22s 线性 | 否 | 原生。completion 里才 hide。 |
| 17 | MultitaskDockView.swift:2463-2465 | reenterStage：windowHostingView.alpha 0→1 | `UIView.animate(withDuration:0.22)` | 0.22s 线性 | 否 | 和 #1 弹簧不是一组：relayout 弹簧跑 0.4s，alpha 只跑 0.22s，前 0.22s 卡片还在半透明状态下滑入。 |
| 18 | MultitaskDockView.swift:1926-1931 | 进后台后 0.1s / 0.5s 两次重新盖冻结帧 | 两次 `DispatchQueue.main.asyncAfter` | 固定 0.1s / 0.5s | 否 | **手搓时序**。在赌"guest 跨进程写 JPEG 大概要多久"。 |
| 19 | MultitaskDockView.swift:1964-1969 | 后台重钉前台：0.2s / 0.5s / 1.0s 三次重钉 | 三次 `DispatchQueue.main.asyncAfter` | 固定 | 否 | 不是动效，但属于手搓时序。 |
| 20 | MultitaskDockView.swift:2041-2047 | 回前台 8s 兜底：强制掀冻结帧 | `asyncAfter(8.0)` | 固定 8s | 否 | 兜底定时器，合理。 |
| 21 | MultitaskDockView.swift:2066-2079 | 回前台 3s 兜底：强制 commit 几何 | `asyncAfter(3.0)` | 固定 3s | 否 | 同上，兜底。 |
| 22 | MultitaskDockView.swift:2145 | 新窗口入列 0.3s 后才显示 launch placeholder | `DispatchQueue.main.asyncAfter(deadline:.now()+0.3, execute: coverItem)` | 固定 0.3s | 否 | **手搓伪动画时序**：用延时来"等 guest 出第一帧"，而不是用 frame-ready 信号。有 frame-ready 时会 cancel（line 1870），但本身是延时把戏。 |
| 23 | MultitaskDockView.swift:2174-2180 / 2216-2220 | 下一个 runloop tick 再 commit 几何 | `DispatchQueue.main.async { ... commitMainWindowGeometry() }` | 1 个 tick | 否 | 不是动画，是布局后刷新。 |
| 24 | MultitaskDockView.swift:2348-2352 | 关窗后 3s 释放 closingVC | `asyncAfter(3.0)` | 固定 3s | 否 | 内存兜底，合理。 |
| 25 | MultitaskDockView.swift:2555 / 2584 | chrome 按钮 glyph 颜色随背景 luma 切换 | 委托给 `MultitaskStageGlassButton.setGlyphOnDarkBackground(animated:true)` | 见 #28 | 是 | 0.5s 轮询触发，可能和用户正在做的其他动画撞车。 |
| 26 | DecoratedAppSceneViewController.m:210-235 | launchPlaceholder / recovery cover 显示 | 直接 `hidden=NO; alpha=1`，**无淡入** | 0s | 否 | 盖帧瞬切。黑屏时突然冒出 icon+spinner，没有过渡。 |
| 27 | DecoratedAppSceneViewController.m:241-269 | frozenFrameView 显示 | 直接 `hidden=NO; alpha=1`，**无淡入** | 0s | 否 | 盖冻结帧瞬切。这是有意的（不能露黑底），但意味着盖帧和揭帧节奏不对称：盖是瞬的，揭是 0.25s 淡。 |
| 28 | DecoratedAppSceneViewController.m:271-293 | 同时掀 launchPlaceholder + frozenFrameView | `[UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:completion:]` | 0.25s 线性 | 是 | 原生。completion 里 hidden=YES、image=nil、停 spinner。 |
| 29 | DecoratedAppSceneViewController.m:313-330 | 单独掀 frozenFrameView | 同上 0.25s | 0.25s | 是 | 原生。 |
| 30 | DecoratedAppSceneViewController.m:397-405 | contentView 的 transform（缩放） | 直接写 `contentView.transform = CGAffineTransformMakeScale(...)` 或 `sublayerTransform`，**靠外层 UIView.animate 块兜着动画** | 同 #1 | 是 | 本身没动画 API，但 frame/transform 的动画完全依赖"调用方是不是在动画块里"。`applyStageFrame` 在 #1 的弹簧块里被调（line 1046-1047），所以是动画的；但如果谁在动画块外调 applyStageFrame，transform 就瞬移。 |
| 31 | DecoratedAppSceneViewController.m:393 / AppSceneViewController.m:284-319 | 跨进程 scene 几何下发 | `updateFrameWithSettingsBlock:` 内部 `dispatch_after(0.05s)` 防抖 | 固定 50ms | 否 | **手搓防抖**。卡片在屏幕上已经开始弹簧动了，scene 的 frame 设置还要等 50ms 才跨进程推过去，guest 端渲染比宿主 UI 慢半拍。 |
| 32 | DecoratedAppSceneViewController.m:438-451 | PiP 最小化/恢复：view.alpha | `[UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut]` | 0.3s easeInOut | 否 | 原生，但目前代码里没人调 minimizeWindowPiP/unminimizeWindowPiP（死代码）。 |
| 33 | MultitaskStage.swift:436-457 | 玻璃按钮 glyph 颜色切换 | 先 snapshotView 盖一层，再 `UIView.animate(0.18)` 把新 glyph.alpha 0→1；失败时退化到 `UIView.transition(.transitionCrossDissolve, 0.18)` | 0.18s | 是 | 原生，写法标准。 |
| 34 | MultitaskStage.swift:475-494 | 玻璃按钮按压反馈：scale 0.94、tint.alpha、glyph 颜色 | `UIView.animate(spring: damping=pressed?1.0:0.8, duration=pressed?0.12:0.34)` | 0.12s 压下 / 0.34s 弹起 | 是 | 原生。按压/弹起用不同 duration 是有意为之，手感对。 |
| 35 | MultitaskStage.swift:371-380 | zoom 按钮图标 morph（展开/还原箭头） | `glyph.setSymbolImage(image, contentTransition: .replace)` | 系统 SF Symbol 自带 | 是 | 原生 API。 |
| 36 | MultitaskStage.swift:751-762 | FPS 数字跳变时的"心跳"缩放 | 先 `label.layer.removeAllAnimations(); label.transform = CGAffineTransform(1.18,1.18)` **瞬跳到 1.18**，再 `UIView.animate(spring: damping 0.45, duration 0.42)` 弹回 identity | 0.42s 弹簧，但起跳瞬间是瞬跳 | 是（removeAllAnimations 会打断上一次） | 手搓关键帧：模型值瞬跳到 1.18 再弹回，等于把"起点"硬写死在屏幕上。每 0.5s 触发一次，频繁打断。`options` 里同时写了 `.curveEaseOut` 和 spring，二者矛盾。 |
| 37 | MultitaskDockView.swift:2811-2817 | Dock 图标按压缩放 | SwiftUI `.animation(.spring(response:0.28, dampingFraction:0.62), value:isPressed)` | 原生 SwiftUI spring | 是 | 原生。 |
| 38 | AppSceneViewController.m:502-521 | 扩展中断 0.5s 后验尸 | `dispatch_after(0.5s)` | 固定 | 否 | 业务兜底，非动效。 |
| 39 | DecoratedAppSceneViewController.m:423-432 | closeWindow 2.5s 兜底清理 | `dispatch_after(2.5s)` | 固定 | 否 | 业务兜底。 |
| 40 | DecoratedAppSceneViewController.m:490-495 | guest 自己退出 3s 后清槽 | `dispatch_after(3.0s)` | 固定 | 否 | 业务兜底。 |

---

## 二、分类总结

### A 类：苹果原生 API 且用法正确

这些可以不用动：

- **#11** 进舞台 0.22s 淡入（UIView.animate + allowUserInteraction）
- **#12** 退场 0.2s 淡出（UIView.animate + completion 隐藏）
- **#16** returnToLauncher 0.22s 淡出
- **#28/#29** 掀盖 0.25s 淡（beginFromCurrentState，可中断）
- **#33** 玻璃按钮 glyph 颜色 0.18s cross-dissolve
- **#34** 玻璃按钮按压弹簧（0.12/0.34s，damping 1.0/0.8）
- **#35** SF Symbol setSymbolImage morph
- **#37** Dock 图标 SwiftUI spring

### B 类：用了原生 API 但参数/时机不标准

- **#1 主布局弹簧**：`damping=1.0` 是临界阻尼，完全没有回弹，视觉上就是个 0.4s 的缓动，跟"spring"这个词不符。苹果自家的窗口弹簧通常 damping 在 0.85~0.9 之间，带一点点过冲。0.4s 也偏长，快速连点切换时会感觉"肉"。completion 里又同步跑一遍 `performLayout(animated:false)`，等于动画刚落地就把所有 frame 再写一遍——虽然值相同，但会触发 `applyStageFrame` → `updateFrameWithSettingsBlock`（50ms 防抖），多一次跨进程设置下发。
- **#2 Reduce Motion 双动画块**：UIView.transition(0.2s) 和 UIView.animate(0.2s) 是两条独立时间线，靠"时长写一样"对齐。应该合成一个动画组或者直接用 transition 里同时改 alpha。
- **#11/#16/#17 淡入淡出 duration 不统一**：进舞台 0.22s、退场 0.2s、回舞台又 0.22s，肉眼能察觉不一致。
- **#36 FPS 心跳**：options 同时写 `.curveEaseOut` 和 spring，二者语义冲突；先瞬跳到 1.18 再弹回，每次都硬起跳。
- **#30 applyStageFrame 里直接写 transform**：本身没动画，靠"调用方在动画块里"。这是个隐式契约，容易在未来被破坏（比如某个新按钮在动画块外调 applyStageFrame，卡片就瞬移）。

### C 类：手搓硬拼，应该重构

- **#4/#5/#6 mirroring 分支全用 `performWithoutAnimation` 瞬移**（MultitaskDockView.swift:1184-1198）
  - 为什么会出 bug：左右对调时卡片啪一下跳半屏。跨进程的 FBScene surface 在宿主 view.frame 突变时会短暂撕裂/重建，露出容器纯黑底。虽然作者加了 swap cover（#14），但 cover 本身是在跳变**之前**那一帧盖上去的，surface 重连时机和 cover 时机并不对齐。
  - 应该换成什么：把 mirroring 分支也走 #1 的弹簧动画（`UIView.animate spring`，把新 frame 写进 update 闭包），只是 chrome/backdrop 用 performWithoutAnimation 冻结。z 序和 corner mask 在 completion 里再 snap。这样卡片是"飞"过去的，surface 不需要撕裂。

- **#9 CABasicAnimation 手搓 shadowPath 补间**（MultitaskDockView.swift:1325-1333）
  - 为什么会出 bug：阴影曲线是手写的 `cubic-bezier(0.42,0,0.2,1)`（ease-in-out），卡片本身用的是 spring（damping 1.0）。两条曲线数学上不同，眼睛能看到阴影"比卡片慢半拍"。而且 CABasicAnimation 不响应 UIKit 的 interruptions——用户快速连点切换时，新的 shadowPath 动画是从 `presentation()` 取的 fromValue，看似续接了，但旧动画被 `addAnimation(forKey:)` 静默覆盖，没有 completion 协作，settle 时机和 UIView 弹簧的 completion 也对不上。
  - 应该换成什么：把 shadowPath 改成在 UIView.animate 块里直接写模型值，让 UIKit 通过 `CACurrentMediaTime()` 的隐式动画去补间；或者用 `UIView.animate` 的 animator 同时驱动 caster.frame 和 shadowPath，共用同一组 spring 参数。shadowPath 是 layer 可动画属性，UIView animate 块里写它会自动走 action 系统。

- **#15 CASpringAnimation 直接操 swapButton.layer**（MultitaskDockView.swift:2394-2400）
  - 为什么会出 bug：(a) 不走 UIKit 动画引擎，不能被取消/续接——用户连点 swap 按钮时，新动画直接 add 上去，旧动画被替换，但因为模型值从来没写过（fromValue=0, toValue=π，模型还是 0），动画结束后按钮会 snap 回正面。连续点两次时两次翻转会叠在一起视觉错乱；(b) 不响应 Reduce Motion（虽然外层 line 2393 判了一次，但 CASpringAnimation 本身不读系统设置）；(c) 没有 completion，没法接"翻完再干嘛"。
  - 应该换成什么：用 `UIView.animate` 改 `swapButton.transform = CATransform3DMakeRotation(π, 0,1,0)`，在 completion 里把 transform 重置回 identity（或用 3D 翻转动画组）。这样可中断、可续接、跟随 Reduce Motion。

- **#13 settle 后 0.35s 二次 commit**（MultitaskDockView.swift:1668）
  - 为什么会出 bug：作者注释自己说这是在跟 iOS 19 的"系统动画后再改一次 hosting 几何"赛跑。0.35s 是拍的：快设备上系统可能 0.1s 就改完了，这 0.35s 内用户点了别的东西，commit 就被 guard 丢掉；慢设备上 0.35s 不够，照样露旧触摸区域。
  - 应该换成什么：用 `CADisplayLink` 或在 `UIView.animate` 的 completion 里再 `dispatch_async(main)` 两次（而不是写死 0.35s），或者监听 `UIView.animate` 的 target 变化回调，直到 hosting view 的 frame 真正稳定。

- **#14 swap cover 0.6s 固定延时**（MultitaskDockView.swift:2386）
  - 为什么会出 bug：跨进程 surface 重连时间在不同设备/内存压力下差异巨大。0.6s 短了露黑，长了多盖一帧旧图。
  - 应该换成什么：等 guest 自己发的 frame-ready Darwin 通知（代码里已有 `LCStageHostFrameReadyAt` 通道），cover 收到通知再掀；0.6s 只做兜底 backstop。

- **#3 Reduce Motion 分支 asyncAfter(0.25s) settle**（MultitaskDockView.swift:1218）
  - 为什么会出 bug：UIView.transition 的 completion 回调本身就告诉你动画结束了，根本不需要 asyncAfter 0.25s。0.25 是因为动画 0.2s + 留 50ms 余量，纯属手搓。
  - 应该换成什么：用 `UIView.transition(..., animations:...) { finished in self.settleAfterAnimation() }` 的 completion。

- **#18/#19/#22 后台/盖帧/launch cover 的一堆 asyncAfter**（0.1s、0.5s、0.3s、0.2s、0.5s、1.0s）
  - 为什么会出 bug：这些都在用延时模拟"等某个跨进程事件发生"。系统忙的时候延时到了但事件没来，事件来了又因为延时没到被忽略。
  - 应该换成什么：用回调/通知驱动（frame-ready Darwin、scene 重连回调），延时只做 backstop。

- **#7/#8 z 序在动画块外瞬变**（MultitaskDockView.swift:1072-1079、1265-1269）
  - 为什么会出 bug：bringSubviewToFront/sendSubviewToBack 在动画块外是瞬时的。mirror 分支里卡片 frame 刚瞬移完，z 序也在同一帧重排，一旦顺序和预期差一帧就会看到两个卡片互相压。
  - 应该换成什么：z 序重排要么放进动画块（虽然 z 序本身不插值，但至少和 frame 同帧提交），要么在动画 completion 里做（落地后再重排）。

- **#26/#27 盖帧瞬切无淡入**（DecoratedAppSceneViewController.m:218-219、261-262）
  - 为什么会出 bug：盖是瞬的、揭是 0.25s 淡，节奏不对称。锁屏瞬间冻结帧啪一下盖上（其实是为了挡黑，合理），但回前台时冻结帧揭掉用了 0.25s 淡——guest 真帧其实早到了，却被冻结帧半透明挡了 0.25s。
  - 应该换成什么：盖也用 0.05~0.1s 的极短淡入（挡黑的同时不突兀），或者盖/揭时长对称。

- **#31 scene 几何 50ms 防抖**（AppSceneViewController.m:316）
  - 为什么会出 bug：卡片在屏幕上弹簧动了，guest 端收到的 frame 还停留在 50ms 前的值。快速连点切换时，guest 永远在"追"宿主 UI。
  - 应该换成什么：弹簧动画期间用 `CADisplayLink` 逐帧把当前呈现 frame 推给 scene（虽然贵，但主窗只有一个），或者至少把防抖降到 16ms（一帧）。

### D 类：多个动画不同步导致闪屏/错位

- **D1：mirror 分支整体无飞行 + cover 0.6s 硬延时**（#4 + #14）。卡片瞬移 → surface 撕裂 → 盖帧是上一帧 JPEG → 0.6s 后掀。这是用户反馈"左右翻转时黑闪一下"的直接原因。
- **D2：shadowPath CABasicAnimation 曲线 ≠ 卡片弹簧曲线**（#9 vs #1）。阴影和卡片数学上不同步，快速切换时阴影"粘"在旧位置。
- **D3：进舞台淡入 0.22s vs 卡片弹簧 0.4s**（#11 vs #1）。alpha 已经全亮了，卡片还在半透明状态下滑。
- **D4：reenterStage 里 alpha 动画和 relayout 弹簧分开**（#17 + #1）。0.22s alpha 到 1，但卡片 frame 弹簧要 0.4s。
- **D5：Reduce Motion 分支 transition + alpha animate + asyncAfter 0.25s 三套时钟**（#2 + #3）。
- **D6：settle 后 0.35s 二次 commit 用 asyncAfter**（#13），和动画 completion 不是同一个事件源。
- **D7：applyStageFrame 里 frame 立刻写，但 scene 设置 50ms 后才跨进程推**（#30 vs #31），宿主和 guest 渲染永远差半帧。

---

## 三、手搓动画总数统计

数一下上面 C/D 类里真正"手搓"的点：

| 类型 | 个数 |
|---|---|
| `performWithoutAnimation` 做瞬时跳变（mirror 三兄弟） | 3（#4 #5 #6） |
| 直接操作 CALayer 的 CA 动画（CASpringAnimation / CABasicAnimation） | 2（#9 #15） |
| `DispatchQueue.main.asyncAfter` / `dispatch_after` 伪时序（动画同步用，不含业务兜底） | 7（#3 #13 #14 #18 #22 + reduce-motion settle + re-cover 两次算一个 family） |
| z 序在动画块外瞬变 | 2（#7 #8） |
| 盖帧/揭帧节奏不对称（瞬盖淡揭） | 2（#26 #27） |
| 跨进程 scene 几何手动防抖 50ms | 1（#31） |
| 动画参数/时长不统一（B 类里偏手搓的） | 3（#1 damping=1.0、#2 双动画块、#36 瞬跳 1.18） |

**手搓动画点合计：约 20 处**（其中真正"直接违背 UIKit 动画引擎用法"的硬伤 14 处，其余是参数/时序不标准）。

---

## 四、最严重的 3 个问题（按对用户观感的破坏排序）

### 第 1 名：mirroring 分支整段 `performWithoutAnimation` 瞬移（#4/#5/#6，MultitaskDockView.swift:1184-1198）

- 用户点 swap 按钮时，四张卡片**啪一下从左边跳到右边**，没有飞行。这是最显眼的跳变。
- 跨进程 FBScene surface 在 frame 突变那一帧会撕裂，露容器纯黑底。作者用 swap cover（#14）挡，但 cover 盖的是上一帧 JPEG，和 surface 重连时机不对齐。
- 修法：把 mirror 也走 `UIView.animate spring`，只把 chrome/backdrop 用 performWithoutAnimation 冻结，corner mask 在 completion 里 snap。

### 第 2 名：swap 按钮 glyph 的 `CASpringAnimation(keyPath:"transform.rotation.y")`（#15，MultitaskDockView.swift:2394-2400）

- 直接操 CALayer，不走 UIKit 动画引擎。模型值从来没写过，动画播完 snap 回正面。
- 不可中断、不响应 Reduce Motion（外层虽然判了一次，但 CASpringAnimation 本身不读系统设置）、连点两次时两次翻转叠加视觉错乱。
- 修法：换成 `UIView.animate` 改 `swapButton.transform`，completion 里重置。

### 第 3 名：settle 后 0.35s 二次 commit + swap cover 0.6s 硬延时（#13 + #14）

- 全靠拍脑袋的固定延时去跟 iOS 19 的系统 layout 赛跑、跟跨进程 surface 重连赛跑。
- 快设备上白等、慢设备上没等够；用户在这 0.35s/0.6s 内做任何操作都会被 guard 丢掉或撞车。
- 修法：用 frame-ready Darwin 通知 + CADisplayLink 检测 hosting view frame 稳定，延时只做 backstop。

---

## 五、一句话结论

整个 MultitaskSupport 的动效**骨架是对的**——主布局走 `UIView.animate spring`、盖帧/揭帧走 `UIView.animate`、玻璃按钮按压走 spring，这些都是原生用法。问题集中在**三个边角**：
1. 左右翻转（mirror）整个分支被作者自己改成了瞬时跳变，放弃了弹簧；
2. 阴影路径和 swap 按钮翻转直接钻到 CALayer 手写 CABasic/CASpringAnimation；
3. 凡是"等跨进程事件"的地方，全用 `asyncAfter` 拍脑袋延时，而不是用 frame-ready 回调。

这三类加起来约 14 处硬伤，是黑闪、跳帧、翻转不顺滑的根因。
