# LiveContainer-MT 双 Bug 根因审查与修复方案

> 只读代码审查，未改动任何仓库文件。所有结论锚定到具体文件/行号。
> 标注说明：**【已确证】** = 代码读死，有实锤；**【高度怀疑】** = 机制推断，改完跑一把确认。

---

## 总览：两个 bug 是同一个底层病根的两种表现

| | 长按录不上音 | 换边闪黑 |
|---|---|---|
| 病根 | `_UISceneHostingView` 被硬套了 `scaleRatio` transform，bounds 与屏幕实际 footprint 不一致 | 换边时 hosting view 跨半屏跳变，触发远程 surface detach/reattach，露出卡片黑底 |
| 所在层 | MultitaskSupport（我们主动套的 transform） | MultitaskSupport + 系统远程渲染合成器 |
| 为什么官方也有 | 官方也是"bounds 设全屏 + transform 缩放"这套 | 官方 `_UISceneHostingView` 远程托管的合成机制本身 |
| 修复方向 | 去掉 transform，让 scene 直接按 slot 尺寸渲染 | 复用已有 guest 自摄冻结帧机制，换边时盖住黑帧 |

**两个 bug 都不在我们加的卡片布局里，都在远程场景托管的底层。** 下面分别展开。

---

# Bug 1：主窗长按"按住说话"录不上音

## 一句话根因

`_UISceneHostingView`（远程托管视图，也就是 `contentView`）被我们硬套了一层 `scaleRatio` 缩放变换。主窗 split 模式下 `scaleRatio = 3/4 ≈ 0.745`（不是 1.0）。我们把它的 bounds 设成未缩放的全屏 390×874，再用 0.745 transform 压到 slot 的 ≈290×647。

系统设计 `_UISceneHostingView` 是"多大视图 = 多大屏幕"，BackBoard 按这个假设注册触摸命中区、换算手指坐标。视图一挂 transform，bounds（390×874）和屏幕真实占的地方（290×647）对不上，坐标回算就有误差。

**tap 容错大所以没事，长按要求手指 10pt 容差内稳住 0.5 秒，这套带误差的坐标回算就把长按手势识别器搞挂了——而且静默失败不发 touchesCancelled，正好对上你诊断浮层 `BEGAN→ENDED` 无 CANCELLED 的现象。** 按钮 touchDown 比长按宽松，所以震感照常有。

## 逐层证据

### 第 1 层：scaleRatio 主窗不是 1.0

`MultitaskSupport/MultitaskStage.swift:111` `slotScaleRatio`：
```swift
return (index <= 0 ? g.unit * 3 : g.unit) / bounds.width
```
`geometry`（65 行）里 `unit = width / 4`（maxWindows=4）。所以主窗（index 0）split 模式下 ratio = (unit×3)/width = **3/4 ≈ 0.745**。

> 只有 `isFullscreen=true` 时 ratio 才是 1.0（`MultitaskDockView.swift:1062`）。默认进多任务舞台 `isFullscreen=false`（`:654`），主窗就是 0.745。

### 第 2 层：transform 是怎么套上去的【已确证】

`MultitaskSupport/DecoratedAppSceneViewController.m:379-387` `applyScaleRatio`：
```objc
- (void)applyScaleRatio {
    CGFloat ratio = _scaleRatio > 0 ? _scaleRatio : 1.0;
    self.appSceneVC.scaleRatio = ratio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(ratio, ratio);  // ← 罪魁祸首
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(ratio, ratio, 1.0);
    }
}
```
`contentView` 就是 `_UISceneHostingController.sceneViewController.view`（`AppSceneViewController.m:177`），即远程场景视图本身。

### 第 3 层：bounds 被设成未缩放的全屏尺寸【已确证】

`MultitaskSupport/AppSceneViewController.m:293-307` `updateFrameWithSettingsBlock:`：
```objc
CGRect frame = self.view.frame;   // slot 在屏幕上的实际尺寸 ≈290×647
// [LOCAL CHANGE] guest 按原生分辨率渲染，再由 contentView.transform 缩小
if(self.scaleRatio > 0) {
    frame.size.width  /= self.scaleRatio;   // 290 / 0.745 = 390
    frame.size.height /= self.scaleRatio;   // 647 / 0.745 = 874
}
settings.frame = frame;   // scene 逻辑尺寸 = 未缩放全屏 390×874
```

`updateSettingsWithBlock:`（321 行起）把这个未缩放尺寸写进 `contentView.bounds`（357-359 行）：
```objc
CGRect newBounds = CGRectMake(0, 0, frame.size.width, frame.size.height);  // 390×874
self.contentView.bounds = newBounds;
```

**结果：hosting 视图 bounds = 390×874，但它在屏幕上真实占 290×647，靠 0.745 transform 对齐。**

### 第 4 层：触摸不走宿主 UIKit hitTest，走 BackBoard【已确证】

`MultitaskSupport/UIKitHooks.m:72-77` 注释原文：
> "delivered through a system-level channel that bypasses the regular UIKit hit-test chain"

远程场景的触摸由 BackBoard 根据 `applyViewGeometryToSettings:` 推上来的几何注册命中区、换算坐标。UIKit 官方文档明说：**transform 非单位阵时 `view.frame` 未定义**（本仓库 `AppSceneViewController.m:348-356` 注释自己也承认了）。BackBoard 拿"bounds 390×874 + 屏幕 footprint 290×647"这套不一致的几何去建触摸区，换算坐标只能大概齐。

### 第 5 层：guest 端没有二次坐标转换【已确证】

`TweakLoader/UIKit+GuestHooks.m:798-884` `hook_lcStage_sendEvent:`：主窗（side=0）走快速放行路径（825-828 行），直接调原始 `sendEvent`，**事件原样透传，没有坐标转换**。副窗隔离只在 `LCStageGuestIsSideWindow==YES` 时才吞事件。

`MultitaskSupport/UIKitHooks.m:97-163` 宿主侧 `LCProcessStageTouches` + `interceptTouchAtLocation:`（`MultitaskDockView.swift:2292`）只遍历 index≥1 副窗，主窗永远返回 NO。

**所以 host/guest 两层 sendEvent hook 都没碰主窗触摸。** 你的诊断浮层能看到 `BEGAN→ENDED` 就是证据——事件到了 guest，但 BackBoard 翻译坐标那一步带误差。

### 第 6 层：官方作者自己踩过这个坑【已确证】

`MultitaskDockView.swift:1678-1701` 0.35s 二次几何 commit 的注释原文：
> "On some iOS 19 builds the system's own post-animation layout pass re-derives the hosting view geometry a beat AFTER our settle push, and the touch region then describes a stale slot: controls in the split main window stay untappable…**fullscreen always worked, because its frame equals the screen**"

**split（带缩放 transform）主窗触摸区会 stale，全屏（frame==screen，无 transform）从来没问题**——官方作者已经用代码注释确认了这个因果关系。

## 为什么长按偏偏挂【高度怀疑】

1. 手指按在按钮视觉位置（屏幕坐标 S）。
2. BackBoard 把 S 映射成 guest 坐标 G 转发。因为 bounds 与 footprint 不一致，映射有误差。
3. began 那一刻大概齐落在按钮上（touchDown 亮、有震感），但：
   - 要么 began 落点蹭在按钮手势区边缘（差几个 pt）；
   - 要么按住期间 guest 收到的后续坐标有微小漂移（远程通道对带 transform 的 hosting view 做逐事件坐标回算，精度不够）。
4. `UILongPressGestureRecognizer` 默认 `allowableMovement ≈ 10pt`、`minimumPressDuration ≈ 0.5s`。落点偏 + 漂移超 10pt → 手势识别器**静默失败**，不产生 `touchesCancelled`。
5. UIControl 的 `touchDown` 不要求 hold、不要求 movement 容差，所以按钮照样亮。

## 修复方案：去掉 transform，让 scene 直接按 slot 尺寸渲染

**思路**：让 `contentView.bounds == 屏幕实际占的尺寸 == settings.frame`，transform 恒为单位阵。BackBoard 拿到的几何回到它设计时假设的状态，触摸 1:1 全准。

**代价**：guest 不再按 390×874 渲染再缩小，而是直接按 slot ≈290×647 渲染。3 倍屏下 slot 实际像素 ≈870×1941，对占屏 75% 的窗口锐度完全够，肉眼基本看不出差别。

### 具体改三处

**① `MultitaskSupport/DecoratedAppSceneViewController.m:383`** — 去掉 hosting 视图的 transform：
```objc
// 删掉这行：
// self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(ratio, ratio);
// legacy 路径 :385 的 sublayerTransform 同理去掉
```

**② `MultitaskSupport/AppSceneViewController.m:298-301`** — 去掉"除以 scaleRatio"，`settings.frame` 直接用 slot 实际尺寸：
```objc
CGRect frame = self.view.frame;
// 删掉：if(self.scaleRatio > 0) { frame.size.width /= ...; frame.size.height /= ...; }
settings.frame = frame;  // scene 尺寸 = slot 实际尺寸
```

**③ `MultitaskSupport/AppSceneViewController.m:357-359`** — `contentView.bounds` 跟着设成 slot 尺寸（不要除以 ratio）。

同时把 `DecoratedAppSceneViewController.m:543-553` legacy 路径里的 `frame.size.width /= ratio`（545-547 行）一并去掉。

> `[LOCAL CHANGE]` 那两段注释（`AppSceneViewController.m:294-301` 和 `348-356`）是为"bounds 全屏 + transform 缩放"服务的，改完后重写，别留着误导。

### 为什么是改 MultitaskSupport 这层，不是 hook 更底层

问题根源是我们**主动**给 `_UISceneHostingView` 套了 transform——这是 MultitaskSupport 自己的决策。拿掉 transform，系统行为回到正常状态，不用 hook BackBoard 私有触摸转发（那层没有稳定 API，跨 iOS 版本必崩）。

### 备选（不推荐）

如果坚持"全屏渲染 + 缩小显示"的锐度，要在 guest 进程侧 hook 每个 `UITouch.locationInView:` 做坐标重映射，工程量大且容易搞坏别的手势，和系统抢坐标 iOS 升级随时崩。**不推荐。**

---

# Bug 2：左右换边整屏黑一下闪屏

## 一句话根因

换边时 `DecoratedStageContainerView`（每张卡片的外壳，**背景色纯黑**，`DecoratedAppSceneViewController.m:88`）的 frame 从左半屏瞬间跳到右半屏，内部 `_UISceneHostingView` 的 on-screen 几何跨半屏跳变，触发系统远程渲染合成器对托管表面做 detach→reattach。重建那一帧 surface 没有后备内容，**露出的就是卡片外壳自己的 `.black` 背景**。

紧接着调的 `commitMainWindowGeometry()` → `applyViewGeometryToSettings:` 把新几何通过 XPC push 给 BackBoard，是把这次 surface 重建"坐实"的扳机。

**这不是 UIView 动画问题，是跨进程远程渲染 surface 的生命周期问题，所以 `performWithoutAnimation` / `layoutIfNeeded` / 瞬时无动画全都管不到——它们只决定黑多久，不决定有没有黑。**

## 逐层证据

### 第 1 层：换边时到底跑了什么【已确证】

入口 `MultitaskDockView.swift:2387` `toggleLayoutHandedness()`：
```swift
MultitaskStageLayout.isMirrored.toggle()
relayout(animated: true, mirroring: true)
```

`geometry()`（`MultitaskStage.swift:65-87`）换边时 bounds/safeArea 都没变，unit/sideHeight/origin 全部不变，唯一变的是 `slotFrame`（92-108 行）里主窗的 x：
```swift
let x = isMirrored ? g.origin.x + g.unit : g.origin.x
```
主窗整体向右平移 1 个 unit 宽，副窗栈从最右跳到最左。**size 完全不变，scale 完全不变。** geometry 不会返回 .zero/invalid。

### 第 2 层：mirroring 最小重铺分支【已确证】

`MultitaskDockView.swift:1195-1223`：
```swift
if mirroring {
    UIView.performWithoutAnimation {
        for (index, app) in self.apps.enumerated() {
            let frame = MultitaskStageLayout.slotFrame(...)
            view.frame = frame                              // ← 卡片外壳 frame 跳变
            view.layer.maskedCorners = ...
            self.windowShadowCasters[app.appUUID]?.frame = frame
        }
        for app in self.apps {
            app.view?.layoutIfNeeded()
        }
    }
    self.commitMainWindowGeometry()                          // ← 主动 push 几何
}
```

**这个分支没有**对 `_UISceneHostingView` 做 removeFromSuperview/addSubview/重新 attach，只改了 `DecoratedStageContainerView` 的 frame 和 cornerMask。也**没有**调 `applyStageFrame`，没有跑 chromeUpdates/backdropUpdates/z-order 重排。是刻意做的"最小重铺"。

### 第 3 层：卡片外壳是纯黑底【已确证】

`DecoratedAppSceneViewController.m:88`：
```objc
container.backgroundColor = UIColor.blackColor;
```
`masksToBounds = YES`（91 行）。只要 hosting view 那一帧没有内容，露出来的就是这层黑。

容器层级（84-102 行）：
```
DecoratedStageContainerView  (backgroundColor = .black)
├── appSceneVC.view          (autolayout pin 到 container 四边)
│   └── contentView          (= _UISceneHostingView, transform = scaleRatio)
├── tapShield
├── frozenFrameView          (UIImageView, 默认 hidden=YES)  ← 已有遮罩设施
└── launchPlaceholder        (黑底, 默认 hidden=YES)
```

### 第 4 层：commitMainWindowGeometry 那一脚【已确证】

`MultitaskDockView.swift:1714-1719` → `AppSceneViewController.m:532-555` `commitHostedGeometry`：
```objc
[self updateFrameWithSettingsBlock:nil];  // 换边 size 不变，这层 no-op
[self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
    settings.foreground = YES;
    if(@available(iOS 19.0, *)) {
        if([self.contentView isKindOfClass:PrivClass(_UISceneHostingView)]) {
            [(id)self.contentView applyViewGeometryToSettings:settings];  // ← 真发 XPC
        }
    }
}];
```
`applyViewGeometryToSettings:` 把 hosting view 当前屏幕位置写进 scene settings，通过 `FBScene updateSettingsWithBlock:` 发给 BackBoard。

### 第 5 层：仓库作者自己已经观察到"push settings 会重连 surface 黑闪"【已确证】

四处注释实锤：
- `DecoratedAppSceneViewController.m:15-18`："pushing an identical settings.frame while the cross-process surface is sliding made it flash black"
- `DecoratedAppSceneViewController.m:356-359`："re-pushing the same settings.frame mid-slide briefly reconnects the cross-process render surface and showed up as a black flash"
- `MultitaskDockView.swift:1646-1649`："re-pushing scene settings would only force a cross-process surface reconnect — exactly the black flicker"
- `MultitaskDockView.swift:1695-1699`："re-committing the hosted scene mid-flight reconnects the render surface and brings the black flash"

### 第 6 层：host 端截远程 view 是黑的【已确证】

`LCStageIPC.h:103-104`：
> "The host cannot snapshot a hosted scene's cross-process pixels (they render black)"

**这直接排除了"在 host 端对 hostingView 做 snapshotViewAfterScreenUpdates 覆盖"这条路——截出来就是黑的，盖上去等于盖一块黑。**

### 第 7 层：已有 frozenFrameView 机制就是为了防 surface 重连露黑【已确证】

`DecoratedAppSceneViewController.m:29` 的 `frozenFrameView`，注释（255-256 行）：
> "The black container backing must never be exposed while the hosted surface is reconnected."

这个 frozen frame 不是 host 端截的，是**guest 进程自己**用 `drawViewHierarchyInRect:afterScreenUpdates:NO` 画自己的 window 存成 JPEG 到 App Group（`TweakLoader/UIKit+GuestHooks.m:336-365` `LCGuestCaptureFrozenFrame`），host 再从磁盘读回来盖上去。它现在只在"宿主进后台/解锁回来/恢复现场"时触发，**换边时没走这条路**。

## 黑帧扳机到底是什么【高度怀疑】

两种可能，结果一样（中间一帧 surface 无后备存储）：
- **可能 1**：hosting view layer 的 on-screen frame 跨半屏瞬时跳变，render server 认为 destination quad 变太多，tear down 旧 render layer 建新的，新 layer 第一帧还没收到 guest 帧。
- **可能 2**：`applyViewGeometryToSettings:` XPC 让 BackBoard 同步重建 surface。仓库注释反复说"re-pushing settings reconnects surface"，倾向这一种。

**判断**：两者都有份。即便删掉 `commitHostedGeometry`，只要 `view.frame` 那一下让 hosting view 跨屏跳变，render server 提交 layer tree 时仍可能重建。删掉 push 只是少一个 XPC 扳机，闪会更短但不会消失——这跟你观察到的"commit 后只是闪得更快、没消失"一致。

## 为什么之前的尝试都没用

| 尝试 | 为什么没用 |
|---|---|
| 瞬时无动画 | 黑帧不是动画插值中间帧，是 surface 重建的真实空帧。动画快慢只决定黑多久 |
| `performWithoutAnimation` | 只冻结 Core Animation 事务级动画。surface 重建在 render server/BackBoard 进程里，不在我们的 CATransaction 里 |
| 同事务 `layoutIfNeeded` | 只逼 autolayout 跑完。跑完之后 hosting view 新 frame 才提交给 render server——提交那一下才是触发重建的那一下 |
| 换边后 `commitMainWindowGeometry()` | 为修触摸区域所必需，但额外发了一次 `applyViewGeometryToSettings:` XPC，把"可能闪"变成了"必闪" |

## 修复方案：复用 guest 自摄冻结帧盖住换边瞬间

### 核心矛盾
- **不能不 push 几何**：不 push BackBoard 不知道主窗换了槽位，触摸区域还是旧的（`MultitaskDockView.swift:1219-1222` 已记录）。
- **不能让 surface 裸奔那一帧**：露出 `.black` 就是闪屏。
- **不能在 host 端截图盖**：`LCStageIPC.h:103` 已证明截出来是黑的。

### 方案 A（推荐，改动最小）：换边期间用 guest 自摄冻结帧盖住整卡

仓库已有全套设施，只是换边时没调。三步：

1. **换边前**（`toggleLayoutHandedness` 改 `isMirrored` 之后、`relayout` 之前），通过已有的 Darwin 通知通道（`LCStageIPC.h` 里的 `CFNotificationCenter`，参考 `LCStageHostBackgroundingNotificationName` 的 post 方式）通知主窗 guest："立刻自己拍一帧写盘"。
   - 触发点：`MultitaskDockView.swift:2387`
   - guest 端在 `TweakLoader/UIKit+GuestHooks.m` 监听，同步调 `LCGuestCaptureFrozenFrame(dataUUID)`。同进程内 `drawViewHierarchyInRect:` 毫秒级，赶得上。

2. **换边那一下**，在 mirroring 分支改 frame 之前，把主窗（及副窗，因为副窗也跳）的 `frozenFrameView.hidden = NO`、`alpha = 1`。`frozenFrameView` 在容器里 z 序本来就在 contentView 之上（`DecoratedAppSceneViewController.m:143` `insertSubview:belowSubview:_tapShield`），直接盖得住。

3. **换边完成后**，收到 guest 的 `LCStageFrameReady` Darwin 通知（已有通道，`UIKitHooks.m:205` `LCStageFrameReadyCallback`）后，调 `hideFrozenFrameAnimated:` 淡掉。

**为什么通**：
- 盖的图是 guest 自己画的真帧，不是 host 端截的黑屏；
- `frozenFrameView` 是普通 UIImageView，在我们进程的 layer tree 里，不经过远程 surface，那一帧一定有内容；
- surface 重建时用户看到的是 frozenFrameView 上的旧帧，不是黑底；
- surface 回来、guest 出新帧后，frame-ready 通知触发淡入淡出，无缝。

**代价**：换边瞬间内容冻结约 1-2 帧。换边本来就是瞬时跳变，用户感知不到这 1-2 帧——感知到的是"不再黑一下"。

### 方案 B（兜底）：换边期间盖普通 UIView 遮罩

如果不想加新的 Darwin 通知往返，在 mirroring 分支改 frame 前，每个卡片外壳上 addSubview 一个普通 UIView（背景色取最近一次成功冻结帧的平均色，或配合快速淡入淡出）。关键是遮罩必须是**本地 UIView**，不能是远程 surface。纯色遮罩会看到色块闪一下，比黑好但不理想，只在方案 A 来不及刷新时兜底。

### 方案 C（治本但工作量大）：hook `_UISceneHostingView` 避免 surface 重建

观测私有 layer 属性（`contentLayer`/`hostedLayer`/`_remoteLayer`，名字要 class-dump 对应 iOS 版本），换边时用 transform 平移而不是改 frame，或 hook `applyViewGeometryToSettings:` 延迟 push。风险：私有 API 跨 iOS 版本漂移大（仓库头文件已有 iOS 17/18/19/27 分支差异），维护成本高。**建议先做方案 A，残留再考虑 C。**

### 关于"能不能避免 surface detach/reattach"

**在当前 hosting 架构下避免不了。** 官方 LiveContainer 多任务版同样有这个 bug，说明这是 `_UISceneHostingView` 远程托管合成机制本身的行为。仓库作者已经把能省的 settings push 都省了（`lastPushedGeometryKey` 跳过同几何、`armGeometryCommitIfNeeded` 不给 mirror arm、延时二次 commit 用 layoutToken 守卫拒绝 mirror 后 push），还是闪。所以现实做法不是"不让 surface 重建"，而是"重建那一帧别让用户看见黑"——方案 A 的思路。

---

# 附带：dock 偶发从右侧被遮挡大半

**跟闪屏是两个独立问题，不要混在一起修。**

### 根因【高度怀疑】

`MultitaskStage.swift:175-182` `dockFrame` 左右对称，不随 `isMirrored` 变。dockView 是 `UIHostingController.view`（SwiftUI），被 addSubview 到 keyWindow。

mirroring 分支（`MultitaskDockView.swift:1195-1218`）**刻意不跑 chromeUpdates**，注释（1185-1188 行）：
> "Writing it inside the spring nevertheless re-ran the SwiftUI dock hosting layout and faded the whole dock block for the flight; freeze it instead."

作者已经发现"写 dock.frame 会触发 SwiftUI hosting 重新布局，整个 dock 会闪"，所以 mirroring 分支干脆不写 dock.frame。

但 dockView 的 `translatesAutoresizingMaskIntoConstraints` 默认 YES、**autoresizingMask 为空**。window.bounds/safeArea 在过渡态（stage 第一次进入、旋转等）时 dock 不会自动跟随，要等下一次非 mirroring 的 `performLayout` 跑 chromeUpdates 才修。偶发遮挡就是 dockView.frame 用了偏窄/偏右的 bounds 算出来，右侧露出下层的 systemGray5/卡片黑底，看起来像被遮。

### 修复方向
- 给 `dockHost.view` 设 `autoresizingMask = [.flexibleWidth, .flexibleTopMargin]`，让它在 window bounds 变化时自动跟随。
- 或在 mirroring 分支结束后下一帧（`DispatchQueue.main.async`）补一次 dock frame 校正。

---

# 修复优先级与实施顺序建议

1. **先修 Bug 1（长按录音）**：去掉 transform 三处改动，改动集中、风险低、效果确定。改完后主窗触摸坐标 1:1，长按应该直接好。
2. **再修 Bug 2（换边闪黑）**：复用 frozenFrameView 机制，加一个 Darwin 通知触发 guest 自摄 + 换边时显示遮罩 + frame-ready 后淡掉。改动在 MultitaskSupport 这层，不碰底层 hook。
3. **最后修 dock 遮挡**：补 autoresizingMask，一行改动。
4. **诊断浮层 diagLabel**：两个 bug 都定位后删除。

> 注意：Bug 1 的修复（去掉 transform）会改变 guest 渲染分辨率，可能影响 Bug 2 中 surface 重建的触发条件（因为 hosting view 几何变了）。建议 Bug 1 改完后重新观察 Bug 2 的闪屏程度，再决定方案 A 的具体实现细节。

---

# 关键代码位置速查

| 作用 | 文件:行 |
|---|---|
| **长按：contentView 套 transform（要删）** | `MultitaskSupport/DecoratedAppSceneViewController.m:383` |
| **长按：frame.size /= scaleRatio（要删）** | `MultitaskSupport/AppSceneViewController.m:298-301` |
| 长按：contentView.bounds 设未缩放尺寸（要改） | `MultitaskSupport/AppSceneViewController.m:357-359` |
| 长按：主窗 scaleRatio = 3/4 ≈ 0.745 | `MultitaskSupport/MultitaskStage.swift:111` |
| 长按：guest 端 sendEvent 主窗透传无坐标转换 | `TweakLoader/UIKit+GuestHooks.m:798-884` |
| 长按：官方注释确认 split 主窗触摸区 stale | `MultitaskSupport/MultitaskDockView.swift:1678-1701` |
| **闪黑：卡片外壳纯黑背景（黑帧出口）** | `MultitaskSupport/DecoratedAppSceneViewController.m:88` |
| 闪黑：换边最小重铺分支 | `MultitaskSupport/MultitaskDockView.swift:1195-1223` |
| 闪黑：commitHostedGeometry + applyViewGeometryToSettings | `MultitaskSupport/AppSceneViewController.m:532-555` |
| 闪黑：作者注释"push settings 重连 surface 黑闪" | `DecoratedAppSceneViewController.m:15-18, 356-359`；`MultitaskDockView.swift:1646-1649, 1695-1699` |
| 闪黑：host 端截远程 view 是黑的 | `MultitaskSupport/LCStageIPC.h:103-104` |
| 闪黑：guest 自摄冻结帧（可复用） | `TweakLoader/UIKit+GuestHooks.m:336-365` |
| 闪黑：host 端 frozenFrameView 遮罩（已存在） | `MultitaskSupport/DecoratedAppSceneViewController.m:137-150, 237-269` |
| 闪黑：frame-ready Darwin 通知通道 | `MultitaskSupport/UIKitHooks.m:205-213` |
| dock：mirroring 分支刻意不写 dock.frame | `MultitaskSupport/MultitaskDockView.swift:1185-1192` |
