# 废弃开关删除 + 死代码清理报告

日期：2026-09-27
范围：删除「锁定 App 页面状态」(scenePinning) 与「应用被系统回收后原位重启」(autoRecoverGuest) 两个废弃开关及其全部逻辑，并做全量死代码审计。

净改动：7 个文件，约 -444 行 / +23 行。两个开关符号全仓 grep 零残留。

---

## 任务一：删除 scenePinning（锁定 App 页面状态）

### 删除内容

| 文件 | 位置 | 删了什么 |
|---|---|---|
| `LiveContainerSwiftUI/.../LCMultitaskSettingView.swift` | 原 21、25 行 | `@AppStorage("LCStageScenePinning") var scenePinning` 及其注释 |
| 同上 | 原 60–67 行 | `Toggle(isOn: $scenePinning)` 整块 |
| `MultitaskSupport/MultitaskDockView.swift` | 原 776–779 行 | `isPinningForeground` / `foregroundPinningTimer` 两个属性 |
| 同上 | 原 1782–1788 行 | `scenePinningEnabled` 计算属性 |
| 同上 | 原 1921–1933 行 | `appWillResignActive` 里 `if scenePinningEnabled { beginForegroundPinning() }` 分支，以及日志里的 `前台钉住=...` 字段 |
| 同上 | 原 1964–2007 行 | `pinAllStagedScenesForeground(reason:)`、`beginForegroundPinning()`、`endForegroundPinning()` 三个方法（含 0.2/0.5/1.0s 阶梯重钉 + 1s 周期 Timer） |
| 同上 | `appWillEnterForeground` | 删除 `endForegroundPinning()` 调用；把原来的 `if scenePinningEnabled { 选择性重推 + 延迟几何提交 } else { 全量重推 + 即时提交 }` 折叠成单一路径（见下「关键决策」） |
| `MultitaskSupport/LCStageIPC.h` | 原 85–91 行 | `LCStageIPCPinningKey` 常量及其文档注释 |
| 同上 | 原 243–248 行 | `LCStageGuestPinningEnabled()` inline 函数 |
| `TweakLoader/UIKit+GuestHooks.m` | 474–478、501–504、510–513 行 | 三处 `LCStageGuestPinningEnabled()` 调用点中性化（见下） |

### GuestHooks 三处调用点怎么处理的
`LCStageGuestPinningEnabled()` 是 guest 侧「生命周期掩码」的总开关：它 gate 了
(a) `LCStageShouldMaskLifecycleName` —— 抑制 guest 自己的 UIScene 生命周期广播；
(b) `hook_lc_activationState` —— 把 `UIScene.activationState` 钳成 foreground；
(c) `hook_lc_applicationState` —— 把 `UIApplication.applicationState` 钳成 active。

这正是「把 app 钉在前台页面、回前台不回喂信息流」的 guest 侧一半。删除开关 = 这套掩码永久关闭。改动方式（最小 diff）：
- `LCStageShouldMaskLifecycleName` 直接 `return NO;`（不再抑制任何广播）；
- 两个 clamp hook 删掉 if 分支，只调原实现（不再钳状态）。

> 注：触摸锚定（LCTouchAnchor）那 101 行是上一步已删的本地改动，本次未碰。

---

## 任务二：删除 autoRecoverGuest（原位重启）

### 删除内容

| 文件 | 位置 | 删了什么 |
|---|---|---|
| `LCMultitaskSettingView.swift` | 原 21、81–88 行 | `@AppStorage("LCAutoRecoverGuest") var autoRecoverGuest` 与对应 Toggle |
| `MultitaskDockView.swift` `DockAppModel` | 原 147–154 行 | `isRecovering` / `recoveryAttempts` / `recoveryBeganAt` 三个状态属性 |
| 同上 `pruneDeadWindows` | 1396–1447 行 | 去掉 `recoverUUIDs` 集合、`if app.isRecovering { continue }` 两处、心跳恢复后清零 attempts 的日志块、`canRecoverInPlace` 分流；现在判定为死的窗口一律 `tearDownWindow` |
| 同上 | 原 1466–1530 行 | `canRecoverInPlace(_:)`、`beginRecovery(uuid:)`、`recoveryFailed(uuid:reason:)` 三个方法 |
| 同上 `watchdogTick` | 原 1620–1625 行 | 「relaunch timeout」超时兜底循环（依赖 `recoveryBeganAt`/`recoveryTimeout`/`recoveryFailed`） |
| 同上 | 原 809 行 | `recoveryTimeout` 静态常量 |
| 同上 `addRunningAppWithInfo` | 1956–1960 行 | `if existing.isRecovering { replaceRecoveredWindow(...) }` 分支；同容器重复启动一律忽略 |
| 同上 | 原 2208–2246 行 | `replaceRecoveredWindow(...)` 方法（新 guest 原位替换卡片） |
| 同上 `blockedReason(forNewStageWindow:)` | 2429 行附近 | 删掉「恢复中槽位放行」的 `if isRecovering { return nil }` 旁路 |
| `MultitaskAppWindow.swift` | 原 284–311 行 | `MultitaskRelaunchManager.recoverGuest(bundleId:dataUUID:)` static 方法 |
| `DecoratedAppSceneViewController.h` | 原 13–16 行 | `isRecoveringGuest` 属性及其文档 |
| 同上 `.m` | `appSceneVCAppDidExit:` | 删掉 `if(_isRecoveringGuest){...return;}` 分支（旧 guest 退出时保留槽位等重启的那段） |
| 同上 `.h/.m` | 原 36–38、224–235 行 | `showRecoveryCoverWithIcon:appName:` 声明与实现（原位重启专用的「recovering…」遮罩，唯一调用方 beginRecovery 已删） |

### 看门狗（watchdog）保留情况
`watchdogTick()` 定时器（1s）**整体保留**，只删了原位重启分支。它现在还负责：
1. 心跳 pruning（`pruneDeadWindows` 拆真死窗口，保活/防孤儿）；
2. 无 layout 变化时 `publishStageRoles(active: true)` 重发角色（保活心跳/角色刷新）；
3. `handleGuestFrameReady()` 帧就绪轮询；
4. 无 TweakLoader guest 的遮罩兜底。
这正是任务要求「保留看门狗框架、只删原位重启」。

### 保留的相关功能（非原位重启）
- `MultitaskRelaunchManager.scheduleRelaunchIfNeeded(...)`（`MultitaskAppWindow.swift:236`）——这是 `LCSkipTerminatedScreen` + `LCRestartTerminatedApp` 开关控制的「退出后重启」，与原位重启无关，保留。
- `markPendingIfNeeded`/`clearPending`/`lookupAppModel`/`relaunchApp` 均保留（scheduleRelaunchIfNeeded 在用）。

---

## 任务三：死代码审计

### 真死代码（已删）
- `DockAppModel.isRecovering / recoveryAttempts / recoveryBeganAt`、`recoveryTimeout` 常量（随任务二）。
- `DecoratedAppSceneViewController.showRecoveryCoverWithIcon:appName:`（随任务二，唯一调用方消失）。
- `LCStageIPC.h` 的 pinning key / inline 函数（随任务一）。

### 审计过但**保留**的（附原因）

1. **`pendingWakeGeometryCommit` / `settleWakeGeometryIfNeeded` / `scheduleWakeGeometryBackstop`**（DockView 769、1901、1914 行）
   原先是 pinning-on 分支才武装的「回前台延迟几何提交」——等主窗像素验真帧就绪再提交主窗几何，避免重连跨进程 surface 时竞速闪黑。这是防黑闪机制，不是 pinning 本体。**改为每次回前台都武装**（`appWillEnterForeground` 里 `pendingWakeGeometryCommit = true; scheduleWakeGeometryBackstop()`），与冻结帧盖帧配合。所以它现在不是死代码，是活的防黑闪路径。

2. **换边弹簧动画里的「飞行时临时 `contentView.isUserInteractionEnabled = true`」段**（DockView 1170–1194）
   这不是死代码：注释说明副窗静止时非交互，render server 会把它们的 surface 钉在缓存槽位，落地时 snapping 闪副窗列；飞行期间临时设交互让 render server 逐帧追踪。属于保留的「换边弹簧动画」功能，删了有复闪风险，**保留**。

3. **`LCStageMaskedLifecycleNames()` / `LCStageGuestHasActivatedOnce` / 三个 no-op swizzle**（GuestHooks 453–521）
   掩码永久关闭后，`LCStageMaskedLifecycleNames()` 成为未被调用的 static 函数（会触发一次 `-Wunused-function` 警告，但工程未开 `-Werror`，不阻断编译），`LCStageGuestHasActivatedOnce` 只写不读，三个 swizzle 变成直通空转。
   **保留原因**：任务前提明确「UIKit+GuestHooks.m 已恢复原样、不要碰它」，且触摸/手势隔离代码极脆弱；这些空转 hook 是直通调用原实现，运行时开销可忽略，不影响功能。如需后续彻底清理，可整段移除 `LCStageInstallLifecycleMasking()` 及其 swizzle 安装点。

4. **`deferCornerMasks` 变量**：grep 全仓已无此符号（此前清理已删），无需处理。

5. **`[LOCAL CHANGE]` 标记**（AppSceneViewController.m 294、347）：是「合并上游时保持同步」的维护标记，不是临时 hack，**保留**。

6. **无 `#if 0` / `if(false)` / 大段注释掉的旧逻辑**。

### Darwin 通知 / IPC key 审计（均有收发双方，保留）
- `LCStageRolesChangedNotificationName` —— host publishRoles → guest `LCStageRolesChangedCallback`
- `LCStageHostBackgroundingNotificationName` —— host `LCStageNotifyHostBackgrounding` → guest `LCStageHostBackgroundingCallback`（冻结帧拍照 + 保活音频 arm，**防黑保留**）
- `LCStageHostForegroundingNotificationName` —— host `LCStageNotifyHostForegrounding` → guest `LCStageHostForegroundingCallback`（保活 disarm + frame-ready re-arm，**保留**）
- `LCStagePromoteRequestNotificationName` / `LCStageFrameReadyNotificationName` —— guest→host，均有接收方。

---

## 编译风险点

1. **GuestHooks 的 `-Wunused-function` 警告**：`LCStageMaskedLifecycleNames()` 未被调用。工程 `GCC_WARN_UNUSED_FUNCTION=YES` 但**未开 `-Werror`**，仅警告不报错，CI 可过。若想消除，见上面保留项 3 的后续清理建议。
2. **头文件同步**：`LCStageIPCPinningKey` / `LCStageGuestPinningEnabled()` 从 `LCStageIPC.h` 删除后，全仓 grep 已无任何引用；`isRecoveringGuest` 属性从 `.h` 删除后，`.m` 与 Swift 侧引用均已清。
3. **本地化字符串残留**：`lc.settings.scenePinning[.detail]`、`lc.settings.autoRecoverGuest[.detail]`、`lc.multitask.recovery.placeholder` 在 `Localizable.xcstrings` 里变成未使用条目——xcstrings 条目不参与编译，不影响构建，未删（避免动大 JSON）。
4. 本机只有 Command Line Tools，无完整 Xcode，**未本地编译**；已通过 grep 零残留 + 括号平衡（brace=0）静态核查。请 CI 验证。

---

## 确认保留的功能
- ✅ 副窗隔离逻辑（side window touch quarantine / `LCStageGuestIsSideWindow`）
- ✅ 冻结帧盖帧（`coverCardsWithFrozenFrames` / guest `LCGuestCaptureFrozenFrame` / `showFrozenFrameAtPath:` / 拍照通知 IPC）
- ✅ 换边弹簧动画（含飞行时 isUserInteractionEnabled 段）
- ✅ 圆角逻辑（`maskedCorners` / `MultitaskStageLayout.maskedCorners`）
- ✅ 保活三兄弟（audio / PiP / location，`applyKeepAliveSettings` + `LCGuestKeepAliveAudio`）
- ✅ 看门狗框架（角色重发 / 心跳 pruning / 帧就绪轮询 / 遮罩兜底）
- ✅ `setHostedSceneForeground:` / `lcPinForeground`（后者仍被 `handleExtensionInterruption` 中断存活逻辑使用）
