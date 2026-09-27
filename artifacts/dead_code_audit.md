# LiveContainer-MT 死代码审计清单（只读，未改仓库）

审计日期：2026-09-27
范围：`MultitaskSupport/`、`TweakLoader/`，重点是换边（mirror swap）后残留的调试/盖帧/猜时间代码。
判断标准：✅ 真死代码可直接删 ／ ⚠️ 还有用不能删 ／ ❓ 需要你实测确认。

---

## 一句话结论

**换边专用的盖帧/诊断/3D旋转代码其实已经删干净了。** 真正还活着的"冻结帧"机制是给**锁屏/后台/jetsam恢复**用的，跟换边无关，不能删。
唯一一个可以直接简化的真死代码是 `deferCornerMasks` 变量。唯一一个需要你拍板的是换边飞行时那段 `isUserInteractionEnabled` 临时开关。

---

## 1. 冻结帧盖帧机制 —— ⚠️ 整套都还活着，不能删

关键区分：你担心的"换边盖帧"已经不调了（见 `toggleLayoutHandedness` 第 2397-2398 行注释明说"no frozen-frame cover needed"）。但这套机制现在扛着**另外三个场景**，全是真在用的：

| 位置 | 是什么 | 判断 | 理由 |
|---|---|---|---|
| `DecoratedAppSceneViewController.m:137-150` | `frozenFrameView`（UIImageView）创建，插在 tapShield 下面 | ⚠️ | 后台/恢复时盖最后一帧用，见下面调用点 |
| `DecoratedAppSceneViewController.m:237-269` | `showFrozenFrameAtPath:notOlderThan:` | ⚠️ | 被 `beginRecovery`（jetsam 恢复，1516）和 `coverCardsWithFrozenFrames`（锁屏/回前台，1967）调用 |
| `DecoratedAppSceneViewController.m:295-312` | `hideFrozenFrameAnimated:` | ⚠️ | 被 2071 行调用：给不注入 TweakLoader 的 guest 一个 8 秒兜底揭图 |
| `DecoratedAppSceneViewController.m:271-293` | `hideContentCoversAnimated:`（同时盖 launchPlaceholder + frozenFrameView） | ⚠️ | 被 1643、1900（frame-ready 揭图）、2098（3 秒兜底揭图）调用 |
| `TweakLoader/UIKit+GuestHooks.m:336-365` | `LCGuestCaptureFrozenFrame`（guest 自摄 JPEG 写 App Group） | ⚠️ | 触发点：willResignActive(661)、UISceneWillDeactivate(670)、宿主后台 Darwin 通知(768)+0.15/0.4s 补拍(777)。全是锁屏/后台链路，不是换边 |
| `LCStageIPC.h:53-54` `LCStageFrameReadyNotificationName` | guest 报"我出真帧了"的 Darwin 通知 | ⚠️ | guest 发（229 行 `LCStageGuestMarkFrameReady`），host 收（`UIKitHooks.m:227` → `handleGuestFrameReady` 1889）。换边不发，回前台/冷启动发 |
| `LCStageIPC.h:314-320` `LCStageFrozenFramePath` | JPEG 路径约定 | ⚠️ | guest 写（362），host 读（1516/1967），窗口销毁时删（1583）。闭环活着 |
| `MultitaskDockView.swift:1918-1958` | `appWillResignActive` / `appDidEnterBackground` 里的盖帧 | ⚠️ | 这就是 agent-hint 提醒的"后台盖帧防黑屏"，完全活着 |
| `MultitaskDockView.swift:2016-2074` | `appWillEnterForeground` 回前台盖帧→等真帧揭图 | ⚠️ | 活着，防锁屏回来露黑 |
| `MultitaskDockView.swift:1503-1525` | `beginRecovery`（jetsam 被杀后原位重启）盖冻结帧+转圈 | ⚠️ | 活着，是"杀进程也无感"的核心 |

**删除风险**：这套东西删了 = 锁屏/回前台/jetsam 恢复时露黑底，属于自断命根。**千万别因为"换边不用了"就删。**

---

## 2. 屏上诊断浮层（diagLabel）—— ✅ 已经删了，无残留

- 全仓库 grep `diagLabel` / `diagnostic` / `diagView` / `debugLabel` / `side=` / `phase=` / `BEGAN` / `ENDED`，**零命中**（唯一命中是 `UIKitHooks.m:80` 一句注释里提到 "BEGAN phase"，不是浮层）。
- git log 印证：`996f1a6 Remove temporary on-screen touch diag overlay (root cause already fixed)`。
- **结论**：这块临时调试浮层之前那轮已经删掉了，本次审计没有可删的东西。

---

## 3. asyncAfter 猜时间过渡代码 —— 逐个过，全是必要延时，没有换边赛跑

| 位置 | 延时 | 判断 | 说明 |
|---|---|---|---|
| `MultitaskDockView.swift:1236` | 0.25s 后 `settleAfterAnimation` | ⚠️ | 仅 reduceMotion 分支（交叉溶解无 spring 可挂 completion），等溶解落地再 commit 几何。非换边，必要 |
| `MultitaskDockView.swift:1694` | 0.35s 二次 `commitMainWindowGeometry` | ⚠️ | 你怀疑的"0.35s 二次 commit"就是它。但它在 `settleAfterAnimation` 里，**只在非换边动画**（全屏切换/提升主窗）后跑，且被 `layoutToken == settleToken` 等 6 个条件死死挡住——换边 bump 了 layoutToken 会被它自己 return 掉。这是 iOS 19 触控区域晚一拍的官方 workaround，不是换边赛跑 |
| `MultitaskDockView.swift:1952/1955` | 0.1s / 0.5s 后台补盖 | ⚠️ | 等 guest 跨进程拍照的 Darwin 往返落地，必要 |
| `MultitaskDockView.swift:1991` | 0.2/0.5/1.0s 前台重钉 | ⚠️ | 锁屏后递增式重钉场景，必要 |
| `MultitaskDockView.swift:2067` | 8s 兜底揭图 | ⚠️ | 给不注入 TweakLoader 的 guest 兜底，防盖帧永远不揭 |
| `MultitaskDockView.swift:2092` | 3s 兜底 commit 几何 | ⚠️ | frame-ready 管线断了的兜底 |
| `MultitaskDockView.swift:2171` | 0.3s 懒启动封面 | ⚠️ | 给快 guest 0.3s 先出帧，出帧就 cancel，不出再上转圈。必要 |
| `MultitaskDockView.swift:249 / 597` | 2s 保活音频重试 | ⚠️ | 跟换边无关 |
| `DecoratedAppSceneViewController.m:405 / 472` | 2.5s / 3.0s 关闭兜底 | ⚠️ | 场景销毁回调丢失的兜底，必要 |
| `MultitaskAppWindow.swift:206/210` | 0.3s 启动引导场景自毁 | ⚠️ | 开机 splash 引导，与多任务无关 |
| `AppSceneViewController.m:316` | 0.05s resize 去抖 | ⚠️ | 防连续 push 场景设置，必要 |

**没找到被注释掉的大段旧逻辑 / `#if 0` / `if(false)`**（grep 全空）。也就是说以前那堆"猜 0.6s 掀盖""0.35s 二次 commit 换边版"的旧代码已经在前面的提交里清掉了。

---

## 4. 飞行时临时设 isUserInteractionEnabled —— ❓ 需要你实测确认

- **位置**：`MultitaskDockView.swift:1194-1196`（飞行前把副窗 `contentView.isUserInteractionEnabled = true`）和 `1216-1218`（completion 里恢复 false）。
- **它是什么**：换边 spring 动画期间，临时把副窗的 contentView 设成交互，动画结束再改回非交互。
- **当初为什么加**：提交 `f740596 "side surfaces live during flight"` + 代码注释（1190-1193）说——非交互的 surface 会被渲染服务按缓存槽位定住，落地时才猛跳，导致副窗那一列闪一下；临时设成交互让渲染服务每帧都跟踪它。
- **判断**：❓。注释给的理由是**渲染服务 surface 活跃度**问题，不是 bringSubviewToFront/commit 问题（那两个已经另修了）。这俩是不同根因。
- **删除风险**：删了如果副窗飞行中还闪，就是这段在扛；如果现在连续弹簧本身就够顺，这段就是多余的。**我没法跑 app 验证，需要你真机换边十几次看副窗那列还闪不闪**：
  - 不闪 → 可以删这 4 行（1194-1196 + 1216-1218）。
  - 还闪 → 别动，它在干活。

---

## 5. Darwin 通知广播 —— ⚠️ 全部有发有收，无死通知

逐个核对发/收两端：

| 通知 | 发送方 | 接收方 | 判断 |
|---|---|---|---|
| `rolesChanged`（`LCStagePublishRoles`，1299 `publishStageRoles`） | host 每次 layout（含换边 1299、进/退舞台、watchdog 1625/2336/2469） | guest `UIKit+GuestHooks.m:690-695`，更新触控隔离缓存 | ⚠️ 活着。换边也发，但 guest 确实在听 |
| `promoteRequest` | guest `UIKit+GuestHooks.m:833`（点副窗要求提升） | host `UIKitHooks.m:218-223` | ⚠️ 活着 |
| `frameReady` | guest `LCStageGuestMarkFrameReady` | host `UIKitHooks.m:224-229` → 揭图 | ⚠️ 活着 |
| `hostBackgrounding` | host `1924`（willResignActive） | guest `700` → 拍照+保活 | ⚠️ 活着 |
| `hostForegrounding` | host `2021`（willEnterForeground） | guest `708` → 重架 frame-ready | ⚠️ 活着 |

**没有"发了没人听"的孤儿通知。** `publishStageRoles` 换边时照发，guest 端监听没撤，不能删。

---

## 6. 其他死代码

| 位置 | 是什么 | 判断 | 理由 / 删除风险 |
|---|---|---|---|
| `MultitaskDockView.swift:1030` + `1066` | `var deferCornerMasks = mirroring && animated && !reduceMotion`，以及 1066 的 `if !deferCornerMasks { ... }` | ✅ **真死代码可删** | **关键**：换边分支（1177-1221）的动画块**根本不调用 `update` 闭包**（它只手动 set frame）。`update` 只在非换边分支跑，那时 `mirroring=false` → `deferCornerMasks` 恒为 false → `if !deferCornerMasks` 恒为真。这个变量是旧设计（update 曾跑在换边 spring 里）的残留。现在换边的圆角在 1187-1189 动画前就直接设好了。**可把 1030 行变量删掉、1066 行 `if !deferCornerMasks {` 这层 if 去掉，直接写 `view.layer.maskedCorners = ...`**。风险极低 |
| `MultitaskDockView.swift:1651-1660` `armGeometryCommitIfNeeded` | 对 mirror 直接 return | ⚠️ 不能删 | 被 1223（reduceMotion）和 1241（普通动画）调用，全屏切换/提升主窗时 arm 几何 commit。mirror 只是不 arm，非 mirror 还在用 |
| `MultitaskDockView.swift:1664-1708` `settleAfterAnimation` | 对 mirror bail | ⚠️ 不能删 | 被 1238/1258（非换边动画落地）调用，里面的 0.35s 二次 commit 也是给非换边用的 |
| `MultitaskDockView.swift:1720-1725` `commitMainWindowGeometry` | mirroring completion 里已不调 | ⚠️ 不能删 | 还有 1621/1682/1706/2061/2086/2205/2245 一堆调用方 |
| `MultitaskDockView.swift:1025-1027` `shadowPathDuration` | 阴影路径动画时长 | ⚠️ 不能删 | 在 `update`（非换边）里 1112 用到；换边不跑 update 但 casters 是首次布局建好的，换边只在 1208 动 frame |
| `MultitaskDockView.swift:741/1316-1329` `windowShadowCasters` / `shadowCaster(for:)` | 每张卡一个隐形阴影孪生 view | ⚠️ 不能删 | 首次非换边 layout 建好，换边 1208 跟着动 frame。删了卡片没投影 |
| `AppSceneViewController.m:294 / 347` `[LOCAL CHANGE]` 注释 | 合并上游提醒注释 | ⚠️ 不是死代码 | 是活代码上的合并标记，留着 |
| `MultitaskDockView.swift:679` `swapButton` | 换边按钮本体 | ⚠️ 活着 | 3D 旋转已在 `fadbb4e` 删掉，按钮本身还在（2399 触发换边） |

**没有** `[HACK]`/`[TEMP]`/`[FIXME]` 标记（grep 全空），没有 `#if 0` / `if(false)`。

---

## 建议删除顺序（从最安全到最需要验证）

1. **第一批（纯清理，零风险）**：
   - 删 `MultitaskDockView.swift:1030` 的 `deferCornerMasks` 变量，把 1066 行的 `if !deferCornerMasks { ... }` 去掉一层（里面那行 `view.layer.maskedCorners = ...` 保留）。这是唯一确认的真死代码。

2. **第二批（你真机验证后再动）**：
   - 真机连续换边十几次，盯副窗那一列飞的时候闪不闪：
     - 不闪 → 删 `MultitaskDockView.swift:1194-1196` 和 `1216-1218` 两段 `isUserInteractionEnabled` 开关。
     - 还闪 → 保留，它就是副窗飞行不闪的原因。

3. **不要碰（看着像死代码其实是命脉）**：
   - 整套冻结帧/盖帧/frame-ready/JPEG 机制（第 1 节）——那是锁屏/回前台/jetsam 恢复防黑的，不是换边专用。
   - `armGeometryCommitIfNeeded` / `settleAfterAnimation` / `commitMainWindowGeometry` / shadowCasters / 全部 Darwin 通知——非换边动画和跨进程通信还在靠它们。
   - 所有 asyncAfter——逐个看过，都是必要延时或兜底，没有换边猜时间赛跑残留。

> 备注：诊断浮层（diagLabel）上一轮提交 `996f1a6` 已经删干净了，本次无活可干。
