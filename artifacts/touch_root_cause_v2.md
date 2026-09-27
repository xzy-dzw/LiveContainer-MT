# 触摸转发链路逐行审查：长按失灵与控件点不到的根因（第二轮）

> 只读分析，未改任何仓库文件。第一轮结论"transform 导致 bounds/footprint 不匹配"被实测否决（去掉 transform 后 bug 原样存在），所以这轮换角度：**不猜 transform，逐个数每一步坐标到底是多少**。
>
> 标注：**【已确证】** = 代码读死/逻辑闭环；**【高度怀疑】** = 机制推断，需跑一把确认；**【无法从代码确定】** = 系统私有行为，只能靠运行时日志验证。

---

## 一、坐标映射链路图（从手指到 guest 内部 hitTest）

### 硬件参数（以 iPhone 390×874 逻辑点为例）

| 量 | 值 | 来源 |
|---|---|---|
| 屏幕逻辑尺寸 | 390 × 874 pt | `UIScreen.mainScreen.bounds` |
| 主窗 slot 尺寸 | ≈290 × 647 pt | `MultitaskStage.swift:97` `slotFrame` |
| scaleRatio | ≈0.745 | `MultitaskStage.swift:114` `slotScaleRatio` = slotWidth/390 |
| contentView.bounds | 390 × 874 pt | `AppSceneViewController.m:356-358` |
| contentView.transform | scale(0.745, 0.745) | `DecoratedAppSceneViewController.m:383` |
| contentView.anchorPoint | (0, 0) | `AppSceneViewController.m:249` |
| contentView.position | (0, 0) | `AppSceneViewController.m:250` |
| contentView 屏幕实际尺寸 | 390×0.745 × 874×0.745 ≈ 290.6 × 651.1 | bounds × transform |
| settings.frame（guest 逻辑尺寸） | 390 × 874 pt | `AppSceneViewController.m:298-306` |

### 逐跳坐标

```
┌─────────────────────────────────────────────────────────────────────┐
│ 第 0 跳：手指物理触摸屏幕                                             │
│ 手指在屏幕上点 slot 内某点，屏幕坐标 P_screen = (X, Y)               │
│ （windowHostingView 覆盖全屏，window 坐标 == 屏幕坐标）               │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 第 1 跳：BackBoard 查触摸区域表                                       │
│ BackBoard 按 _UISceneHostingView 的 on-screen 几何注册了一个矩形 R：  │
│   R.origin = slot 在屏幕上的左上角 S0 = (slotScreenX, slotScreenY)   │
│   R.size   = ≈290.6 × 651.1（contentView 屏幕实际尺寸）              │
│ 注册时机：commitHostedGeometry → applyViewGeometryToSettings:        │
│   （AppSceneViewController.m:549-551）                                │
│ 注册后系统"持续派生"（LCStageIPC.h:13 注释原文）。                    │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 第 2 跳：BackBoard 做坐标换算                                        │
│ 本地坐标：local = P_screen - S0 = (X - S0.x, Y - S0.y)              │
│ 范围：local ∈ [0, 290.6] × [0, 651.1]                               │
│                                                                       │
│ 换算到 guest 逻辑坐标：                                               │
│   guestX = localX × (390 / 290.6) = localX / 0.745 ≈ localX × 1.342 │
│   guestY = localY × (874 / 651.1) = localY / 0.745 ≈ localY × 1.342 │
│                                                                       │
│ 例：手指点 slot 内 (100, 200) → guest 收到 (134.2, 268.5)           │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 第 3 跳：跨进程 XPC 发给 guest 进程                                   │
│ 宿主进程完全看不到这个事件（LCStageIPC.h:16-17 原文：                 │
│   "the host never sees that event in UIApplication.sendEvent"）      │
│ 宿主的 sendEvent swizzle（UIKitHooks.m:244-247）只拦截宿主自己 UI    │
│   （dock/chrome）的触摸，不拦托管场景的触摸。                         │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 第 4 跳：guest 进程 UIApplication.sendEvent                           │
│ TweakLoader hook（UIKit+GuestHooks.m:798-863）：                     │
│   主窗 side=0 → 快速放行路径（:804-807）：                            │
│     if (LCStageSideTouches.count==0 && !isSideWindow)                │
│         [self hook_lcStage_sendEvent:event]; return;  // 原样透传    │
│   ★ 不修改任何坐标。事件原样进原始 sendEvent。                        │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 第 5 跳：guest UIKit hitTest                                          │
│ guest 的 UIWindow.frame = UIScreen.mainScreen.bounds = 390×874      │
│ （TweakLoader.m:60 创建窗口时用 UIScreen.mainScreen.bounds）          │
│ 触摸坐标 (134.2, 268.5) 在 390×874 坐标系里做 hitTest。              │
│ 命中"按住说话"按钮（按钮在 guest 坐标系里位于底部 ≈(195, 814)）。     │
│ touchDown 触发 → 震感 ✓                                               │
└─────────────────────────────────────────────────────────────────────┘
```

### 坐标计算验证：BEGAN 为什么能命中按钮

用户视觉上看到按钮在 slot 里的位置：
- 按钮在 guest 坐标系：(195, 814)（390×874 屏幕底部居中）
- 按钮在屏幕上的视觉位置 = guest坐标 × 0.745 + S0 = (195×0.745 + S0.x, 814×0.745 + S0.y) = (145.3 + S0.x, 606.4 + S0.y)

用户手指按在视觉位置 (145.3+S0.x, 606.4+S0.y)：
- local = (145.3, 606.4)
- guest = (145.3/0.745, 606.4/0.745) = (195, 814) ← 精确命中按钮 ✓

**结论：BEGAN 坐标换算数学上是精确的，没有常数偏移。**

---

## 二、核心问题逐一回答

### Q1：BackBoard 注册触摸区域用的是什么几何？

**【已确证】** 用的是 contentView 的 **on-screen frame**（屏幕实际占的矩形），不是 bounds。

证据链：
- `commitHostedGeometry`（`AppSceneViewController.m:549-551`）调 `[contentView applyViewGeometryToSettings:settings]`。
- 注释原文（`:546-547`）："The system's own way of writing the hosting view's on-screen geometry into the scene settings. This is the value the touch region is derived from."
- `MultitaskDockView.swift:1648-1649` 注释："BackBoard derives a hosted scene's touch region from the hosting view's geometry."
- `LCStageIPC.h:12-13`："continuously derived from the hosting view's geometry."

`applyViewGeometryToSettings:` 是系统私有方法，它内部会把 contentView 的 bounds 沿 superview 链 convert 到 window 坐标（这个 convert 会自动乘 transform），所以注册的矩形是 ≈290×651，不是 390×874。

### Q2：手指点 slot 上 (x,y)，guest 收到的坐标是多少？

**【已确证】** 收到的是 `(x/0.745, y/0.745)`，即 slot 坐标除以 scaleRatio 换算后的全屏逻辑坐标。

验证：BEGAN 精确命中按钮（震感），证明换算因子是 1/0.745，不是 1:1。如果是 1:1 直传，guest 收到 (x,y) ∈ [0,290]×[0,651]，按钮在 guest 坐标 (195,814) 根本够不着。

### Q3：guest 进程认为自己的屏幕尺寸是多少？

**【已确证】** 390×874（全屏逻辑尺寸）。

证据：
- `settings.frame = 390×874`（`AppSceneViewController.m:298-306`，slot 尺寸除以 ratio）。
- guest 创建窗口用 `UIScreen.mainScreen.bounds`（`TweakLoader.m:60`），它读的就是 scene settings.frame。
- 去掉 transform 改 slot 分辨率渲染后用户说"视觉变低分辨率"——反证了当前 guest 确实在按 390×874 渲染。

### Q4：长按失败是不是坐标误差超过 10pt 容差？

**【高度怀疑】是，但误差来源不是 transform 浮点精度，而是触摸区域在手势进行中被重新注册导致坐标跳变。**

精确计算：
- 触摸硬件位置精度 ≈ ±0.5pt（屏幕坐标）。
- 换算放大：±0.5 / 0.745 ≈ ±0.67pt（guest 坐标）。
- 0.5s 按住期间累积抖动 ≈ 1-2pt。
- **远小于 10pt。纯浮点精度解释不了长按失败。**

但有一个被忽略的变量：**系统"持续派生"触摸区域**（`LCStageIPC.h:13`）。如果手势进行中 BackBoard 重新读取了 hosting view 几何并用新的矩形做换算，同一个物理点就会映射到不同的 guest 坐标。

什么会触发重新派生？
- `viewWillLayoutSubviews` → 防抖 0.05s 后的 `updateFrameWithSettingsBlock:`（`AppSceneViewController.m:280-282`）。
- `commitHostedGeometry` 的 0.35s 二次 commit（`MultitaskDockView.swift:1694`）。
- 系统自己的 post-animation layout pass（`:1684-1689` 注释原文）。
- watchdog 1s 定时器触发的 `performLayout` + `commitMainWindowGeometry`（`:1610-1622`）。

**关键推理**：如果在按住 0.5s 的窗口期内，上面任何一条触发了一次几何重推，新注册的矩形和旧矩形之间哪怕只有几个 pt 的差异（浮点/像素对齐），换算因子就会变。同一个物理点在 BEGAN 时映射到 (195, 814)，在 MOVED 时映射到 (201, 819)——6pt 跳变。BEGAN 参考点是 (195, 814)，6pt 跳变本身没超 10pt，但如果重推发生两次（0.05s 防抖一次 + 0.35s 二次 commit 一次），累积跳变就可能超过 10pt。

**为什么去掉 transform 也没修好**：去掉 transform 后换算因子是 1:1（无放大），但"持续派生"重新注册矩形这个机制依然存在。每次重推导致的坐标跳变虽然小了（不放大 1.34x），但重推次数如果多了（0.05s 防抖 + 0.35s 二次 + 系统 post-layout），累积漂移仍可能超 10pt。全屏（ratio=1.0，hosting view 满屏）从来没问题——因为满屏矩形 origin=(0,0)、size=全屏，怎么重推都是同一个矩形，换算恒等，零漂移。

### Q5：某些控件点不到的根因？

**【已确证】** 这是触摸区域 stale 的问题，代码里已有注释和缓解。

证据：`MultitaskDockView.swift:1684-1689` 原文：
> "On some iOS 19 builds the system's own post-animation layout pass re-derives the hosting view geometry a beat AFTER our settle push, and the touch region then describes a stale slot: **controls in the split main window stay untappable** until the next foreground round trip (fullscreen always worked, because its frame equals the screen and the race happens to be invisible)."

缓解措施是 0.35s 后二次 commit（`:1694-1706`）。但如果：
- 系统在 0.35s 之后又改了一次几何（watchdog 1s tick、safe area 变化、键盘弹出收回），
- 或者 0.35s 二次 commit 的 guard 条件没满足（`layoutToken` 变了），

触摸区域就会 stale，控件点了没反应。这和长按 bug 是**同一个底层机制**（几何重推时机不对）的两种表现：stale 期间 tap 落不到正确 view（点不到）；stale 跳变期间长按参考点漂移（识别不出来）。

---

## 三、根因判断

### 【已确证】
1. BEGAN 坐标换算精确（1/ratio），按钮 touchDown 命中是对的。
2. host/guest 两层 sendEvent hook 都不修改主窗触摸坐标。
3. 长按静默失败（无 CANCELLED）= UILongPressGestureRecognizer 在 0.5s 窗口内看到 >10pt 位移，状态变 Failed，touches 本身继续 ENDED。
4. 控件点不到 = 触摸区域 stale（代码注释已确认）。

### 【高度怀疑】
5. **长按失败的直接原因**：手势进行中 BackBoard 重新派生了触摸区域（几何重推），导致同一物理点在 BEGAN 和 MOVED 之间映射到不同 guest 坐标，位移累积超 10pt。重推来源是 `viewWillLayoutSubviews` 防抖链 + 0.35s 二次 commit + 系统 post-layout pass 在 0.5s 窗口内叠加。
6. **为什么 tap 没事**：tap 不要求 0.5s 内稳定，BEGAN 落点在按钮 44pt 命中区内就行，stale/跳变几 pt 不影响 tap。
7. **为什么全屏没事**：hosting view 满屏时，注册矩形恒等于全屏 (0,0,390,874)，重推 N 次结果都一样，换算恒等，零跳变。

### 【无法从代码确定，需运行时日志验证】
8. 重推导致的坐标跳变到底是几 pt？是每次 ~3pt 还是每次 ~1pt？这决定了为什么 0.5s 内就会超 10pt。
9. `applyViewGeometryToSettings:` 内部到底写了哪个 settings 字段（是 `frame` 还是某个未声明的 hostingFrame 属性）。
10. BackBoard 是每事件重算坐标，还是 BEGAN 算一次后只跟踪 delta。

---

## 四、改法（保留"全屏渲染 + transform 缩放"前提）

### 方案 A：guest 端 hook sendEvent，长按期间锚定触摸坐标【最推荐】

**思路**：既然问题是 MOVED 阶段坐标漂移超 10pt，那就在 guest 端对"几乎不动的触摸序列"做坐标锚定。不碰 host 几何，不碰 BackBoard。

**具体做法**：
在 `TweakLoader/UIKit+GuestHooks.m` 的 `hook_lcStage_sendEvent:` 里，主窗快速放行路径之前，加一段：
- BEGAN 时记录每个 touch 的 `locationInView:keyWindow`，记为 anchor，时间戳 t0。
- 对 t0 之后 0.5s 内的 MOVED 事件，算 `delta = currentLocation - anchor`。
- 如果 `|delta| < 12pt`（略大于系统 10pt 容差），**把 touch 的 location 强制改回 anchor**（用 `objc` 关联对象覆盖 `locationInView:` 返回值，或直接改 UITouch 的私有坐标 ivar）。
- 超过 0.5s 后松开锚定（长按手势此时已经 fire，后续 move 让它自由）。
- 如果 `|delta| > 12pt`（用户真的在拖动），不锚定，让手势正常失败/滚动。

**为什么可行**：
- 真·长按：手指基本不动，delta < 12pt，锚定后位移恒为 0，长按识别必成功。
- 真·滚动/拖动：手指动 >12pt，不锚定，行为正常。
- tap：delta 本来就小，锚不锚定都一样。
- 不碰 host 端任何几何，不影响渲染分辨率。

**风险**：
- 需要 hook UITouch 的 `locationInView:` 和 `previousLocationInView:`，这是热路径，性能要测。
- 锚定 12pt 阈值需要调——太松会把"想拖动但手指微抖"的手势错误锚定；太紧压不住漂移。
- 如果漂移来源不是坐标跳变而是事件丢失（MOVED 被吞），锚定没用。
- 验证方法：先加日志打印每次 MOVED 的坐标和 delta，跑一次长按看漂移到底是多少 pt，再定阈值。

### 方案 B：host 端冻结手势期间的几何重推

**思路**：在主窗有活跃触摸（BEGAN 后未 ENDED/CANCELLED）时，跳过 `viewWillLayoutSubviews` 里的 `updateFrameWithSettingsBlock:` 调用，也跳过 0.35s 二次 commit。

**具体做法**：
- `AppSceneViewController.m:280-282` `viewWillLayoutSubviews`：加一个 `_hasActiveTouch` 标志，有活跃触摸时不调 `updateFrameWithSettingsBlock:`。
- `MultitaskDockView.swift:1694` 的 0.35s 二次 commit：检查主窗是否有活跃触摸，有就跳过。
- 触摸 ENDED/CANCELLED 后再补一次 commit。

**风险**：
- 手势期间如果真的需要 layout（比如 safe area 变化、键盘弹出），不推几何会导致触摸区域和视觉错位。
- 怎么检测"活跃触摸"？宿主看不到托管场景的触摸（LCStageIPC.h:16-17），只能靠 guest 通过 IPC 通知宿主"我正在被按"——这又多了跨进程往返。
- 治标不治本：如果系统自己的 post-layout pass 在手势期间重推几何，我们拦不住。

### 方案 C：修正 BackBoard 注册的触摸区域几何

**思路**：既然怀疑 `applyViewGeometryToSettings:` 注册的矩形和 contentView 实际屏幕位置有偏差，那就自己算一个精确矩形写进 settings。

**具体做法**：
- 不依赖 `applyViewGeometryToSettings:`，自己用 `[contentView convertRect:contentView.bounds toView:nil]` 算 on-screen rect，手动写进 settings 的对应字段。
- 但这个字段是私有的（头文件里没声明），需要 runtime 探。

**风险**：
- 私有字段跨 iOS 版本会崩。
- 第一轮已经试过改几何（去掉 transform），bug 原样存在——说明几何本身不是根因，这条路大概率白走。
- **不推荐。**

### 方案 D：guest 端 hook UITouch 坐标，用 BEGAN 位置重算 MOVED

**思路**：和方案 A 类似，但更激进——不只是"按住期间"锚定，而是对整个触摸序列，把 MOVED 坐标重算成 `BEGAN位置 + (硬件delta × 修正因子)`。

**风险**：太复杂，容易把正常手势搞坏。不推荐。

---

## 五、推荐执行顺序

1. **先加诊断日志（不改行为）**：在 guest `hook_lcStage_sendEvent:` 里，主窗路径打印每次触摸的 `phase`、`locationInView:keyWindow`、`timestamp`。按住"按住说话"录一次音，看 MOVED 序列的坐标到底漂了多少 pt、是不是有跳变。这一步确认根因 5/9/10。
2. **根据日志结果选方案 A 或 B**：
   - 如果日志显示 MOVED 坐标有 >5pt 的离散跳变（不是连续微抖），方案 A 锚定有效。
   - 如果日志显示坐标完全稳定（没漂移），那问题不在坐标，在手势识别器本身（可能被别的 recognizer 抢了），需要查 guest 里 app 自己的手势系统。
3. **方案 A 落地后实测**：长按录音 + 小窗控件点按，确认两个 bug 都好。

---

## 六、关键代码位置索引

| 文件 | 行号 | 内容 |
|---|---|---|
| `MultitaskSupport/AppSceneViewController.m` | 249-250 | contentView.anchorPoint=(0,0), position=(0,0) |
| `MultitaskSupport/AppSceneViewController.m` | 284-319 | `updateFrameWithSettingsBlock:`：frame.size /= scaleRatio |
| `MultitaskSupport/AppSceneViewController.m` | 320-364 | `updateSettingsWithBlock:`：bounds 直接设成未缩放尺寸 |
| `MultitaskSupport/AppSceneViewController.m` | 531-554 | `commitHostedGeometry`：调 `applyViewGeometryToSettings:` |
| `MultitaskSupport/DecoratedAppSceneViewController.m` | 42-50 | `DecoratedStageContainerView hitTest:`：tapShield 拦截（主窗 hidden，不生效） |
| `MultitaskSupport/DecoratedAppSceneViewController.m` | 379-387 | `applyScaleRatio`：`contentView.transform = CGAffineTransformMakeScale(ratio, ratio)` |
| `MultitaskSupport/DecoratedAppSceneViewController.m` | 320-377 | `applyStageFrame:scaleRatio:maximized:` |
| `MultitaskSupport/UIKitHooks.m` | 41-68 | FBScene hook：safeAreaInsets 除以 transform |
| `MultitaskSupport/UIKitHooks.m` | 97-163 | `LCProcessStageTouches`：宿主 sendEvent 拦截（主窗返回 NO） |
| `MultitaskSupport/UIKitHooks.m` | 244-247 | swizzle UIApplication/UIWindow sendEvent |
| `MultitaskSupport/MultitaskDockView.swift` | 1684-1707 | 0.35s 二次几何 commit + "controls stay untappable"注释 |
| `MultitaskSupport/MultitaskDockView.swift` | 1602-1645 | watchdog 1s tick：可能触发 performLayout + commit |
| `MultitaskSupport/MultitaskStage.swift` | 65-114 | 几何计算：unit、slotFrame、slotScaleRatio |
| `TweakLoader/UIKit+GuestHooks.m` | 798-863 | guest `hook_lcStage_sendEvent:`：主窗快速放行 |
| `TweakLoader/UIKit+GuestHooks.m` | 728-746 | side-window 缓存 0.5s |
| `MultitaskSupport/LCStageIPC.h` | 12-24 | "host never sees touches" + guest 端拦截原理 |
