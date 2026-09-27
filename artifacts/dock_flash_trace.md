# 快速换边 dock 闪烁 —— 从零逐行重查的根因

> 范围：`MultitaskSupport/MultitaskDockView.swift`（当前 HEAD = `3f42597`，工作区干净）、`MultitaskStage.swift`、`DecoratedAppSceneViewController.m`、`AppSceneViewController.m`、`VirtualWindowsHostView.m`。
> 前提：用户已把 `bringSubviewToFront(dockView)` 包在 `if !mirroring` 里（commit `3f42597`），但 dock 闪依旧。下面每条结论都标"已确证"或"高度怀疑"。

---

## 0. 先把层级画清楚

```
keyWindow (UIWindow)
├── rootViewController.view  (app 自己的 VC.view)
│   └── rootView.subviews.first
│       └── windowHostingView  (VirtualWindowsHostView, bg = systemGray5 不透明)
│           ├── stageBackdrop  (黑 22%, frame=bounds)
│           ├── blockPlate     (黑 30%, 始终 hidden)
│           ├── shadowCaster × N
│           └── 卡片 view × N  (DecoratedAppSceneViewController.view, masksToBounds=YES)
├── zoomButton / swapButton / homeButton / closeButton / fpsCounter  (直接挂 keyWindow)
└── dockHost.view  (UIHostingController<AnyView>, 直接挂 keyWindow)
```

关键事实（已确证）：
- dockHost.view 是 keyWindow 的直接子视图，和 windowHostingView **不是兄弟**，dock 在 z 轴天然在 windowHostingView 之上。
- dock 的毛玻璃（`.glassEffect` / `.ultraThinMaterial`）采样到的是：rootViewController.view → windowHostingView（不透明灰）→ stageBackdrop（黑 22%）。卡片底边正好顶到 dock 顶边（`MultitaskStage.swift:70` 的 `available = height - top - bottom - controlsHeight - dockHeight`），卡片不压 dock。
- dock 后面衬的是一块**接近均匀的暗灰**，本来不该闪。

---

## 1. 问题一：swapButton tap 的完整调用链

### 1.1 swapButton 创建与绑定

`MultitaskDockView.swift:679-687`：

```swift
private lazy var swapButton: MultitaskStageGlassButton = {
    let button = MultitaskStageGlassButton(
        glyphImage: MultitaskStageSwapGlyph.makeImage(),
        pressedTint: nil
    )
    button.accessibilityLabel = "lc.multitask.toggleHandedness".loc
    button.addTarget(self, action: #selector(toggleLayoutHandedness), for: .touchUpInside)
    return button
}()
```

只有一个 target：`#selector(toggleLayoutHandedness)`，绑在 `.touchUpInside`。没有 `addAction`/`UIAction`。

### 1.2 toggleLayoutHandedness 全文（2392-2411）

```swift
@objc func toggleLayoutHandedness() {
    MultitaskStageLayout.isMirrored.toggle()          // 2393
    switchFeedback.impactOccurred()                  // 2394
    relayout(animated: true, mirroring: true)         // 2398 → async
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    swapFlipAngle += .pi                              // 2403
    UIView.animate(withDuration: 0.4, delay: 0,
                   usingSpringWithDamping: 1.0,
                   initialSpringVelocity: 0,
                   options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.swapButton.layer.transform = CATransform3DMakeRotation(self.swapFlipAngle, 0, 1, 0)  // 2409
    }
}
```

逐行副作用：

| 行号 | 代码 | 副作用 |
|---|---|---|
| 2393 | `MultitaskStageLayout.isMirrored.toggle()` | 写 `appGroupUserDefault` + `synchronize()`（`MultitaskStage.swift:43-49`）。**不是 @AppStorage、不是 @Published**，是普通 UserDefaults 计算属性。不触发任何 SwiftUI body 重算。 |
| 2394 | `switchFeedback.impactOccurred()` | 触觉反馈，不影响渲染。 |
| 2398 | `relayout(animated:true, mirroring:true)` | 进 931-935：`DispatchQueue.main.async { performLayout(...) }`。**异步跳到下一个 runloop**。 |
| 2403-2410 | swapButton.layer.transform 旋转动画 | **同步在 tap handler 里启动**，和上面的异步 performLayout 在不同 runloop turn。这是一个 3D Y 轴旋转，加在 swapButton 这个自带 UIVisualEffectView 玻璃的按钮上（见 §5）。 |

### 1.3 relayout → performLayout

`931-935`：

```swift
func relayout(animated: Bool, mirroring: Bool) {
    DispatchQueue.main.async {
        self.performLayout(animated: animated, mirroring: mirroring)
    }
}
```

performLayout 入口 `937`。从入口到 mirroring 分支（1177）之间跑的代码：

| 行号 | 代码 | mirroring 时执行情况 |
|---|---|---|
| 938 | `guard let window = keyWindow` | 通过 |
| 943-946 | buttons 重挂 keyWindow | no-op（早就挂了） |
| 947-950 | fpsCounter 重挂 | no-op |
| 954-956 | PiP attach | 默认关，跳过 |
| 957-965 | dockView 重挂 keyWindow | no-op（superview 已 === window） |
| 973 | `removeOrphanWindowViews()` | 遍历 windowHostingView.subviews，没有 add/remove 窗口，no-op |
| 975-993 | `guard count > 0` | count>0，跳过 dismiss 分支 |
| 996 | `entering = !isStagePresented` | false（已在舞台） |
| 1006 | `isStagePresented = true` | 已 true，no-op |
| 1009-1015 | `windowHostingView/stageBackdrop/blockPlate/dockHost.view.isHidden = ...` | 全是同值写入，UIKit 短路 |
| 1016-1019 | entering 时 alpha=0 | entering=false，跳过 |
| 1025-1030 | shadowPathDuration / deferCornerMasks | 算变量，无副作用 |
| 1032-1175 | `update` 闭包定义 | **mirroring 不调用 update**（见 §2） |

### 1.4 完整调用链图

```
touchUpInside on swapButton
  └─ toggleLayoutHandedness()                          [2392, main thread, sync]
       ├─ isMirrored.toggle() → UserDefaults.set+synchronize  [2393, 同步磁盘写]
       ├─ switchFeedback.impactOccurred()                    [2394, 触觉]
       ├─ relayout(animated:true, mirroring:true)
       │    └─ DispatchQueue.main.async { performLayout }     [931-935, 下一个 runloop]
       └─ UIView.animate spring: swapButton.layer.transform  [2404-2410, 同步启动]
            │
            ↓ 下一个 runloop turn
       performLayout(animated:true, mirroring:true)            [937]
            ├─ 943-965  mount 检查（no-op）
            ├─ 973      removeOrphanWindowViews（no-op）
            ├─ 1009-1015 isHidden 同值写（no-op）
            ├─ 1182     layoutToken &+= 1
            ├─ 1187-1189 card.layer.maskedCorners = ... （同步，动画块外）
            ├─ 1194-1196 side contentView.isUserInteractionEnabled = true
            ├─ 1197-1210 UIView.animate spring: card.frame + caster.frame
            ├─ 1288-1294 if !mirroring { bringSubviewToFront(...) }  ← 已跳过
            └─ 1298      publishStageRoles(active:true)  ← 1s 内去重，no-op
                 │
                 ↓ 0.4s 后动画落地（只有最后一个 token 的 completion 跑）
            completion:
                 ├─ guard layoutToken == token
                 ├─ side contentView.isUserInteractionEnabled = false
                 └─ commitMainWindowGeometry()  → XPC 到 BackBoard  [1219]
```

---

## 2. 问题二：mirroring=true 时 performLayout 跑了哪些"刷新"动作

逐行过 performLayout 全文（937-1299），mirroring=true 时**实际执行到的、有副作用的行**：

### 2.1 动画块外（同步执行）

| 行号 | 代码 | 是否碰 dock |
|---|---|---|
| 1182 | `layoutToken &+= 1` | 纯计数器 |
| 1187-1189 | `app.view.layer.maskedCorners = MultitaskStageLayout.maskedCorners(...)` | 写卡片 layer 的圆角掩码，在 windowHostingView 内部，不直接碰 dock |
| 1194-1196 | 副窗 `contentView.isUserInteractionEnabled = true` | 改远程 surface 的渲染模式（注释说让 render server 把 surface 当 live 追踪），不直接碰 dock |

### 2.2 动画块内（1197-1210）

```swift
UIView.animate(... animations: {
    for app in apps {
        view.frame = slotFrame(...)          // 1207
        self.windowShadowCasters[uuid]?.frame = frame   // 1208
    }
})
```

**只动卡片和阴影 caster 的 frame。一个字都没碰 dock、stageBackdrop、blockPlate、按钮。**

### 2.3 动画块后（1263-1298）

| 行号 | 代码 | mirroring 时 |
|---|---|---|
| 1263-1280 | `if entering { ... dockHost.view.alpha = 0 ... }` | entering=false，跳过 |
| 1288-1294 | `if !mirroring { bringSubviewToFront(...) }` | **已跳过**（用户的修复） |
| 1298 | `publishStageRoles(active: true)` | 进去后 `publishRolesIfChanged` 检查：`last.active==true && last.uuid==mainUUID && <1s` → **直接 return，不发 Darwin 通知** |

### 2.4 completion（1211-1220）

```swift
guard layoutToken == token else { return }
for side windows { contentView.isUserInteractionEnabled = false }
self.commitMainWindowGeometry()
```

- 不调 relayout / performLayout / setNeedsLayout。
- `commitMainWindowGeometry()`（1719-1724）→ `AppSceneViewController.m:531-554` `commitHostedGeometry`：
  1. `updateFrameWithSettingsBlock:nil` — size 不变时 no-op（`:357` guard）。
  2. `scene updateSettingsWithBlock:` — **真 XPC 到 BackBoard**，设 `foreground=YES`、`deactivationReasons=0`，iOS 19+ 调 `applyViewGeometryToSettings:` 把 hosting view 屏幕位置写进 scene settings。

### 2.5 明确排除的"刷新"动作

- **没有**重新创建 window / rootView / windowHostingView。
- **没有** `dockHost.rootView = ...` 重新赋值（rootView 只在 `setupDockView` 908-910 赋过一次，全文再无第二次）。
- **没有** `dockManager.objectWillChange.send()`。
- **没有**写 `@AppStorage("darkModeIcon")` 或任何 dock body 依赖的 key。
- **没有**改 `dockHost.view.backgroundColor / alpha / hidden / frame`（1160-1165 在 `update` 里，mirroring 不跑 update）。
- **没有**改 `stageBackdrop / blockPlate` 的 alpha / hidden / frame（1087-1101 在 `update` 里，mirroring 不跑）。
- **没有**改 `rootView` 的 alpha / hidden / frame。
- **没有** `layoutIfNeeded / setNeedsLayout / setNeedsDisplay`（全文 grep 零命中）。
- **没有** `CATransaction`（1344-1347 在 shadowCaster 里，shadowCaster 在 update 里，mirroring 不跑）。
- `removeOrphanWindowViews`（973/1589）：遍历 windowHostingView.subviews，没有 add/remove 窗口，零移除。
- `watchdogTick`（1601）：1 秒定时器，不是每次 tap 触发。

---

## 3. 问题三：dockHost 的 SwiftUI body 依赖什么

### 3.1 MultitaskStageDockSwiftView（2696-2717）

```swift
struct MultitaskStageDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @ObservedObject var sortManager = LCAppSortManager.shared
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(sortManager.sortedApps, id: \.self) { app in
                    MultitaskStageDockIcon(app: app, darkModeIcon: darkModeIcon) {
                        dockManager.stageDockTapped(app)
                    }
                }
            }
        }
        .modifier(MultitaskStageDockBackground())
    }
}
```

### 3.2 这些依赖在 mirroring 时变没变

| 依赖 | mirroring 时变吗 |
|---|---|
| `dockManager.apps`（@Published, 653） | 不变（不增删窗口） |
| `dockManager.isFullscreen`（@Published, 654） | 不变 |
| `sortManager.sortedApps`（@Published, LCAppSortManager.swift:79） | 不变（不重排） |
| `darkModeIcon`（@AppStorage） | 不变（不写） |
| `MultitaskStageLayout.isMirrored` | 是普通 UserDefaults 计算属性（`MultitaskStage.swift:43-49`），**不是 @AppStorage**，dock body 也没读它 |

结论：**dock body 在 mirroring 时不重算，objectWillChange 不发，图标不重新 layout。**

### 3.3 dockHost.rootView 有没有被重新赋值

全文 grep `rootView =` / `dockHost.rootView`：只有 908-910 一次赋值。mirroring 路径**零次**。UIHostingController.rootView 不重新赋值，SwiftUI 就不会做完整重渲染。

### 3.4 dock 的毛玻璃

`MultitaskStageDockBackground`（2723-2757）：iOS 26 走 `.glassEffect(.regular, in: shape)`，老系统走 `.ultraThinMaterial`。两者都是 UIVisualEffectView 系，实时采样下面的内容。

---

## 4. 问题四：bringSubviewToFront 改动是否生效，有没有别处再排 z 序

### 4.1 用户的修复已生效

`1288-1294`：

```swift
if !mirroring {
    allChromeButtons.forEach { window.bringSubviewToFront($0) }
    window.bringSubviewToFront(fpsCounter)
    if let dockView = dockHost?.view {
        window.bringSubviewToFront(dockView)
    }
}
```

确认在。mirroring 时这三行全部跳过。

### 4.2 全文所有 z 序操作

| 行号 | 代码 | mirroring 时跑吗 |
|---|---|---|
| 1076 | `windowHostingView.bringSubviewToFront(view)`（卡片） | 在 `update` 里，**不跑** |
| 1079 | `windowHostingView.sendSubviewToBack(stageBackdrop)` | 在 `update` 里，**不跑** |
| 1081 | `windowHostingView.insertSubview(blockPlate, aboveSubview: stageBackdrop)` | 在 `update` 里，**不跑** |
| 1289-1292 | `window.bringSubviewToFront(buttons/fps/dockView)` | `if !mirroring`，**跳过** |
| 1329 | `windowHostingView.insertSubview(caster, aboveSubview: blockPlate)` | 在 `shadowCaster()` 里，被 `update` 调用，**不跑** |

**mirroring 路径里，window 和 windowHostingView 的 subviews 数组一次都不被重写。** 没有 windowDidUpdate / sceneDidActivate 回调重排 z 序。

---

## 5. 问题五：快速连按时 layoutToken 门控

### 5.1 时序（tap1=t=0, tap2=t=0.2s）

```
t=0.00  tap1: toggleLayoutHandedness
        isMirrored.toggle() → UserDefaults
        switchFeedback.impactOccurred()
        relayout → async 入队
        swapButton 旋转动画 A 启动（同步）
t=0.01  async: performLayout(mirroring:true)
          ├─ 1182 layoutToken 0→1 (token=1)
          ├─ 1187 maskedCorners 切成镜像边（同步）
          ├─ 1194 副窗 interactive=true
          ├─ 1197 卡片弹簧动画 A 启动
          └─ 1298 publishStageRoles（1s 内去重，no-op）
t=0.20  tap2: toggleLayoutHandedness
        isMirrored.toggle() → 翻回去
        relayout → async 入队
        swapButton 旋转动画 B 启动（.beginFromCurrentState，打断 A）
t=0.21  async: performLayout(mirroring:true)
          ├─ 1182 layoutToken 1→2 (token=2)   ← tap1 的 completion 稍后被 guard
          ├─ 1187 maskedCorners 切回原边（同步）
          ├─ 1194 副窗 interactive=true（已 true，no-op）
          ├─ 1197 卡片弹簧动画 B 启动（.beginFromCurrentState，打断 A）
          └─ 1298 publishStageRoles（仍在 1s 内，no-op）
t=0.21+ε tap1 卡片动画 A 被打断，completion finished=false
          └─ guard layoutToken(2) == token(1) 失败 → 直接 return
             ⚠️ 副窗 interactive 没被恢复成 false（但下一次 performLayout 又会设 true，幂等）
             ⚠️ commitMainWindowGeometry 没跑
t=0.61  tap2 卡片动画 B 落地，completion finished=true
          └─ guard layoutToken(2) == token(2) 通过
             ├─ 副窗 interactive=false
             └─ commitMainWindowGeometry() → XPC 到 BackBoard
```

### 5.2 completion 里有没有再触发 layout

没有。completion 只做三件事：恢复副窗 interactive、commitMainWindowGeometry。不调 relayout / performLayout / setNeedsLayout。

### 5.3 被 guard 掉的 completion

tap1 的 completion（finished=false）直接 return，副窗 interactive 停在 true。但 tap2 的 performLayout 在 1194 又设一次 true（幂等），最后 tap2 completion 设回 false。最终状态一致。

### 5.4 .beginFromCurrentState 跳变

新动画从 presentation value 开始，不会跳。卡片位置连续。

---

## 6. 根因判断

### 6.1 已确证的事实

1. **dock 自己没被任何代码动过**：dockHost.view 的 frame / alpha / isHidden / transform 在 mirroring 路径里一行都没写（1160-1165 在 `update` 里，mirroring 不调 update）。
2. **dock SwiftUI body 不重算**：dockManager.apps / isFullscreen 不变，sortManager.sortedApps 不变，darkModeIcon 不写。objectWillChange 不发。
3. **dockHost.rootView 不重新赋值**：只在 908-910 赋过一次。
4. **z 序不重排**：用户的 `if !mirroring` 修复已生效，window.subviews 数组在 mirroring 里零改写。
5. **publishStageRoles 是 no-op**：1s 去重窗口内，tap 不发 Darwin 通知。
6. **windowHostingView / stageBackdrop / blockPlate 的 alpha / isHidden 全是同值写入**（1009-1015），UIKit 短路。

### 6.2 那 dock 为什么还闪？

dock 看起来在闪，不是 dock 自己变了，是 dock 身上那块 `.glassEffect` / `.ultraThinMaterial` 模糊表面被**render server 重置了采样**。已确证的直接触发 dock 玻璃重置的动作只剩两个：

#### 扳机 C（高度怀疑，每次 tap 都跑）：swapButton 的 3D 旋转动画

位置：`MultitaskDockView.swift:2404-2410`。

```swift
UIView.animate(... options: [.beginFromCurrentState, .allowUserInteraction]) {
    self.swapButton.layer.transform = CATransform3DMakeRotation(self.swapFlipAngle, 0, 1, 0)
}
```

机制：
- `swapButton` 是 `MultitaskStageGlassButton`，它内部嵌了一个 `UIVisualEffectView` 玻璃（`MultitaskStage.swift:339,408`：`glass.effect = UIBlurEffect(style: .systemUltraThinMaterial)`，iOS 26 走 `UIGlassEffect`）。
- **UIVisualEffectView / UIGlassEffect 在祖先层带 3D transform（尤其 Y 轴旋转）时，渲染会异常**——blur 是屏幕空间采样的，3D transform 会让 render server 重新计算 backdrop filter 的几何。
- 快速连按时，这个 0.4s 弹簧被 `.beginFromCurrentState` 打断 N 次、重启 N 次。每一次重启都让 render server 重算一次 window 的 backdrop context。
- 同一 window 里的所有 effect view（包括底部 dock 的 `.glassEffect`）共享 window 级 backdrop 渲染上下文——一个 effect view 的 3D 变换重置，会波及同 window 其他 effect view 的采样。
- 为什么单次换边不明显：单次 tap，旋转动画只启动一次，那一下屏幕是静态的，重采样 1-2 帧落在静态画面上捕不到。
- 为什么快速连按明显：每 tap 一次就重启一次 3D 旋转动画，重采样叠在卡片滑动的动效中间，dock 玻璃条的模糊纹理突然跳一下。

**这是上一版分析（dock_flash_root.md）完全没覆盖到的角度**——上一版只盯着 performLayout 里的 z 序，没看 tap handler 里同步启动的 swapButton 3D 动画。

#### 扳机 D（已确证，每次 burst 末尾跑一次）：commitMainWindowGeometry XPC

位置：`MultitaskDockView.swift:1219` → `AppSceneViewController.m:531-554`。

机制：
- 最后一个 token 的 completion 里调 `commitMainWindowGeometry()`，做一次真 XPC 到 BackBoard（`updateSettingsWithBlock:` + `applyViewGeometryToSettings:`）。
- 这个 XPC 会触发 UIKit 在落地那一帧重跑一次 window 层级 layoutSubviews → UIHostingController.view layoutSubviews → SwiftUI 重新布局一次 → UIVisualEffectView 模糊短暂重置。
- 注意：`armGeometryCommitIfNeeded`（1650-1659）的注释明说"a left/right mirror is deliberately NOT an arming change... re-pushing scene settings would only force a cross-process surface reconnect — exactly the black flicker the mirror used to produce"。**但 mirroring completion 1219 却又硬调了一次 commit，跟 1651-1654 的设计意图自相矛盾。**
- 这个只在 burst 末尾跑一次，不是"每 tap 闪一下"的来源，但它是"最后一下还能看到 dock 闪"的那一下。

### 6.3 已排除的怀疑方向

- ~~`isMirrored.toggle()` 写 UserDefaults 触发 @AppStorage 重算~~：isMirrored 是普通 UserDefaults 计算属性，不是 @AppStorage；dock body 也没读它。
- ~~`dockHost.rootView` 重新赋值~~：全文只赋一次。
- ~~`dockManager.apps / isFullscreen` @Published 变化~~：mirroring 不增删窗口、不全屏切换。
- ~~`publishStageRoles` 发 Darwin 通知让 guest 重渲染~~：1s 去重窗口内 no-op；而且 Darwin 通知只唤醒 guest 进程，不回 host。
- ~~stageBackdrop / blockPlate 的 alpha/hidden 切换~~：在 `update` 里，mirroring 不跑。
- ~~blockPlate 弹进弹出~~：1014 写死 hidden=true。
- ~~bringSubviewToFront~~：已包在 `if !mirroring` 里。

---

## 7. 改法（落到行号）

### 改法 1（必做，治扳机 C）：swapButton 别再用 3D layer transform

**文件**：`MultitaskSupport/MultitaskDockView.swift:2403-2410`

现在是：
```swift
swapFlipAngle += .pi
UIView.animate(withDuration: 0.4, delay: 0,
               usingSpringWithDamping: 1.0,
               initialSpringVelocity: 0,
               options: [.beginFromCurrentState, .allowUserInteraction]) {
    self.swapButton.layer.transform = CATransform3DMakeRotation(self.swapFlipAngle, 0, 1, 0)
}
```

问题：`swapButton.layer.transform` 是 3D 旋转，按钮内部嵌了 UIVisualEffectView 玻璃，3D transform 让 render server 重算 backdrop。

改法：**不要动 layer.transform，改成 2D flip 或直接换 glyph 图片**。最干净的写法是用 `swapButton.glyph`（UIImageView，`MultitaskStage.swift:341`）的 `transform` 做 2D 翻转，或者直接在镜像切换时换一张左右翻转的 glyph 图片：

```swift
// 方案 A：只旋转内部 glyph 图片（不碰按钮自身 layer，不影响 UIVisualEffectView）
UIView.transition(with: swapButton, duration: 0.25,
                  options: [.transitionFlipFromLeft, .allowUserInteraction]) {
    // 换一张翻转后的 glyph image，或者直接 swapButton.glyph.transform = .init(scaleX: -1, y: 1)
}
```

或者更简单：**把 swapFlipAngle 的 3D 旋转整个删掉**，换边时 glyph 不转（glyph 本来就是双向箭头，转不转用户感知不强）。这是最小改动。

为什么这一改能治：
- swapButton.layer.transform 不再带 3D 旋转，按钮里的 UIVisualEffectView 不再被 3D 变换波及。
- render server 不再每次 tap 都重算 window backdrop，dock 玻璃不被误伤。

### 改法 2（建议做，治扳机 D）：mirroring completion 里别再调 commitMainWindowGeometry

**文件**：`MultitaskSupport/MultitaskDockView.swift:1219`

现在是：
```swift
} { [weak self] _ in
    guard let self, self.layoutToken == token else { return }
    for side windows { ... interactive = false }
    self.commitMainWindowGeometry()   // ← 这行
}
```

改成：删掉 `self.commitMainWindowGeometry()`。

理由：
- `armGeometryCommitIfNeeded`（1650-1659）注释明说 mirror 不该 arm commit，因为 geometry key（size/scale/fullscreen）不变。
- 主窗触摸区域：side touches 在 guest 进程内被吞（UIKitHooks.m sendEvent hook），主窗触摸路由不依赖 BackBoard region（1213-1215 注释自己说的）。
- 删掉这一下 XPC，落地那一帧不再触发 window relayout，dock 玻璃不再被重置一次。

如果担心触摸区域：折中是把 1219 的 commit 延后到 `asyncAfter 0.15`，跟动画落地帧错开。但首选是直接删。

### 改法 3（可选，防御）：1009-1015 的同值写也包一下

现在每次 performLayout 都写 `windowHostingView.isHidden = isStageCollapsed` 等。虽然 UIKit 短路，但如果将来状态在连按中间被改，同步写入会在动画中途突然切 hidden。改成只在值变化时写：

```swift
if windowHostingView.isHidden != isStageCollapsed { windowHostingView.isHidden = isStageCollapsed }
if stageBackdrop.isHidden != isStageCollapsed { stageBackdrop.isHidden = isStageCollapsed }
if dockHost?.view.isHidden != isStageCollapsed { dockHost?.view.isHidden = isStageCollapsed }
```

不是必须，但防回归。

---

## 8. 关键代码位置速查

| 作用 | 文件:行号 |
|---|---|
| swapButton 创建 + addTarget | MultitaskDockView.swift:679-687 |
| toggleLayoutHandedness 全文 | MultitaskDockView.swift:2392-2411 |
| **swapButton 3D 旋转动画（扳机 C）** | MultitaskDockView.swift:2403-2410 |
| relayout → async performLayout | MultitaskDockView.swift:931-935 |
| performLayout 入口 | MultitaskDockView.swift:937 |
| isHidden 同值写（mirroring no-op） | MultitaskDockView.swift:1009-1015 |
| update 闭包（mirroring 不调用） | MultitaskDockView.swift:1032-1175 |
| chromeUpdates（含 dockView.frame/alpha） | MultitaskDockView.swift:1160-1165 |
| mirroring 分支入口 | MultitaskDockView.swift:1177 |
| layoutToken &+= 1 | MultitaskDockView.swift:1182 |
| maskedCorners 同步写（动画块外） | MultitaskDockView.swift:1187-1189 |
| 副窗 interactive=true | MultitaskDockView.swift:1194-1196 |
| mirroring 弹簧动画块（只动卡片/caster frame） | MultitaskDockView.swift:1197-1210 |
| mirroring completion（guard + 恢复 interactive + commit） | MultitaskDockView.swift:1211-1220 |
| **commitMainWindowGeometry XPC（扳机 D）** | MultitaskDockView.swift:1219 |
| bringSubviewToFront 已包 if !mirroring | MultitaskDockView.swift:1288-1294 |
| publishStageRoles（1s 去重） | MultitaskDockView.swift:1298 → 1386-1395 |
| commitMainWindowGeometry 实现 | MultitaskDockView.swift:1719-1724 |
| commitHostedGeometry XPC | AppSceneViewController.m:531-554 |
| isMirrored 定义（普通 UserDefaults，非 @AppStorage） | MultitaskStage.swift:43-49 |
| dockHost.rootView 唯一赋值 | MultitaskDockView.swift:908-910 |
| MultitaskStageDockSwiftView body | MultitaskDockView.swift:2696-2717 |
| dock 毛玻璃（.glassEffect/.ultraThinMaterial） | MultitaskDockView.swift:2723-2757 |
| MultitaskDockManager @Published | MultitaskDockView.swift:653-654 |
| swapButton 内嵌 UIVisualEffectView 玻璃 | MultitaskStage.swift:339, 388-411 |
| armGeometryCommitIfNeeded（mirror 故意不 arm） | MultitaskDockView.swift:1650-1659 |

---

## 9. 一句话总结

**dock 没被任何代码直接动过 frame/alpha/hidden——它看起来在闪，是因为身上的 `.glassEffect` 模糊表面在快速连按时被 render server 误伤：(C) tap handler 里同步启动的 `swapButton.layer.transform` 3D Y 轴旋转动画（2404-2410），每 tap 一次就重启一次，按钮内部嵌的 UIVisualEffectView 被 3D 变换波及，连带同 window 里 dock 的玻璃 backdrop 重采样；(D) burst 末尾 completion 里那一下冗余的 `commitMainWindowGeometry()` XPC（1219）又触发一次 window relayout。上一版只修了 bringSubviewToFront（z 序重排），没碰这两个。修法：swapButton 别用 3D layer transform（改 2D glyph 翻转或干脆不转），mirroring completion 删掉那次冗余 commit。**
