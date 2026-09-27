# 换边弹簧动画后三个问题的深查报告

> 只读代码分析，未改仓库。锚定文件:行号。

---

## 问题 1：副窗竖列 + dock 栏换边时仍快速闪一下

### 1a. 副窗为什么闪？

#### 上一轮假设为什么被推翻

上一轮（`artifacts/side_window_flash.md`）的结论是"副窗缺落地那次 geometry commit"，建议对所有窗口都调 `commitHostedGeometry()`。用户实测：对所有窗口 commit 后，副窗闪**没变化**。说明根因不在 geometry commit。

代码证据：`AppSceneViewController.m:531-554` 的 `commitHostedGeometry` 里，真正有副作用的只有 `applyViewGeometryToSettings:`（iOS 19+，把 hosting view 的 on-screen 几何写进 BackBoard settings）。这步只影响触摸区域路由，不影响 surface 渲染位置。注释 `:529-530` 本来就说"Side windows never need this"——副窗触摸在 guest 进程内被吞（`UIKitHooks.m:97-163` 的 sendEvent hook），不走 BackBoard touch region。所以多推这一次 XPC 对副窗渲染毫无影响，闪不闪都跟它无关。

#### 已排除的方向（都有代码证据）

| 方向 | 排除理由 |
|---|---|
| 副窗被后台/挂起/节流 | `AppSceneViewController.m:149` 所有窗口 `foreground=YES`；`DecoratedAppSceneViewController.m:530-534` 注释明确"Never background the side scenes"。无 `deactivationReasons` 写入、无 suspend/pause/throttle 逻辑。 |
| tapShield 遮挡或 frame 不跟随 | `DecoratedAppSceneViewController.m:107-117`：tapShield 是 autolayout 撑满 container（`translatesAutoresizingMaskIntoConstraints=NO`，四边约束到 container），`backgroundColor=clearColor` 完全透明。container 平移时 tapShield 作为 subview 跟着走，不会落地后才跳。 |
| launchPlaceholder / frozenFrameView 显隐 | 正常运行时 `hidden=YES`（`:110, :139, :157`），mirroring 分支完全不碰它们。 |
| scene settings 主副窗有差异 | `AppSceneViewController.m:145-159`：所有窗口的 `foreground=YES`、`level=1`、`displayConfiguration` 相同，无差异。 |
| z 序变化 | mirroring 分支不跑 `update` 闭包，不做 `bringSubviewToFront`，apps 数组顺序不变。 |
| corner mask 切换闪 | completion 里对主副窗一视同仁（`:1203-1204`），主窗不闪所以不是它。 |
| commitHostedGeometry 缺失 | 用户实测加了没变化。 |

#### 根因判断（高度怀疑）

**主窗和副窗在弹簧动画里做的事完全一样**——动画块里只写 `view.frame = frame`（`MultitaskDockView.swift:1197`），主副窗一视同仁。但主窗不闪、副窗闪。唯一的实质区别是：

```
DecoratedAppSceneViewController.m:335-348
BOOL interact = isMainWindow;   // 主窗=YES，副窗=NO
self.appSceneVC.contentView.userInteractionEnabled = interact;
self.appSceneVC.hostingController.sceneView.userInteractionEnabled = interact;
```

副窗的 `contentView`（就是 `_UISceneHostingView`，`AppSceneViewController.m:177`）和 `sceneView` 的 `userInteractionEnabled=NO`。

**高度怀疑**：在 iOS 的 scene hosting 架构里，`userInteractionEnabled=NO` 的 hosting view 被 render server 视为"非活跃表面"。主窗因为 `userInteractionEnabled=YES`，它的 layer position 每帧被 render server 采样追踪，surface 连续滑过去。副窗因为 `userInteractionEnabled=NO`，render server 可能不对它做逐帧 position 采样——动画过程中 surface 停在旧槽位的最后一帧缓存上，动画落地后系统在下一个 surface 同步周期才把 surface 拉到新槽位。**这一拉就是"快速闪一下"。**

这解释了为什么：
- 主窗不闪（活跃表面，连续追踪）。
- 副窗闪（非活跃表面，不连续追踪，落地后一次性跳）。
- 加 `commitHostedGeometry` 没变化（commit 只写触摸区域 settings，不改变 render server 对 surface position 的采样策略）。

**为什么不能 100% 确证**：`_UISceneHostingView` 是私有 API，它内部对 `userInteractionEnabled` 的处理是黑盒。但主副窗在动画块里做的事完全一样、唯一区别就是 `userInteractionEnabled`，这个区别是最合理的归因。

#### 改法

在 mirroring 弹簧动画**开始前**，临时把所有副窗的 `contentView.userInteractionEnabled` 和 `sceneView.userInteractionEnabled` 设为 `YES`（让 render server 把它们当活跃表面逐帧追踪），动画**落地后**再恢复为 `NO`。

具体位置：`MultitaskDockView.swift:1184` 附近（mirroring 分支，`layoutToken &+= 1` 之后、`UIView.animate` 之前）。

```swift
if mirroring {
    deferCornerMasks = true
    layoutToken &+= 1
    let token = layoutToken

    // ★ 新增：飞行期间把所有窗口临时当活跃表面，让 render server
    //   逐帧追踪副窗的 surface position，避免落地时一次性跳变闪一下。
    for app in self.apps {
        (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
            .appSceneVC.beginMirrorFlight()   // 新增方法：contentView.userInteractionEnabled=YES
    }

    UIView.animate(... animations: {
        // ... 现有 frame 动画 ...
    }) { [weak self] _ in
        // ★ 恢复
        for app in self.apps {
            (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
                .appSceneVC.endMirrorFlight() // 新增方法：恢复原 interact 值
        }
        // ... 现有 maskedCorners + commit ...
    }
}
```

`beginMirrorFlight` / `endMirrorFlight` 在 `AppSceneViewController.m` 里加：
- `beginMirrorFlight`：`self.contentView.userInteractionEnabled = YES; self.hostingController.sceneView.userInteractionEnabled = YES;`
- `endMirrorFlight`：恢复为 `self.appSceneVC.view.userInteractionEnabled` 对应的原始值（主窗本来就是 YES，副窗恢复 NO）。

#### 风险

- 飞行 0.4s 内副窗临时可交互。但换边是点 swap 按钮触发的，手指已经离开屏幕，0.4s 内误触概率极低。且 `.allowUserInteraction` 动画本来就允许中途交互。
- 如果 `userInteractionEnabled=YES` 不是 surface 采样的决定因素（黑盒里可能是别的开关），这个改法无效——那就需要 hook `_UISceneHostingView` 的 `willMoveToWindow:` / `layoutSubviews` 加日志，观测飞行中 surface 有没有真的在逐帧更新。

---

### 1b. dock 为什么闪？

#### 层级关系（已确证）

- `dockHost.view` 被 addSubview 到 **keyWindow**（`MultitaskDockView.swift:957-959`），不在 `windowHostingView` 里。
- 卡片（container views）在 `windowHostingView`（`VirtualWindowsHostView`，灰底）里，`windowHostingView` 被 addSubview 到 rootView（`:823`）。
- dock 和 windowHostingView 是平级兄弟（都在 keyWindow 层级里）。
- dock.frame = `dockFrame(bounds, safeArea)`（`:175-182`），**不依赖 isMirrored**——dock 在底部居中，换边前后 frame 一样。
- dock.autoresizingMask = `[.flexibleWidth, .flexibleTopMargin]`（`:964`）。window.bounds 不变时 autoresizing 不做事。

#### 已排除

- mirroring 分支跳过了 `chromeUpdates`（`:1170-1171` 用 `performWithoutAnimation` 冻结，实际上连调都没调——mirroring 分支根本不进 `update` 闭包），所以 dock.frame/alpha 没被重写。dock 不该动。
- dock.alpha 在 mirroring 时不变（`:1015, :1018` 只在 entering/collapsed 时改）。
- dock 不在 windowHostingView 里，卡片移动不该直接影响它。

#### 根因判断（高度怀疑）

dock 是 `UIHostingController<AnyView>` 的 view（`:908-910`），rootView 是 `MultitaskStageDockSwiftView`——一个水平 ScrollView + HStack，外面套 `.ultraThinMaterial` 实时模糊背景（`:2717-2741`，iOS 26 是 `glassEffect`）。

**dock 紧挨着卡片底部**：`dockFrame` 的 y = `bounds.height - safeArea.bottom - dockHeight`，而卡片块底部 = `origin.y + sideHeight*3`。当 sideHeight*3 == available 时，卡片底边正好贴 dock 顶边。dock 的模糊区域就是卡片底边 + windowHostingView 灰底。

**怀疑链条**：
1. 卡片在弹簧动画中左右滑半屏，dock 下面的卡片边缘内容在快速变化。
2. dock 的 `.ultraThinMaterial` 是 `UIVisualEffectView` 实时模糊，理论上每帧自动采样下面内容。但半屏大位移 0.4s 快速滑动时，模糊采样跟不上卡片速度，会出现短暂的"模糊层没跟上"的闪烁。
3. **completion 里对所有窗口调 `commitHostedGeometry()`（`:1210-1211`）加剧了这个问题**：每次 `commitHostedGeometry` 都做一次 `updateSettingsWithBlock` XPC 到 BackBoard（`AppSceneViewController.m:541-553`）。N+1 次 XPC transaction 叠在动画落地那一帧，触发 UIKit 重新跑一次 window 层级 layoutSubviews——`UIHostingController.view` 的 layoutSubviews 会让 SwiftUI 重新布局一次，`UIVisualEffectView` 的模糊效果在重新布局时短暂重置。这就是"加了 commit 后 dock 闪得更明显"的原因。

这解释了用户观察：
- 加 commit 之前 dock 就闪（原因 1-2，模糊采样跟不上）。
- 加 commit 之后 dock 闪得更明显（原因 3，XPC transaction 叠加触发 hosting view 重新布局）。

#### 改法

**第一步（必做）**：把 completion 里对所有窗口的 `commitHostedGeometry` 去掉，恢复成只对主窗 commit（或干脆不 commit，因为 size 不变它本来就是 no-op）。

```swift
// :1203-1212 改成：
for (index, app) in self.apps.enumerated() {
    app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
}
self.commitMainWindowGeometry()   // 只推主窗，回到 65e3669 之前的行为
```

这一步应该能让 dock 闪减轻（去掉了 XPC transaction 叠加）。

**第二步（如果还闪）**：在 mirroring 弹簧飞行期间，临时把 dock 的模糊效果换成静态色，避免实时模糊跟不上卡片滑动。或者更简单——飞行期间临时把 `dockHost?.view.alpha` 动画到 0，completion 里再淡回 1。

```swift
// 动画块里加一行：
dockHost?.view.alpha = 0
// completion 里加：
UIView.animate(withDuration: 0.2) { dockHost?.view.alpha = 1 }
```

#### 风险

- 去掉对副窗的 commit 不影响触摸（副窗触摸本来就在 guest 进程内被吞，不走 BackBoard touch region）。
- dock 飞行中 alpha=0 会让底部 dock 消失 0.4s——但卡片正好在飞，用户注意力在卡片上，dock 短暂消失可接受。如果觉得太突兀，改成 dock 飞行中透明度降到 0.5 而不是 0。

---

## 问题 2：圆角时机不对

### 现状

mirroring 分支（`MultitaskDockView.swift:1184`）强制 `deferCornerMasks = true`。动画块里**不设** `maskedCorners`（`:1066-1068` 的 `if !deferCornerMasks` 在 mirroring 分支根本不会执行，因为 mirroring 不进 `update` 闭包）。completion 里才设 `maskedCorners`（`:1204`）。

结果：飞行中卡片保持**旧侧**的圆角 mask，落地后才瞬切到新侧。用户看到的是：卡片滑到新位置时，屏幕边缘那一侧是直角（该圆角的地方没圆角），落地后突然冒出圆角。

### 根因（已确证）

`maskedCorners` 是 `CACornerMask` 位掩码，是瞬时属性，不能被 CA 插值——设了就立刻切，没有渐变。所以飞行中要么保持旧 mask，要么切新 mask，没有中间态。

注释 `:1062-1065` 说"在飞行开始时设新 mask 会在共享边上画一条硬轮廓线"——这是对的：如果飞行开始时就切新 mask，主窗滑到右边时，它的右边（屏幕边缘）圆角了，但飞行刚开始时主窗还在左边，右边是共享边（跟副窗列相邻），共享边圆角了——这不对。

但现在的做法（保持旧 mask 到落地）更难看：飞行中外边是直角。

### 正确做法

**换边后哪些角该圆角，在 `isMirrored.toggle()` 那一刻就已经确定了**（`:2378` 翻 toggle，`:2383` 才 relayout）。`maskedCorners(index:count:)` 根据全局 `isMirrored` 算新 mask，不依赖卡片当前位置。

所以正确做法是：**在动画开始前（`UIView.animate` 之前）就把新 mask 设好**。飞行中卡片从旧位置飞到新位置，mask 一直是新侧的圆角。飞行刚开始时共享边会短暂圆角（因为卡片还在旧位置但 mask 已经是新的），但卡片在 0.4s 内连续飞过去，人眼不会盯着共享边看——这比"外边直角 0.4s"自然得多。

具体改法（`MultitaskDockView.swift:1184` 附近）：

```swift
if mirroring {
    layoutToken &+= 1
    let token = layoutToken

    // ★ 在动画开始前就设好新 mask，飞行全程保持圆角。
    //   maskedCorners 是位掩码不能插值，但换边后哪些角该圆角在 toggle() 那一刻
    //   就定了，不需要等落地。飞行刚开始时共享边会短暂圆角，比外边直角自然。
    for (index, app) in self.apps.enumerated() {
        app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
    }

    UIView.animate(
        withDuration: MultitaskDockManager.layoutAnimationDuration,
        delay: 0,
        usingSpringWithDamping: 1.0,
        initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
            for (index, app) in self.apps.enumerated() {
                guard let view = app.view else { continue }
                let frame = MultitaskStageLayout.slotFrame(index, bounds: bounds, safeArea: safeArea)
                view.frame = frame
                self.windowShadowCasters[app.appUUID]?.frame = frame
            }
        }
    ) { [weak self] _ in
        guard let self, self.layoutToken == token else { return }
        // completion 里不需要再设 maskedCorners 了——动画开始前已经设好。
        self.commitMainWindowGeometry()
    }
}
```

删掉 `deferCornerMasks = true`（`:1184`）和 completion 里的 `maskedCorners` 赋值（`:1204`）。

### 为什么安全

- `cornerRadius` 固定 12（`DecoratedAppSceneViewController.m:89` + `MultitaskStage.swift:53`），飞行中不变。
- `cornerCurve = .continuous` 也固定。
- 只要 `maskedCorners` 选对了角，飞行全程都是圆角，不会看到直角。
- 注释里担心的"共享边硬轮廓线"——卡片在连续滑动，共享边也在移动，人眼不会注意一条移动的圆角轮廓。

### 风险

- 飞行刚开始那一帧，卡片还在旧位置但 mask 已经是新侧——共享边短暂圆角。如果觉得突兀，可以用方案 (c)：飞行中临时设 `allCorners`（四个角都圆角），落地再切回正确 mask。但这样飞行中共享边和外边都圆角，不如直接设新 mask 干净。
- 这个改法要配合问题 3 的 `maskedCorners` 修正一起做（见下），否则 N<3 时下角还是错的。

---

## 问题 3：副窗少于 3 个时圆角算错

### 现状

`MultitaskStage.swift:198-213` 的 `maskedCorners(index:count:)`：

```swift
static func maskedCorners(_ index: Int, count: Int) -> CACornerMask {
    if count <= 1 { return allCorners }
    if !isMirrored {
        if index <= 0 { return [.layerMinXMinYCorner, .layerMinXMaxYCorner] }  // 主窗
        var corners: CACornerMask = []
        if index == 1 { corners.insert(.layerMaxXMinYCorner) }     // 最上副窗上角
        if index == count - 1 { corners.insert(.layerMaxXMaxYCorner) }  // 最下副窗下角
        return corners
    }
    // 镜像同理...
}
```

`count = apps.count`（`MultitaskDockView.swift:969`），是**总窗口数** = 1主窗 + N副窗。

### BUG

`index == count - 1` 给"最下那个窗口"加下角圆角。但 `count-1` 不一定是"占满整列的最下副窗"：

| 副窗数 N | count | index == count-1 的是谁 | 该不该有下角圆角 | 现状 |
|---|---|---|---|---|
| 1 | 2 | index 1（唯一一个副窗） | **不该**（底边在半空） | 错误地给了下角 |
| 2 | 3 | index 2（第二个副窗） | **不该**（底边在半空） | 错误地给了下角 |
| 3 | 4 | index 3（第三个副窗） | 该（占满整列） | 正确 |

N=1 或 N=2 时，最下副窗的底边悬在半空（下面是空的 windowHostingView 灰底），不该圆角——但代码给它加了下角圆角。

### 正确规则（用户已明确）

- 主窗（index 0）：靠自己那一侧的两个角永远圆角。
- 副窗列：
  - 最上面那个副窗（index 1）：靠外那侧的**上角**圆角——不管 N 是多少。
  - 只有当副窗列占满整列（**N=3，即 count=4**）时，最下面那个副窗（index 3）靠外那侧的**下角**才圆角。
  - N<3 时，最下副窗底边悬在半空，**不**加下角圆角。
  - 中间副窗（index 2，只有 N=3 时存在）：全直角。

### 改法

`MultitaskStage.swift:198-213`，把下角的判断从 `index == count - 1` 改成 `count == 4 && index == 3`（副窗占满整列时才给最下副窗下角圆角）：

```swift
static func maskedCorners(_ index: Int, count: Int) -> CACornerMask {
    if count <= 1 { return allCorners }
    // 副窗数 = count - 1（index 0 是主窗）。下角圆角只在副窗列占满整列
    // （sideCount == 3，即 count == 4）时才给最下那个副窗。
    let sideCount = count - 1
    let sideColumnFilled = (sideCount == 3)   // 副窗列占满整列

    if !isMirrored {
        if index <= 0 { return [.layerMinXMinYCorner, .layerMinXMaxYCorner] }
        var corners: CACornerMask = []
        if index == 1 { corners.insert(.layerMaxXMinYCorner) }  // 最上副窗上角
        if sideColumnFilled && index == 3 { corners.insert(.layerMaxXMaxYCorner) }  // 只有占满整列才给最下副窗下角
        return corners
    }
    // Mirrored: 主窗在右。
    if index <= 0 { return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] }
    var corners: CACornerMask = []
    if index == 1 { corners.insert(.layerMinXMinYCorner) }
    if sideColumnFilled && index == 3 { corners.insert(.layerMinXMaxYCorner) }
    return corners
}
```

### 风险

- 这是纯几何计算修正，不影响动画。N=3 时行为跟现在一样（本来就是对的），N=1/2 时去掉了不该有的下角圆角。
- 要跟问题 2 的改法一起上（动画开始前就设新 mask），否则飞行中 mask 还是旧的错值。

---

## 三个问题的改法汇总

| 问题 | 改法位置 | 一句话 |
|---|---|---|
| 1a 副窗闪 | `AppSceneViewController.m` 加 `beginMirrorFlight`/`endMirrorFlight`；`MultitaskDockView.swift:1184` 附近调用 | 飞行期间临时把副窗 userInteractionEnabled 设 YES，让 render server 逐帧追踪 surface |
| 1b dock 闪 | `MultitaskDockView.swift:1203-1212` | 去掉对所有窗口的 commit，恢复只推主窗；如果还闪，飞行中临时 dock.alpha=0 |
| 2 圆角时机 | `MultitaskDockView.swift:1184-1213` | 动画开始前就设新 maskedCorners，不要 defer |
| 3 圆角算错 | `MultitaskStage.swift:198-213` | 下角圆角条件从 `index==count-1` 改成 `count==4 && index==3` |

建议顺序：先改 3（纯计算，零风险）→ 再改 2（圆角时机）→ 再改 1b（去掉多余 commit，应该立刻见效）→ 最后改 1a（需要上设备验证 userInteractionEnabled 是否真是 surface 采样开关）。
