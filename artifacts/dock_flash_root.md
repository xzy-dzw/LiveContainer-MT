# 快速换边 dock 闪烁 —— 从零逐行重查的根因与一次性修法

> 范围：`MultitaskSupport/MultitaskDockView.swift`（performLayout 全文）、`MultitaskStage.swift`（几何）、`VirtualWindowsHostView.m`、`DecoratedAppSceneViewController.m`、`AppSceneViewController.m`。
> 原则：只读不改，不猜。下面每条结论都标了"已确证"或"高度怀疑"。

---

## 0. 先把层级画清楚（这是后面所有判断的地基）

```
keyWindow (UIWindow)
├── rootViewController.view  (rootView)
│   └── rootView.subviews.first  (app 自己的容器)
│       └── windowHostingView  (VirtualWindowsHostView, bg = systemGray5 不透明)
│           ├── stageBackdrop  (黑 22%, frame=bounds, alpha=1)
│           ├── blockPlate      (黑 30%, 圆角, 始终 isHidden=true)
│           ├── shadowCaster × N (在 blockPlate 之上)
│           └── 卡片 view × N  (DecoratedAppSceneViewController.view, 最上)
├── zoomButton / swapButton / homeButton / closeButton / fpsCounter  (直接挂 keyWindow)
└── dockHost.view  (UIHostingController<AnyView>, 直接挂 keyWindow, 最前)
```

关键事实（已确证）：

- **dock 不在 windowHostingView 里**。dockHost.view 是 keyWindow 的直接子视图，windowHostingView 嵌在 rootViewController.view 里面。两者差了两层。dock 在 z 轴上天然就在 windowHostingView 之上，`bringSubviewToFront(dockView)` 只是在 keyWindow 的直接子视图之间排序。
- **dock 后面（被 .ultraThinMaterial / .glassEffect 采样到的内容）** = windowHostingView 的底部那条。windowHostingView 不透明灰底 + stageBackdrop 黑 22%。卡片块的底边正好顶到 dock 的顶边（几何见 `MultitaskStage.swift:70` 的 `available = height - top - bottom - controlsHeight - dockHeight`），卡片本身不压 dock。
- dock 的模糊采样到的就是一块**接近均匀的灰**，卡片只在 dock 顶边投下 ~22pt 的阴影（caster shadowRadius 16 + offset 6，`MultitaskDockView.swift:1316-1319`）。

---

## 1. 问题一：换边过程中有没有代码间接触发 dock 的 hosting view 重布局/重渲染？

### 1.1 performLayout 全文对 dock 做了什么（逐行）

performLayout = `MultitaskDockView.swift:937-1286`。mirroring=true 时，真正执行到的、跟 dock 相关的行：

| 行号 | 代码 | 执行情况 |
|---|---|---|
| 957-965 | `if dockView.superview !== window { addSubview; autoresizingMask=... }` | **no-op**（dock 早就挂在 keyWindow 上了，superview 没变） |
| 1009 | `windowHostingView.isHidden = isStageCollapsed` | 写死 false，与现值相同，no-op |
| 1010 | `stageBackdrop.isHidden = isStageCollapsed` | 同上，no-op |
| 1014 | `blockPlate.isHidden = true` | 已经是 true，no-op |
| 1015 | `dockHost?.view.isHidden = isStageCollapsed` | 写死 false，与现值相同，no-op |
| 1160-1165 | `dockView.isHidden/alpha/frame = ...` | **在 `update` 闭包里，mirroring 根本不调用 update**（见下） |
| 1282-1286 | `window.bringSubviewToFront(buttons/fpsCounter/dockView)` | **每次 performLayout 都执行，无条件** |

### 1.2 mirroring 分支到底跑了什么（1177-1220）

```swift
if mirroring {
    layoutToken &+= 1                       // 1182
    for app in apps { app.view.layer.maskedCorners = ... }   // 1187-1189，同步写，在动画块外
    for sideWindow { contentView.isUserInteractionEnabled = true }  // 1194-1196，同步写
    UIView.animate(spring 0.4s, [.beginFromCurrentState, .allowUserInteraction]) {
        for app in apps {
            app.view.frame = slotFrame(...)          // 1207
            windowShadowCasters[uuid]?.frame = ...   // 1208
        }
    } completion: { _ in
        guard layoutToken == token else { return }    // 1212
        for sideWindow { contentView.isUserInteractionEnabled = false }  // 1216-1218
        commitMainWindowGeometry()                    // 1219
    }
}
```

**动画块里只写了卡片和 shadow caster 的 frame，一个字都没碰 dock、stageBackdrop、blockPlate、按钮。**

### 1.3 关键：`update` 闭包在 mirroring 下根本不跑

`update`（1032-1175）里装着所有"平时"对 dock/backdrop/chrome 的写入：
- `backdropUpdates`（1087-1101）：`stageBackdrop.frame/alpha`、`blockPlate.frame/isHidden`
- `chromeUpdates`（1126-1166）：按钮 frame/alpha/isHidden，**以及 1160-1165 的 `dockView.isHidden/alpha/frame`**

但 `update` 只在三个分支被调用：
- 1225 `UIView.transition(... animations: update)`（Reduce Motion）
- 1254 `UIView.animate(... animations: update)`（普通 spring，非 mirroring）
- 1260 `update()`（无动画）

**mirroring 分支（1177）自己写了一个内联动画块，没有调 `update`。** 所以 mirroring 时 dockView.frame / dockView.alpha / dockView.isHidden **一行都没写**。1097-1101 和 1170-1174 那两个 `if mirroring { UIView.performWithoutAnimation(...) }` 是死代码——`update` 都不跑，里面的分支永远进不去。

这就是之前注释（1167-1169）说的"writing it inside the spring re-ran the SwiftUI dock hosting layout and faded the dock"——他们已经把 chromeUpdates 从 mirroring 路径里摘干净了。**这一步是做对了的。**

### 1.4 dock 的 SwiftUI rootView body 依赖什么

`MultitaskStageDockSwiftView`（2688-2709）：
- `@EnvironmentObject dockManager: MultitaskDockManager`
- `@ObservedObject sortManager = LCAppSortManager.shared`
- `@AppStorage("darkModeIcon")`

body 里只遍历 `sortManager.sortedApps`，**没有读 dockManager.apps / dockManager.isFullscreen**。`MultitaskDockManager` 是 ObservableObject，`@Published` 只有 `apps` 和 `isFullscreen`（653-654）。换边时这两个都不变 → **objectWillChange 不发 → SwiftUI body 不重算 → 图标不重新 layout**。

dock 的毛玻璃是 `MultitaskStageDockBackground`（2715-2749）：iOS 26 走 `.glassEffect(.regular, in: shape)`，老系统走 `.ultraThinMaterial`。这俩都是 UIVisualEffectView 系，实时采样下面的内容。

### 1.5 UIHostingController.view 什么时候会 relayout

dockView.bounds 没变（frame 没写），没人调 `setNeedsLayout`/`layoutIfNeeded` on dockView。autoresizingMask 只在首次挂载时设一次（964）。**正常情况下 mirroring 不触发 SwiftUI relayout。**

---

## 2. 问题二：快速连按时 layoutToken 门控会不会交错？

### 2.1 layoutToken 机制

- 类型 `UInt`（752）。
- mirroring 分支每次 `layoutToken &+= 1`（1182），抓快照 `token = layoutToken`。
- completion 第一行 `guard self.layoutToken == token else { return }`（1212）。
- 普通 spring 分支同理（1241-1242, 1256）。

### 2.2 连点两次的完整时序（t=0 第一次，t=0.2 第二次）

```
t=0.00  tap1: toggleLayoutHandedness
        isMirrored.toggle() → UserDefaults
        relayout → DispatchQueue.main.async
t=0.01  async 块跑 performLayout(mirroring:true)
          ├─ 1009-1015: isHidden 全是 no-op 写入
          ├─ 1182: layoutToken 0→1 (token=1)
          ├─ 1187: 卡片 maskedCorners 切成镜像边（同步，动画块外）
          ├─ 1194: 副窗 contentView.userInteractionEnabled = true
          ├─ 1197: UIView.animate spring 开始，卡片从 A 滑向 B
          └─ 1282: bringSubviewToFront(buttons → fpsCounter → dockView)
t=0.20  tap2: toggleLayoutHandedness
        isMirrored.toggle() → 又翻回去
        relayout → async
t=0.21  async 块跑 performLayout(mirroring:true)
          ├─ 1009-1015: isHidden no-op
          ├─ 1182: layoutToken 1→2 (token=2)   ← tap1 的 completion 被 guard
          ├─ 1187: 卡片 maskedCorners 切回原边（同步，动画块外）
          ├─ 1194: 副窗 userInteractionEnabled = true（已经是 true，no-op）
          ├─ 1197: 新 spring .beginFromCurrentState，卡片从当前中间位置滑回 A
          │         （这一步把 tap1 的动画打断）
          └─ 1282: bringSubviewToFront(buttons → fpsCounter → dockView)  ← 又排一遍
t=0.21+ε tap1 的动画被打断，completion 以 finished=false 回调
          └─ guard layoutToken(2) == token(1) 失败 → 直接 return
             ⚠️ 副窗 userInteractionEnabled 没有被恢复成 false
             ⚠️ commitMainWindowGeometry 没跑
t=0.61  tap2 的 spring 落地，completion 以 finished=true 回调
          └─ guard layoutToken(2) == token(2) 通过
             ├─ 副窗 userInteractionEnabled = false
             └─ commitMainWindowGeometry() → XPC 到 BackBoard
```

### 2.3 连点三次

t=0→T1, t=0.2→T2, t=0.4→T3。tap1/tap2 的 completion 都被 guard 掉，只有 T3 的 completion 跑一次 commit。**commit 永远只跑一次**（最后那个 token），不存在 commit 交错。

### 2.4 bringSubviewToFront 被调几次

每次 performLayout 末尾都无条件调（1282-1286）。连点 N 次就调 N 次。它在 keyWindow 上把 buttons、fpsCounter、dockView 重新排到最前。dockView 本来就在最前，但 UIKit 仍然会把 subviews 数组 remove+add 重排一遍。

### 2.5 commitMainWindowGeometry 做了什么

`1711-1716` → `AppSceneViewController.m:531-554`：
1. `updateFrameWithSettingsBlock:nil`  flush 一下
2. `scene updateSettingsWithBlock:` XPC 到 BackBoard，设 foreground=YES，写 hosting view 几何

这是一次真 XPC transaction。上一轮分析（artifacts/three_issues.md:119）已经定位：这个 XPC 会触发 UIKit 重跑 window 层级 layoutSubviews → UIHostingController.view layoutSubviews → SwiftUI 重新布局一次 → **UIVisualEffectView 的模糊在 relayout 那一帧短暂重置**。当前代码已经把它限制成只 commit 主窗（1213-1215 注释明说"pushing every window's geometry stacked XPC and reset the dock's live blur"），所以单次换边已经很轻了。

---

## 3. 问题三：dock 和 windowHostingView 的 z 序

已在第 0 节画清楚：
- windowHostingView 挂在 `rootView.subviews.first ?? rootView`（823），不在 keyWindow 上。
- dockHost.view 挂在 keyWindow 上（959）。
- 两者**不是兄弟**，dock 天然在 windowHostingView 之上。
- windowHostingView.backgroundColor = `systemGray5Color`（VirtualWindowsHostView.m:17），不透明。
- windowHostingView 在 mirroring 里 **alpha 不变、frame 不变、isHidden 不变**（1009 是 no-op）。
- rootView = `keyWindow.rootViewController.view`，就是 app 自己的 VC.view。

**换边时 windowHostingView.alpha 不变。** 它只在 entering（1017/1268）、dismiss（1731）、returnToLauncher（2416）、reenterStage（2455）这几个生命周期点被写，mirroring 不碰。

---

## 4. 问题四：blockPlate / stageBackdrop 在快速换边时有没有显隐/alpha 切换？

**没有。** 逐行确认：

- `stageBackdrop.isHidden`：mirroring 路径只在 1010 写一次 `= isStageCollapsed`（false，no-op）。1088/1091（frame/alpha）在 `update` 里，mirroring 不跑。
- `stageBackdrop.alpha`：mirroring 不写。
- `blockPlate.isHidden`：1014 写死 `= true`，mirroring 每次都写 true，但本来就是 true。1095 也是 true，在 update 里不跑。
- `blockPlate.frame`：1092 在 update 里，mirroring 不跑。blockPlate 本来就 hidden，frame 无所谓。

**dock 下面衬的东西在快速连按里没有任何一帧发生 alpha/hidden 切换。** agent-hint 里怀疑方向 (1) 和 (4) ——"下面衬的颜色在变"——**被逐行排除**。

---

## 5. 根因判断

### 5.1 已确证的事实

1. mirroring 路径里，dockView 的 frame / alpha / isHidden / transform **一行都没写**（chromeUpdates 在 update 里，mirroring 不调 update）。
2. dock 的 SwiftUI body 不依赖换边时变化的 state（apps/isFullscreen 不变），body 不重算。
3. windowHostingView / stageBackdrop / blockPlate 的 alpha / isHidden 在 mirroring 里全是 no-op 写入，没有任何视觉切换。
4. 卡片 frame 动画和 shadow caster frame 动画是唯一在动的东西，它们不压 dock。
5. **每次 performLayout 末尾（1282-1286）都会无条件 `window.bringSubviewToFront(dockView)`**，连点 N 次就排 N 次。
6. 最后一次动画落地时会跑一次 `commitMainWindowGeometry()` XPC（1219），这个 XPC 已知会触发 window layoutSubviews → UIHostingController relayout → 模糊短暂重置（artifacts/three_issues.md:119 的结论，与代码注释 1213-1215 互证）。

### 5.2 根因（高度怀疑，两因素叠加）

**dock 闪不是 dock 自己在闪，是 dock 身上那块 `.ultraThinMaterial` / `.glassEffect` 模糊表面在快速连按时被"重置采样"了。** 两个扳机：

**扳机 A（主因，单次也会有但单次不易察觉）：`bringSubviewToFront` 每次都跑。**
- 位置：`MultitaskDockView.swift:1282-1286`。
- 机制：UIVisualEffectView 系的 backdrop 是通过 render server 注册的一块 IOSurface 采样。当它所在的 window 的 subviews 数组被重排（bringSubviewToFront 哪怕把已经在最前的视图再排一次，UIKit 也会 remove+add 重写 subviews 数组），backdrop 的 layer tree 位置发生变化，render server 会 invalidate 当前采样、重新注册。重注册的 1-2 帧里，模糊表面会回退到一个 fallback 纹理（通常是上一帧或扁平灰），眼睛看到就是 dock 那条玻璃"闪一下"。
- 为什么单次换边不明显：单次 performLayout 在 t≈0 跑一次 bringSubviewToFront，那一下屏幕是静止的（卡片还没开始动），重采样的 1-2 帧落在静态画面上，人眼捕不到。
- 为什么快速连按明显：第二次 performLayout 在 t≈0.2 跑，这时卡片正在屏幕中间滑，用户视线正在跟踪运动，backdrop 又被 invalidate 一次、重采样 1-2 帧——这 1-2 帧正好叠在动效中间，玻璃条的模糊纹理突然跳一下，就是"闪"。

**扳机 B（次因，落在最后一次落地时）：`commitMainWindowGeometry()` 的 XPC。**
- 位置：`MultitaskDockView.swift:1219` → `AppSceneViewController.m:541-553`。
- 机制：这个 XPC 到 BackBoard 会触发 UIKit 在动画落地那一帧重跑一次 window layoutSubviews。UIHostingController.view 的 layoutSubviews 一跑，SwiftUI 重新布局一次，UIVisualEffectView 的 backdrop 在 relayout 时重置（上一轮 three_issues.md:119 已定位）。
- 单次换边：落地时闪一下，因为卡片刚停稳，用户注意力在卡片上，dock 那一下被容忍了。
- 快速连按：这个 XPC 永远只跑一次（被 layoutToken 门住），所以它不是"连按更多就闪更多"的来源，但它在最后一次落地那一帧仍然贡献一次重置——这是"最后一下还是能看到 dock 闪"的那一下。

### 5.3 已排除的怀疑方向

- ~~stageBackdrop / blockPlate / windowHostingView 的 alpha/hidden 在连按时切换~~：逐行确认 mirroring 不写它们（1087-1101 在 update 里，不跑）。
- ~~dockView.frame 被写导致 SwiftUI relayout~~：1164 在 update 里，mirroring 不跑。
- ~~SwiftUI body 因 @Published 变化重算~~：apps/isFullscreen 换边时不变。
- ~~commit 交错 / 多次 XPC~~：layoutToken 门住，最后一次只 commit 一次。
- ~~blockPlate 弹进弹出~~：1014 写死 hidden=true，mirroring 里它一直 hidden。

---

## 6. 一次性修到位方案

### 修法 1（必做，根治扳机 A）：mirroring 路径不要动 window 的 subview 顺序

**文件**：`MultitaskSupport/MultitaskDockView.swift`
**位置**：`performLayout` 末尾，1282-1286。

现在是：
```swift
allChromeButtons.forEach { window.bringSubviewToFront($0) }
window.bringSubviewToFront(fpsCounter)
if let dockView = dockHost?.view {
    window.bringSubviewToFront(dockView)
}
```

改成：**这一段只在"层级可能真的变了"的时候跑，mirroring 换边不跑。** mirroring 全程不 add/remove window 的任何直接子视图（卡片都在 windowHostingView 内部，不在 keyWindow 上），dock 和按钮的相对 z 序本来就稳定，根本不需要重排。

具体做法：把这三行挪出 mirroring 路径。最干净的写法是在 mirroring 分支末尾不要 fall through 到这里，或者加一个标志位：

```swift
// 在 performLayout 开头，mirroring 时记一个"层级不变"的标记
let hierarchyStable = mirroring

// ... 中间 mirroring 动画照跑 ...

if !hierarchyStable {
    allChromeButtons.forEach { window.bringSubviewToFront($0) }
    window.bringSubviewToFront(fpsCounter)
    if let dockView = dockHost?.view {
        window.bringSubviewToFront(dockView)
    }
}
```

**为什么这一改能根治**：
- mirroring 连按 N 次，window 的 subviews 数组一次都不被重写，dock 的 backdrop 采样不被 invalidate，扳机 A 消失。
- 非 mirroring 路径（首次进入、orientation、promote、fullscreen）该排还排，行为不变。

**会不会引入新问题**：
- mirroring 不排 z 序，dock 会不会被某个后来的视图压下去？mirroring 路径里 keyWindow 上没有 addSubview（卡片都在 windowHostingView 里，PiP layer 只在 keepAlivePiPEnabled 时 attach，且 attach 是幂等的），所以 dock 仍然在最前。安全。
- 如果担心，可以保留一次"幂等"排序：只在 `dockView.window?.subviews.last !== dockView` 时才 bringSubviewToFront。但这判断本身要遍历 subviews，不如直接按 mirroring 跳过干净。

### 修法 2（建议做，消除扳机 B）：mirroring 落地的 commit 不要在动画落地那一帧同步触发

**文件**：`MultitaskSupport/MultitaskDockView.swift:1211-1220`

现在 completion 里直接 `self.commitMainWindowGeometry()`。这一下 XPC 触发 window relayout，重置 dock 模糊。

mirroring 本来就不改变主窗的 size/scale/fullscreen（主窗只是从左滑到右，几何 key 完全一致，1643-1646 注释自己说的），**这个 commit 在 mirroring 里本来就是冗余的**。armGeometryCommitIfNeeded（1642-1651）明确说"mirror is deliberately NOT an arming change"——但 mirroring 分支的 completion 却又硬调了一次 commit（1219）。

改成：**mirroring 的 completion 里不要调 commitMainWindowGeometry**。副窗 interactive 恢复照跑（1216-1218），但 commit 删掉。

理由：
- mirroring 不改主窗几何，BackBoard 里的 scene settings 不需要更新。
- 删掉这一下 XPC，就不会在落地那一帧触发 window relayout → dock 模糊不再被重置。
- 触摸区域：mirroring 不改主窗的 size/position 路由（主窗还是那块屏幕，只是左右翻），guest 进程里的触摸隔离逻辑靠 `isMirrored` 这个 UserDefaults 自己算（MultitaskStageLayout.isMirrored），不靠 BackBoard region。

**验证一下风险**：如果删掉 mirroring completion 的 commit，主窗的触摸区域会不会错？看 `commitHostedGeometry`（AppSceneViewController.m:541-553）它写的是 `applyViewGeometryToSettings:`——把 hosting view 的 on-screen 位置写进 scene settings。mirroring 后主窗的 on-screen frame 确实变了（从左半屏到右半屏），这个 settings 不更新，BackBoard 的触摸 region 会不会停在旧位置？

——但注意：主窗在 mirroring 前后都是 3 单位宽，只是 x 翻了。guest 进程里的触摸隔离是靠 `UIKitHooks.m` 的 sendEvent hook + LCStageIPC，不是靠 BackBoard region（1213-1215 注释明说"side touches are quarantined in-guest"，主窗的触摸路由在 guest 进程内）。而且 armGeometryCommitIfNeeded 注释（1643-1646）明说 mirroring 不 arm commit，说明设计者本来就认为 mirroring 不需要推 geometry。1219 那一下 commit 是早期遗留、跟 1643 的结论自相矛盾。

如果实在担心触摸区域，可以折中：把 1219 的 commit 延后到 `asyncAfter 0.1`，让它跟动画落地帧错开，别在 completion 同步帧里跑。但首选是直接删——因为 size 不变，`updateFrameWithSettingsBlock` 在 size 不变时本身就是 no-op（artifacts/side_window_flash.md:230 已确认 `:357` guard）。

### 修法 3（可选，防御性）：mirroring 路径里 1009-1015 的 no-op 写入也包一下

现在每次 performLayout 都写 `windowHostingView.isHidden = isStageCollapsed` 等。虽然 UIKit 对同值写入会短路，但如果将来 isStageCollapsed 状态在连按中间被改，这些同步写入会在动画中途突然切 hidden，那才是真闪。

可以把 1009-1015 改成只在值变化时写：
```swift
if windowHostingView.isHidden != isStageCollapsed { windowHostingView.isHidden = isStageCollapsed }
if stageBackdrop.isHidden != isStageCollapsed { stageBackdrop.isHidden = isStageCollapsed }
if dockHost?.view.isHidden != isStageCollapsed { dockHost?.view.isHidden = isStageCollapsed }
// blockPlate 永远 hidden，照写就行
```
不是必须，但能防止未来回归。

---

## 7. 关键代码位置速查

| 作用 | 文件:行号 |
|---|---|
| performLayout 入口 | MultitaskDockView.swift:937 |
| dock 挂载 keyWindow + autoresizingMask | MultitaskDockView.swift:957-965 |
| isHidden 同步写入（mirroring 里 no-op） | MultitaskDockView.swift:1009-1015 |
| update 闭包（mirroring 不调用） | MultitaskDockView.swift:1032-1175 |
| chromeUpdates（含 dockView.frame/alpha） | MultitaskDockView.swift:1160-1165 |
| mirroring 分支入口 | MultitaskDockView.swift:1177 |
| layoutToken &+= 1 | MultitaskDockView.swift:1182 |
| maskedCorners 同步写（动画块外） | MultitaskDockView.swift:1187-1189 |
| 副窗 interactive=true | MultitaskDockView.swift:1194-1196 |
| mirroring spring 动画块（只动卡片/caster frame） | MultitaskDockView.swift:1197-1210 |
| mirroring completion（guard + 恢复 interactive + commit） | MultitaskDockView.swift:1211-1220 |
| **bringSubviewToFront 无条件链（扳机 A）** | MultitaskDockView.swift:1282-1286 |
| commitMainWindowGeometry | MultitaskDockView.swift:1711-1716 |
| commitHostedGeometry XPC（扳机 B） | AppSceneViewController.m:531-554 |
| toggleLayoutHandedness | MultitaskDockView.swift:2384-2403 |
| MultitaskStageDockSwiftView body | MultitaskDockView.swift:2688-2709 |
| dock 毛玻璃背景（.glassEffect/.ultraThinMaterial） | MultitaskDockView.swift:2715-2749 |
| windowHostingView 不透明灰底 | VirtualWindowsHostView.m:17 |
| stageBackdrop 黑 22% | MultitaskDockView.swift:829-832 |
| blockPlate 黑 30% 始终 hidden | MultitaskDockView.swift:836-841 |
| dockFrame 几何（顶到卡片底边） | MultitaskStage.swift:175-182 |
| available 几何（卡片块高度=可用区） | MultitaskStage.swift:70 |

---

## 8. 一句话总结

**dock 没被任何代码直接动过 frame/alpha/hidden——它看起来在闪，是因为身上的 `.ultraThinMaterial`/`.glassEffect` 模糊表面在快速连按时被两次误伤：(A) 每次 performLayout 末尾都无条件 `bringSubviewToFront(dockView)` 重排 window 的 subviews，让 backdrop 的 render server 采样在动画飞行中途被 invalidate 重注册；(B) 最后一次落地的 `commitMainWindowGeometry()` XPC 又触发一次 window relayout 重置模糊。修法就是 mirroring 路径别再排 z 序、别再调那个冗余 commit。**
