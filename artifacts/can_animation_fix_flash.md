# 用 UIViewPropertyAnimator 连续动画换边，能不能从根上消除黑闪？

> 只读代码 + git 历史分析，未改仓库。结论先行，理由锚定文件:行号。

---

## 结论：有条件能根治

**连续动画本身大概率不会触发 surface 重建**——之前弹簧露黑的真正原因不是"大位移连续动画必然拆 surface"，而是弹簧版本的 `update` 闭包里干了多余的事（z 序重排、seam plate 显隐、`layoutIfNeeded` 时机），加上团队把"卡片之间露黑缝"误判成了"surface 重建"。

但**不能拍胸脯说一定行**，因为有一个无法从代码层 100% 确认的黑盒：`_UISceneHostingView` 内部是否对 frame 变化有自己的 geometry observer。下面给出验证方法，不改代码先观测，确认后再动手。

**如果验证通过（surface 在连续位移中不重建）**，方案能把冻结帧盖帧整个删掉，换边变成丝滑弹簧。如果验证发现 surface 确实在连续位移中重建，那盖帧就是唯一出路。

---

## 问题 1：黑闪到底是"瞬移半屏 → surface detach/reattach"造成的吗？

### 换边这一下实际跑了什么（逐行）

入口 `toggleLayoutHandedness()`（`MultitaskDockView.swift:2367`）：

1. **先盖帧**（2372-2378）：对每个卡片调 `showSwapCover`——把 guest 自摄的 JPEG 盖上去，没 JPEG 就盖 app 图标卡。这一步在跳之前。
2. 翻 `isMirrored`（2379）。
3. `relayout(animated: true, mirroring: true)`（2383）→ 走进 mirroring 分支（1175-1203）：
   - `performWithoutAnimation` 里：`view.frame = newFrame`（卡片外壳跨半屏跳）、`maskedCorners`、`shadowCaster.frame`、然后 `layoutIfNeeded()`（1195-1197）。
   - 分支末尾**显式调** `commitMainWindowGeometry()`（1203）。
4. 0.6s 后 `hideSwapCover`（2386-2391）。

### `commitMainWindowGeometry()` 干了什么

→ `commitHostedGeometry()`（`AppSceneViewController.m:531-554`）：

```objc
self.shouldSkipDebounceOnce = YES;          // 绕过 50ms 防抖
[self updateFrameWithSettingsBlock:nil];    // ① 立刻推一次 frame

[self.presenter.scene updateSettingsWithBlock:^(...) {
    settings.foreground = YES;
    settings.deactivationReasons = 0;
    [(id)self.contentView applyViewGeometryToSettings:settings];  // ② 把 on-screen 几何写进 settings
}];
```

关键点：
- **① 是 no-op**。`updateFrameWithSettingsBlock:`（284-318）最终走 `updateSettingsWithBlock:`（320-364），在 modern hosting 路径下（344-359）**只写 `contentView.bounds`**，且 357 行有 guard——size 不变就不写。换边 size 不变，所以 bounds 不动，也不 forward 给 scene。
- **② 是真 XPC push**。`applyViewGeometryToSettings:` 把 hosting view 的 on-screen 几何写进 scene settings，BackBoard 据此重算触摸区域。这是跨进程调用。

### `applyStageFrame` 的 geometryKey 跳过逻辑（`DecoratedAppSceneViewController.m:374-394`）

```objc
NSString *geometryKey = [NSString stringWithFormat:@"%.2f_%.2f_%.4f_%d",
                         frame.size.width, frame.size.height, _scaleRatio, maximized];
BOOL geometryChanged = ![geometryKey isEqualToString:_lastPushedGeometryKey];
// ...
} else if(geometryChanged) {
    [self.appSceneVC updateFrameWithSettingsBlock:nil];
}
```

**geometryKey 不含 position**，只有 size/scale/maximized。换边时这三个全不变 → `geometryChanged = NO` → `applyStageFrame` 自己**不推 settings**。

所以 mirror 分支里，唯一一次跨进程 settings push 就是 1203 行那次显式 `commitMainWindowGeometry()`。

### 容器层级（`DecoratedAppSceneViewController.m:84-165`）

```
DecoratedStageContainerView  backgroundColor=.black, masksToBounds=YES  ← :88 这层黑
├── appSceneVC.view  (autolayout pin 四边, :97-102)
│   └── contentView = _UISceneHostingView  (anchorPoint/position=(0,0), transform=scaleRatio)
├── frozenFrameView  (UIImageView, 盖帧用, :137-150)
├── launchPlaceholder (黑底icon+spinner, :154-165)
└── tapShield
```

换边时：container 的 frame.origin.x 跳变（position 变），**bounds 不变**。`appSceneVC.view` pin 在 container 四边，bounds 不变 → 它的 frame 相对 container 不变 → `contentView` 的 bounds/transform/position 全不变。`contentView` 只是作为子视图跟着 container 平移。

### 判断：瞬移那一帧是谁触发了 surface 重建？

**两个嫌疑：**

| 嫌疑 | 证据 | 强度 |
|---|---|---|
| (A) container position 瞬移本身 | 708b1fb commit message："jumping the hosting view half a screen tears down/reattaches the cross-process surface"；换边黑闪修复方案.md:37 同样归因 | 团队当前认定 |
| (B) `commitHostedGeometry` 的 XPC push | `armGeometryCommitIfNeeded` 注释（1626-1629）："re-pushing scene settings would only force a cross-process surface reconnect — exactly the black flicker"；换边黑闪修复方案.md:39："XPC 是帮凶，把可能闪坐实成必闪" | 也有注释支持 |

**我的判断：(A) 和 (B) 可能是同一件事的两面，不是两件事。**

render server 合成远程 IOSurface 时，它读的是 layer tree 里 hosting view 的**on-screen position**。瞬移那一帧，position 从旧值跳到新值，layer tree 里没有中间帧——render server 可能短暂地在新旧位置之间"找不到"surface，露出 container 的黑底。`commitHostedGeometry` 的 XPC push 把新几何告诉 BackBoard，触发 surface 在新位置重挂——这一步把"可能闪"坐实成"必闪"，但不 push 的话 surface 停在旧位置，视觉上卡片在新位置、内容还在旧位置，也是错的。

**关键推论：如果 position 是连续插值的（弹簧），layer tree 每一帧都有合法的中间 position，render server 就不需要"找不到 surface"那一帧。** 这就是连续动画可能根治的理论基础。

---

## 问题 2：之前弹簧飞行也露黑，真正原因是什么？

### git 历史时间线（从旧到新）

| commit | 干了什么 |
|---|---|
| pre-6d6f29b | mirror 走通用弹簧分支：`UIView.animate(spring damping 1.0, 0.4s)` + `update` 闭包 |
| `6d6f29b` | 把 mirror 改成 `performWithoutAnimation` 瞬切，commit message："Sliding the hosted cards through a spring exposed a black mid-flight gap and **made iOS re-derive each hosted surface mid-flight** (the whole-screen flicker)" |
| `8fe2df5` | 瞬切后补 `layoutIfNeeded()` 同事务布局（"otherwise the remote content lags one frame, which is the whole-screen flash"） |
| `2e712db` | 瞬切后补 `commitMainWindowGeometry()`（修触摸区域；commit message 说这步"reduces the one-frame black flash"） |
| `708b1fb` | 加冻结帧盖帧（"jumping half a screen tears down/reattaches surface, exposing black backing"） |
| `073f288` | 盖帧 Plan B：有 JPEG 用 JPEG，没 JPEG 用 icon 兜底 |

### pre-6d6f29b 弹簧版本到底做了什么

我把 `6d6f29b^` 的 `MultitaskDockView.swift` 拉出来逐行看了（`/tmp/dock_pre6d6.swift`）。弹簧分支（1190-1209）：

```swift
armGeometryCommitIfNeeded()          // ①
UIView.animate(spring, animations: update) {
    self.settleAfterAnimation()      // ②
}
```

**① `armGeometryCommitIfNeeded()`（1593-1602）对 mirror 是空操作：**
```swift
let changed = lastSettledFullscreen != isFullscreen
    || lastSettledMainUUID != apps.first?.appUUID
guard changed else { return }   // mirror 不翻 fullscreen、不换 mainUUID → 直接 return
```

**② `settleAfterAnimation()`（1606-1650）对 mirror 也是空操作：**
```swift
let currentGen = pendingGeometryGeneration   // 没 arm 过，gen 没变
guard currentGen != lastSettledGeneration else { return }  // 相等 → return
```

**所以弹簧版本全程没有任何一次 `commitMainWindowGeometry()`，没有 XPC push。** 这推翻了"弹簧露黑是因为 completion 里 push 了几何"的假设（agent-hint 里的假设 4 不成立——我查了 git，pre-6d6f29b 的 settle 对 mirror 直接 bail 了）。

### 那弹簧露黑到底从哪来？

弹簧版本的 `update` 闭包（1030-1170）做了这些事：

1. **`applyStageFrame` 每个卡片**（1046-1047）：设 container frame + `applyScaleRatio` + `[self.view layoutIfNeeded]`（DecoratedAppSceneVC.m:372）
2. **z 序重排**（1072-1079）：`bringSubviewToFront` / `sendSubviewToBack` / `insertSubview:aboveSubview:`
3. **`blockPlate.isHidden = !mirroring`**（1090）：seam plate 在飞行中显示
4. shadow caster 更新（1102-1114）
5. backdrop/chrome 用 `performWithoutAnimation` 冻结（1092-1096, 1165-1169）

对比现在的瞬切分支（1184-1198），瞬切分支**只做了 1 的 frame 写入 + layoutIfNeeded**，不做 2/3/4。

**弹簧露黑的真正原因，我认为是以下两个之一（或叠加），而不是"连续位移必然拆 surface"：**

#### 原因 A：z 序重排 + seam plate 显隐在动画块里做了瞬时操作

`bringSubviewToFront` 和 `insertSubview:aboveSubview:` 是**瞬时**的（不插值）。它们在动画开始的那一帧执行，改变了 subview 顺序。`insertSubview:aboveSubview:` 把 blockPlate 从 view hierarchy 里摘出来再插回去——虽然 blockPlate 是本地 UIView，但这个操作发生在 `windowHostingView` 上，可能触发布穿。更关键的是，`sendSubviewToBack(stageBackdrop)` + `insertSubview(blockPlate, above: stageBackdrop)` 在动画块开头执行，而 blockPlate 是飞行中唯一盖住中心缝的东西——它的显隐是瞬切的，不是插值的。

#### 原因 B："black mid-flight gap" 是卡片之间的黑缝，不是 surface 重建

commit message 说 "exposed a **black mid-flight gap**"。两个卡片从左右两边对滑到中间、穿过、再到对面。滑行中途，卡片腾空的区域（最左/最右）露出 `windowHostingView` 的背景。`stageBackdrop` 虽然 sendSubviewToBack 了，但它是个 alpha 模糊层，底下如果没有不透明内容，露出的就是 window 的黑底。blockPlate 只盖了中心缝，没盖两侧腾空区。

**这是视觉缝，不是 surface 重建。** 团队把"看到黑"直接等同于"surface 拆了重挂"，但没有加日志验证过。

### 为什么我倾向于"不是 surface 重建"

1. **弹簧版本没有 XPC push**。surface 重建通常由 scene settings 变化（size 变、foreground 翻、window 换）触发。纯 position 变化不应该触发。
2. **`contentView` 的 bounds/transform 在弹簧中完全不变**（换边 size 不变）。IOSurface 的尺寸不需要重分配。
3. **iPadOS Split View 拖 divider 时两个 app 的 hosting view 就是连续 resize/移动的**，没有黑闪。苹果自己就是这么做的。
4. 代码里没有任何 `willMoveToWindow` / `didMoveToSuperview` 重写（我 grep 过，MultitaskSupport 里零个），hosting view 没有被摘过窗口。

---

## 问题 3：如果连续动画能根治，具体方案是什么？

### 前提

先按问题 4 的验证方法确认 surface 在连续位移中不重建。如果验证通过，方案如下：

### 改 `toggleLayoutHandedness()`（2367）

```
现状：showSwapCover → toggle isMirrored → relayout(mirroring:true) → 0.6s 后 hideSwapCover
改后：toggle isMirrored → relayout(mirroring:true, animated:true spring) → 动画 completion 里 commit → 不盖帧
```

### 改 mirroring 分支（1175-1203）

现在是 `performWithoutAnimation` 瞬切。改成弹簧：

```swift
if mirroring {
    layoutToken &+= 1
    let token = layoutToken
    // 弹簧动画：卡片 frame 从旧槽位连续飞到新槽位
    UIView.animate(
        withDuration: 0.4,
        delay: 0,
        usingSpringWithDamping: 0.95,   // 近临界阻尼，不过冲
        initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
            for (index, app) in self.apps.enumerated() {
                guard let view = app.view else { continue }
                let frame = MultitaskStageLayout.slotFrame(index, bounds: bounds, safeArea: safeArea)
                view.frame = frame
                // corner mask 在动画中保持旧的（deferCornerMasks = true），落地再切
                self.windowShadowCasters[app.appUUID]?.frame = frame
            }
        }
    ) { [weak self] _ in
        guard let self, self.layoutToken == token else { return }
        // 落地后：切 corner mask + 推一次几何修触摸区域
        for (index, app) in self.apps.enumerated() {
            app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
        }
        self.commitMainWindowGeometry()   // 只推一次，size 不变 → metadata 更新，不应重建 buffer
    }
}
```

### 中途不做什么

- **不调** `commitMainWindowGeometry()`（弹簧飞行中）
- **不调** `applyStageFrame` 的 settings push（geometryKey 本来就跳过了，保持）
- **不做** z 序重排（换边不换 mainUUID，z 序本来就不变）
- **不 showSwapCover / hideSwapCover**
- corner mask 在飞行中保持旧的（`deferCornerMasks = true`），落地再切——这是 pre-6d6f29b 就有的经验（1060-1063 注释）

### settle 时做什么

- 一次 `commitMainWindowGeometry()` 修触摸区域
- corner mask 落地切换
- **不需要** 0.35s 二次 commit（mirror 不翻 fullscreen/mainUUID，不会有"系统 post-animation layout 改几何"的问题——那个二次 commit 是给 fullscreen/promotion 准备的，1668-1681 的 guard 本来就会因为 layoutToken 不匹配而跳过 mirror）

### 冻结帧盖帧删不删？

**验证通过后可以整个删掉**（至少 mirror 路径不需要了）。理由：
- 连续动画中 surface 跟着 layer 走，没有黑帧
- 落地那次 `commitMainWindowGeometry()` 是 size 不变的 metadata push，不重分配 IOSurface，不应该露黑
- `showSwapCover` / `hideSwapCover` / `blockPlate` 在 mirror 路径全删

**保留作为兜底**：如果验证发现落地 commit 那一下还是闪 1 帧，可以保留盖帧但只在落地前后盖（飞行中不盖），或者干脆盖帧逻辑留着但 mirror 路径走不到。

### 其他组件怎么处理

| 组件 | 飞行中 | 落地时 |
|---|---|---|
| `contentView.transform = scaleRatio` | 不变（size 不变，transform 不写） | 不变 |
| shadowCaster | frame 跟着弹簧插值（放进动画块） | 落地 |
| cornerMask | 保持旧 mask | 切新 mask |
| chrome/dock/backdrop | `performWithoutAnimation` 冻结（它们不在新槽位动） | 不动 |
| stageBackdrop | 不动 | 不动 |

---

## 问题 4：风险和判断标准——怎么确认假设而不是盲改？

### 怎么验证（不改业务逻辑，只加观测）

在改动画之前，先加临时日志/钩子，跑一次换边，看 surface 到底有没有拆：

#### 方法 1：hook `_UISceneHostingView` 的 window/superview 生命周期

在 `UIKitHooks.m` 里临时加：

```objc
// hook willMoveToWindow: 看换边飞行中 hosting view 的 window 是不是变 nil
%hook _UISceneHostingView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    NSLog(@"[LCGeom] hostingView willMoveToWindow: %@ (self=%@)", newWindow, self);
    %orig;
}
- (void)willMoveToSuperview:(UIView *)newSuperview {
    NSLog(@"[LCGeom] hostingView willMoveToSuperview: %@", newSuperview);
    %orig;
}
%end
```

**如果飞行中这两个方法都没被调（或 newWindow/newSuperview 非 nil），说明 surface 没 detach。**

#### 方法 2：CADisplayLink 逐帧看 hosting view 的 presentation position

在 mirror 弹簧飞行期间，用 CADisplayLink 每帧打一条日志：

```swift
// 弹簧开始后
var displayLink: CADisplayLink?
displayLink = CADisplayLink(target: self, selector: #selector(sampleFrame(_:)))
displayLink?.add(to: .main, forMode: .common)

@objc func sampleFrame(_ link: CADisplayLink) {
    guard let mainView = apps.first?.view else { return }
    let pres = mainView.layer.presentation()
    NSLog("[LCGeom] t=%.3f frame=%@", link.timestamp, NSStringFromCGRect(pres?.frame ?? .zero))
    // 动画结束后 invalidate
}
```

如果 presentation frame 是连续插值的（从旧 x 到新 x 中间有逐帧值），说明 UIKit 在正常做 layer 动画。

#### 方法 3：看 surface 有没有真的重建——hook `_UISceneHostingController`

```objc
%hook _UISceneHostingController
// 看有没有 invalidate / re-instantiate
- (void)invalidate {
    NSLog(@"[LCGeom] hostingController INVALIDATED during mirror!");
    %orig;
}
%end
```

如果飞行中 `invalidate` 没被调，说明 hosting controller 没被拆。

#### 方法 4：最直接——先试"无盖帧瞬切"看黑多久

现在的代码是瞬切 + 盖帧盖 0.6s。临时把盖帧去掉（`showSwapCover` 不调，直接跳），看：
- 黑是持续多久？1 帧？还是 0.5s？
- 黑是整个卡片黑，还是只有卡片中心一条缝？
- 如果是 1 帧黑 → surface 重建那一帧，连续动画可能躲过。
- 如果是 0.5s 持续黑 → surface 在位移期间持续重建，连续动画也救不了。

**这是最快的判定实验**，5 分钟改完上设备看一眼。

### 什么情况下连续动画还是会闪？

| 情况 | 概率 | 说明 |
|---|---|---|
| `_UISceneHostingView` 内部对任何 frame 变化都 detach/reattach | 低 | iPadOS Split View 反证——人家就是连续动画的 |
| 大位移（半屏）超过 render server 的某个阈值，强制重连 | 中 | 苹果自己 Split View 位移也不小，应该不是阈值问题 |
| `contentView.transform` 非单位 + 父容器 frame 动画叠加，触发 UIKit 重新计算 layer 几何 | 中 | 这是本项目特有的（苹果自己的 hosting view 不叠 transform），需要实测 |
| iOS 版本差异（17/18/19 行为不同） | 中 | 代码里已经有 `@available(iOS 19.0, *)` 分支，不同版本可能不一样 |
| 落地那次 `commitHostedGeometry` 的 XPC push 还是闪 1 帧 | 中 | size 不变理论上不重分配 buffer，但 `applyViewGeometryToSettings:` 可能触发 scene transaction |

### 风险清单

1. **触摸区域在动画中途是旧的**。飞行 0.4s 里，BackBoard 的触摸区域还在旧槽位。如果用户在飞行中点屏幕，落点是错的。但换边是个瞬时手势（点一下 swap 按钮），飞行期间用户不太可能立刻点卡片——而且 side window 触摸本来就在 guest 进程内 quarantine（`LCStageIPC.h`），主窗触摸在 0.4s 内落点偏了也问题不大。落地立刻 commit 修触摸区域。

2. **性能**。两个远程 surface 同时在屏幕上连续移动，render server 每帧要重新合成两个跨进程 surface。iPadOS Split View 这么干没问题，半屏位移 0.4s 应该扛得住。

3. **可中断性**。用 `UIViewPropertyAnimator` 而不是 `UIView.animate`，支持飞行中再点 swap 按钮反转方向（`.beginFromCurrentState`）。这比现在的瞬切体验好。

4. **iOS 版本差异**。代码在 iOS 17.4+ 走 `_UISceneHostingController`，更老的版本走 legacy presenter。legacy 路径（`contentView` 是普通 UIView 包 `presentationView`）没有远程 surface 问题，连续动画肯定不闪。风险只在 modern hosting 路径。

---

## 之前弹簧露黑的真正原因（总结）

**不是"连续位移必然拆 surface"。** 证据：
- 弹簧版本全程无 XPC push（arm/settle 对 mirror 都 bail 了，我查了 git 确认）
- `contentView` 的 bounds/transform 在飞行中完全不变
- iPadOS Split View 就是连续动画的反例

**更可能是：**
1. `update` 闭包里的 z 序重排（`bringSubviewToFront` / `insertSubview:aboveSubview:`）和 blockPlate 显隐在动画块开头瞬时执行，造成了视觉瞬态
2. 两个卡片对滑时腾空区域露出黑底，blockPlate 没盖全
3. 团队把"看到黑"直接归因为"surface 重建"，没有加日志验证——这个归因可能是错的

**现在的瞬切方案（盖帧 0.6s）是在"黑帧必然存在"的假设下打补丁。如果黑帧本身是可以通过连续动画消除的，那盖帧就是过度工程。**

---

## 推荐行动顺序

1. **先做方法 4 的实验**（去掉盖帧，瞬切，看黑多久/黑在哪）——5 分钟，上设备看一眼，直接判定 surface 是"闪 1 帧"还是"持续黑"。
2. 如果是闪 1 帧：按问题 3 的方案改成弹簧，中途不 push，落地 push 一次，盖帧删掉。上设备看。
3. 如果是持续黑：说明 surface 在位移期间确实重建，连续动画救不了，保留盖帧。
4. 不管结果如何，把方法 1-3 的观测日志留在代码里（临时 NSLog），下次改动画时能直接看到 surface 生命周期。

---

## 关键代码位置速查

| 作用 | 文件:行 |
|---|---|
| 换边入口 | `MultitaskSupport/MultitaskDockView.swift:2367` |
| mirroring 瞬切分支 | `MultitaskSupport/MultitaskDockView.swift:1175-1203` |
| `commitMainWindowGeometry` | `MultitaskSupport/MultitaskDockView.swift:1694-1699` |
| `armGeometryCommitIfNeeded`（mirror 不 arm） | `MultitaskSupport/MultitaskDockView.swift:1625-1634` |
| `settleAfterAnimation`（mirror 不 settle） | `MultitaskSupport/MultitaskDockView.swift:1638-1682` |
| `commitHostedGeometry`（XPC push） | `MultitaskSupport/AppSceneViewController.m:531-554` |
| 50ms 防抖 | `MultitaskSupport/AppSceneViewController.m:284-318` |
| hosting 路径只写 bounds 不 forward scene | `MultitaskSupport/AppSceneViewController.m:344-359` |
| geometryKey 跳过 position | `MultitaskSupport/DecoratedAppSceneViewController.m:374-394` |
| contentView transform 缩放 | `MultitaskSupport/DecoratedAppSceneViewController.m:397-405` |
| 容器层级 + 黑底 | `MultitaskSupport/DecoratedAppSceneViewController.m:84-165` |
| 冻结帧盖帧 | `MultitaskSupport/DecoratedAppSceneViewController.m:237-312` |
| `_UISceneHostingView` 私有头 | `MultitaskSupport/UIKitPrivate+MultitaskSupport.h:303-308` |
| 6d6f29b 瞬切 commit | git show 6d6f29b |
| pre-6d6f29b 弹簧版本 | `git show 6d6f29b^:MultitaskSupport/MultitaskDockView.swift` |
