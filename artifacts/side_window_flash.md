# 副窗换边闪烁根因分析

> 只读代码分析，未改仓库。结论先行，理由锚定文件:行号。

---

## 一句话结论

**主窗和副窗在 mirroring 弹簧动画里做的事几乎一模一样，唯一区别是动画落地那一下：主窗多跑了一次 `commitHostedGeometry()`（把 hosting view 的屏幕位置写进 BackBoard），副窗没跑。** 高度怀疑就是这一下缺失，让 BackBoard 里记录的副窗 surface 位置还停在旧槽位，系统在落地后下一帧检测到不一致、做了一次 surface geometry 重新同步——这一帧就是副窗竖列"快速闪一下"。

主窗因为落地那一下同步 push 了新位置，BackBoard 跟 layer tree 一致，不需要纠正，所以不闪。

---

## 已确证的事实（逐行对比）

### 1. mirroring 分支现在长什么样

`MultitaskDockView.swift:1177-1209`：

```swift
if mirroring {
    deferCornerMasks = true
    layoutToken &+= 1
    let token = layoutToken
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
                view.frame = frame                              // ← 只写了 container view 的 frame
                self.windowShadowCasters[app.appUUID]?.frame = frame
            }
        }
    ) { [weak self] _ in
        guard let self, self.layoutToken == token else { return }
        for (index, app) in self.apps.enumerated() {
            app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
        }
        self.commitMainWindowGeometry()   // ← ★ 只推主窗，副窗没推
    }
}
```

**动画块里对主窗和副窗做的事完全一样**：都是 `view.frame = frame`（container view 的 frame 弹簧插值）+ shadow caster frame。没有区别对待。

**completion 里的区别**：
- corner mask 换边：对所有 apps 都做了（1203-1205）
- `commitMainWindowGeometry()`：**只对主窗**（1208）

### 2. 副窗没有被后台/挂起（排除假设 1）

`AppSceneViewController.m:145-159`，每个 scene 创建时：

```objc
void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
    settings.canShowAlerts = YES;
    settings.cornerRadiusConfiguration = ...;
    settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
    settings.foreground = YES;          // ← 所有窗口都是 foreground
    settings.level = 1;
    ...
};
```

`DecoratedAppSceneViewController.m:530-531` 注释明确写：

> "Every window's scene stays foreground so all four apps keep rendering live. Never background the side scenes here: a backgrounded hosted scene freezes on its last frame, defeating the live stage."

副窗触摸隔离是在 **guest 进程内部**做的（`UIKitHooks.m` 的 sendEvent hook + `TweakLoader/UIKit+GuestHooks.m:798` 的 `hook_lcStage_sendEvent`），guest 进程完全活跃、持续渲染，只是触摸事件在它自己的 sendEvent 里被吞掉。**副窗的渲染 surface 没有被系统挂起或节流。**

### 3. tapShield / launchPlaceholder / frozenFrameView 不是元凶（排除假设 2）

容器层级（`DecoratedAppSceneViewController.m:84-165`），从下到上：

```
DecoratedStageContainerView  backgroundColor=.black, masksToBounds=YES  ← :88
├── appSceneVC.view (contentView = _UISceneHostingView, autolayout pin 四边)  ← :94-102
├── frozenFrameView  (UIImageView, hidden=YES 正常时)  ← :137-150
├── launchPlaceholder (黑底icon+spinner, hidden=YES 正常时)  ← :154-165
└── tapShield  (clearColor, 透明)  ← :107-117
```

- **tapShield**：`backgroundColor = clearColor`（:109），完全透明，只靠 `hitTest` override（:42-50）拦截触摸。它在 `applyStageFrame:349` 里设 `hidden = interact || maximized`，mirroring 时 `isMainWindow` 不变（apps 数组顺序不变），所以 tapShield 的 hidden/alpha 不变。**透明 view 不闪。**
- **launchPlaceholder / frozenFrameView**：正常运行时 `hidden = YES`，mirroring 分支完全不碰它们。
- mirroring 分支里没有任何地方对这三个 cover view 做 alpha/hidden 切换。

### 4. corner mask 换边主副窗一视同仁（排除假设 4）

`MultitaskStage.swift:198-213` `maskedCorners(index:count:)` 由全局 `isMirrored` 驱动。mirroring 时 `isMirrored` 已经翻转（`toggleLayoutHandedness:2374` 在 relayout 前翻的），completion 里写 `maskedCorners(index, count:)` 时拿到的是新值。

- 主窗（index 0）：左圆角 → 右圆角
- 副窗 index 1：右上圆角 → 左上圆角
- 副窗 index 3：右下圆角 → 左下圆角
- 副窗 index 2：无圆角（中间）

**这个 corner mask 切换对主窗和副窗都做了**（completion 里 for 循环对所有 apps）。如果 corner mask 切换本身会闪，主窗也该闪。但主窗不闪——所以 corner mask 不是副窗单独闪的原因。

### 5. z 序在 mirroring 时不变（排除假设 4 的 z 序部分）

mirroring 分支没有跑 `update` 闭包，所以没有跑 `bringSubviewToFront` 重排（:1074-1078）。但 mirroring 不改 apps 数组顺序，z 序本来就对（主窗在最前，副窗竖列在后面）。cards 之间不重叠（tile 排列），z 序不影响视觉。

### 6. shadow caster 是本地 view，不涉及远程 surface

`shadowCaster`（:1296-1345）是一个透明 UIView，只带 shadow，在 card 下面。动画块里写它的 frame 跟着弹簧走。它不 hosting 远程内容，不会闪。

---

## 根因判断：副窗缺了落地那次 geometry commit

### commitHostedGeometry 到底干了什么

`AppSceneViewController.m:531-554`：

```objc
- (void)commitHostedGeometry {
    if(!self.presenter || !self.usesHostingControllerAPI || _shouldIgnoreSceneUpdates) return;
    self.shouldSkipDebounceOnce = YES;
    [self updateFrameWithSettingsBlock:nil];   // ① size 不变 → no-op（见下）

    [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.foreground = YES;
        settings.deactivationReasons = 0;
        if(@available(iOS 19.0, *)) {
            if([self.contentView isKindOfClass:PrivClass(_UISceneHostingView)]) {
                [(id)self.contentView applyViewGeometryToSettings:settings];  // ② ★ 真 XPC push
            }
        }
    }];
}
```

**① 是 no-op**：`updateFrameWithSettingsBlock:` → `updateSettingsWithBlock:`（:320-364）在 modern hosting 路径下只写 `contentView.bounds`，且 :357 有 guard——size 不变就不写。mirroring 时 size 不变，bounds 不动，不 forward 给 scene。

**② 是关键**：`applyViewGeometryToSettings:`（`UIKitPrivate+MultitaskSupport.h:307`）是 `_UISceneHostingView` 的私有方法，iOS 19+。它把 hosting view 在 window 中的**实际 on-screen position** 写进 scene settings，BackBoard 据此配置远程 IOSurface 的合成参数。

### 为什么主窗不闪、副窗闪

动画飞行过程中：container view.frame 弹簧插值 → `container.layer.position` 每帧连续变化 → hosting view（contentView）作为 subview 跟着 GPU 端 layer tree 连续移动 → 远程 surface 跟着连续走。这就是改成弹簧后不黑的原因（`can_animation_fix_flash.md` 里已经论证过：连续 position 给 render server 提供了合法的中间帧）。

**但 BackBoard 里记录的 surface position 是另一条路**。它不是每帧从 layer tree 读的，而是由 `applyViewGeometryToSettings:` 主动写进去的。飞行中没人写它，它一直停在上一次 commit 的旧槽位。

动画落地那一刻：

| | 主窗 | 副窗 |
|---|---|---|
| layer tree 里 hosting view 位置 | 新槽位（动画已结束） | 新槽位（动画已结束） |
| BackBoard settings 里记录的位置 | **新槽位**（completion 里 ② 刚 push 过） | **旧槽位**（没人 push） |
| 下一帧 render server 用谁画 | 两边一致，无缝 | 不一致，需要同步 |

主窗：completion 里同步跑了 ②，BackBoard 在动画结束那一帧就知道新位置，下一帧直接用新位置画，不需要"纠正"。

副窗：completion 里没跑 ②。BackBoard 里还是旧位置。系统在落地后的下一个 runloop tick / surface 同步周期里，检测到 hosting view 在 layer tree 里的实际位置跟 settings 里记录的位置不一致，触发一次 surface geometry 重新同步。这次同步会把 IOSurface 的合成 rect 从旧槽位改到新槽位——**改的那一帧 surface 短暂用旧配置画了一下（或重新配置时露出 container 的黑底 `:88`），就是"快速闪一下"。**

主窗因为落地那一下提前把 settings 写成新位置，系统的自动同步发现 settings 已经是最新的，不做事，所以不闪。

### 为什么之前注释说"副窗不需要 commit"

`AppSceneViewController.m:529-530`：

> "Side windows never need this: their touches are quarantined inside the guest process, not routed through the region table."

这个注释只考虑了**触摸区域**。副窗的触摸在 guest 进程内被吞掉（`UIKit+GuestHooks.m:849`），不走 BackBoard 的 touch region table，所以从触摸角度确实不需要 commit。

但 `applyViewGeometryToSettings:` 写进 settings 的不只是触摸区域——它写的是 hosting view 的**整个 on-screen geometry**（position + bounds），BackBoard 用它配置 surface 合成。注释没料到这一步同时也同步了 surface 位置。

---

## 已排除的假设

| 假设 | 排除理由 |
|---|---|
| 副窗 scene 被后台/deactivated/挂起 | `:149` 所有窗口 `foreground=YES`；`:530` 注释明确不 background 副窗 |
| tapShield 在换边时 alpha/hidden 切换 | tapShield 是 clearColor 透明 view；`applyStageFrame:349` 设的 hidden 只取决于 `isMainWindow`，mirroring 时 index 不变 |
| launchPlaceholder / frozenFrameView 显隐 | 正常运行时 hidden=YES，mirroring 分支不碰它们 |
| corner mask 换边闪 | 对主副窗都做了，主窗不闪 |
| z 序变化 | mirroring 不改 apps 顺序，cards 不重叠 |
| shadow caster 闪 | 本地透明 view，不 hosting 远程内容 |
| 副窗被 RBS 暂停 | guest 进程持续渲染（视频/动画/audio 都在跑），只是触摸被吞 |

---

## 最小改法

在 mirroring 分支 completion 里，对**所有窗口**（不只是主窗）都跑一次跟主窗一样的 geometry commit。因为 size 不变，`updateFrameWithSettingsBlock` 是 no-op，真正起作用的只有 ② `applyViewGeometryToSettings:` 那步 XPC push——它把 hosting view 的新位置写进 BackBoard，让系统不需要事后纠正。

### 具体改法

文件：`MultitaskSupport/MultitaskDockView.swift`，mirroring 分支 completion（约 :1201-1209）。

现在：

```swift
) { [weak self] _ in
    guard let self, self.layoutToken == token else { return }
    for (index, app) in self.apps.enumerated() {
        app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
    }
    // Geometry push after the spring lands: re-derive the main window's touch region at
    // its new slot. No foreground blip, only settings.
    self.commitMainWindowGeometry()
}
```

改成（对所有窗口 commit，不只是主窗）：

```swift
) { [weak self] _ in
    guard let self, self.layoutToken == token else { return }
    for (index, app) in self.apps.enumerated() {
        app.view?.layer.maskedCorners = MultitaskStageLayout.maskedCorners(index, count: count)
        // Push every window's settled geometry into its hosted scene. The main window needs
        // this for its touch region; the side windows need it too, otherwise BackBoard keeps
        // the surface composited at the OLD slot until the system's own next sync — that one
        // re-sync is the one-frame side-column flash. Size is unchanged so this is a metadata-
        // only push (no IOSurface reallocation), safe for all four.
        (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?
            .appSceneVC.commitHostedGeometry()
    }
}
```

### 为什么安全

- `commitHostedGeometry` 里 ① `updateFrameWithSettingsBlock` 在 size 不变时是 no-op（`:357` guard）。
- ② `applyViewGeometryToSettings:` 只写 settings metadata（surface position），不重分配 IOSurface buffer（size 没变）。
- `settings.foreground = YES` / `deactivationReasons = 0` 本来就是当前值，写了等于没写。
- 主窗已经这么做了，验证过不闪、不黑、不断音。副窗跟着做同理。

### 风险

- 这会多发 3 次 XPC settings push（副窗数量）。每次 push 是跨进程调用，但 size 不变、buffer 不重分配，开销极小。
- 如果 iOS 19 以下（`applyViewGeometryToSettings:` 不可用），② 是 no-op，commit 退化为 ① no-op，等于什么都没做——安全降级。

---

## 区分"已确证"和"高度怀疑"

**已确证：**
1. mirroring 分支 completion 里只对主窗调了 `commitMainWindowGeometry()`，副窗没调。
2. `commitHostedGeometry` 里 `applyViewGeometryToSettings:` 是一次真 XPC push，把 hosting view 的 on-screen position 写进 BackBoard scene settings。
3. 所有窗口 scene 都是 foreground=YES，副窗没被后台。
4. tapShield/cover view/corner mask/z 序/shadow caster 在 mirroring 时对主副窗一视同仁（或透明/不碰），不是副窗单独闪的原因。

**高度怀疑（未从代码 100% 确证，因为 `_UISceneHostingView` 是私有 API 黑盒）：**
1. `applyViewGeometryToSettings:` 写进 settings 的 surface position，在飞行中没人更新，停在旧槽位。
2. 动画落地后，系统在下一次 surface 同步时检测到 layer tree 位置跟 settings 不一致，触发一次 surface 重新合成——这一帧就是副窗闪。
3. 主窗因为 completion 里主动 push 了新位置，系统不需要事后纠正，所以不闪。

**验证方法**（不改业务逻辑，先观测）：在 mirroring 分支 completion 里临时加一行对副窗也调 `commitHostedGeometry()`，看副窗闪是否消失。如果消失，根因坐实；如果还闪，说明 surface position 不是元凶，需要继续查（下一个嫌疑是 corner mask 切换对远程 layer 的 mask 重算）。
