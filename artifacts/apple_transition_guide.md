# 苹果原生转场为什么不闪黑 —— 对照 LiveContainer-MT 冻结帧方案的规范化研究

> 只读研究，不改代码。目标：搞清楚苹果自己是怎么做"跨进程/后台/转场不闪黑"的，再回头看我们现在那套 guest 拍 JPEG 写盘、host 读盘盖帧的做法，差在哪、怎么改。

---

## 一、先把问题说清楚

你现在看到的"闪黑"，本质上是这一类事情：

- 宿主退到后台/锁屏再回来，guest 的跨进程渲染面（`_UISceneHostingView`）在某一瞬间是空的或者旧的，容器黑底露出来一帧。
- 换边（mirroring）时，把 hosting view 挪半屏，跨进程 surface 重新配置，副窗落地那一帧闪一下。

现在的解法是：**guest 在 willResignActive 时自己拍一张 JPEG 写到 App Group 共享磁盘，host 回前台时读这张 JPEG 塞进一个 UIImageView 盖住卡片，等 guest 报"我出新帧了"再把盖图淡出。**

你说这是"遮丑"——对。但要先搞清楚苹果自己是怎么不遮丑也不闪的，才能知道哪一步是真的可以省掉、哪一步是被跨进程架构逼出来的、必须换一种更高效的做法。

---

## 二、苹果原生转场机制：它到底怎么做的

### 2.1 App Switcher（多任务卡片）

**卡片是快照，不是实时 view。** 但关键不在"是不是快照"，在于**快照是什么时候拍的**。

- 你按 Home 键/上滑退到桌面那一刻，iOS 就在 `applicationDidEnterBackground` 返回之后**立刻**给你的 app 窗口拍一张图（系统内部做，不是 app 自己做）。
- 这张图被系统存起来，App Switcher 里那个卡片就是它。
- 你打开 App Switcher 左右划卡片时，**卡片上显示的一直是这张提前拍好的静态图**，不是 app 实时在画。
- 只有你真的点了某个卡片、它要回前台了，系统才把那个 app 的真实 surface 重新接上，同时用这张快照当"launch image"盖在新 surface 上面——等 app 真的画出第一帧了，快照淡出，实时 view 淡入。

**共同点：快照在转场开始之前就已经躺在那里了，不是转场进行中才现拍现传。** 所以你划卡片时看到的永远是一张完整的图，不会拍到一半黑。

官方文档原话（[Preparing your UI to run in the background](https://developer.apple.com/documentation/UIKit/preparing-your-ui-to-run-in-the-background)）：

> "After your app enters the background and your delegate method returns, UIKit takes a snapshot of your app's current user interface. The system displays the resulting image in the app switcher. **It also displays the image temporarily when bringing your app back to the foreground.**"

注意最后半句：回前台时系统**临时**显示这张快照。这跟我们现在的 frozenFrameView 思路是一样的——区别在于苹果是系统自动拍、系统自动存、系统自动显示，app 一行代码都不用写。

### 2.2 iOS 后台快照：什么时候拍、存哪、怎么用

拍的时机：
- 不是在 `willResignActive`（屏幕还在变暗动画时），而是在 `applicationDidEnterBackground` / `sceneDidEnterBackground` **返回之后**。
- 苹果 Q&A（[QA1838](https://developer.apple.com/library/archive/qa/qa1838/_index.html)）明确警告：`applicationDidEnterBackground:` 里不要做任何动画，因为"**你的方法一返回，系统立刻就截屏**"。动画来不及跑完就会被截进去。

存哪：
- 存在系统自己的私有缓存目录（`/var/mobile/Containers/Data/Application/<UUID>/Library/Caches/Snapshots/` 之类），**不是 app 自己写的 JPEG**。
- 这张图是给系统用的（App Switcher 缩略图 + 回前台临时占位），app 自己读不到也不需要读。

怎么用：
- 回前台时，系统先把这张快照铺在屏幕上（你感觉 app"秒回"了），然后等 app 的真实 UI 渲染出来，快照被自然替换。
- 如果 app 被 jetsam 杀了冷启动，这张快照会当 launch storyboard 用，让你感觉 app 还在原来的状态。
- app 可以调 `ignoreSnapshotOnNextApplicationLaunch()` 让系统别用这张快照（比如你刚退到后台时屏幕上是密码框）。

### 2.3 Split View / Slide Over（iPadOS 分屏）

这个最接近我们的场景——两个 app 的 view 在屏幕上同时存在、还要连续移动。

**做法：两个 app 的 surface 都是实时的，但移动时是系统在渲染服务器层面连续平移 IOSurface，不是 app 自己在 UIKit 里画动画。**

- 你拖中间分隔条时，背后两个 app 根本不知道自己被 resize 了——它们的 IOSurface 还是原来那一块。
- 是 **SpringBoard / BackBoard** 在 render server 层面把两块 surface 的合成 rect 连续改了，GPU 端连续重采样，所以你看到的是连续滑动。
- app 进程不参与这个动画，它的 CPU/GPU 该干嘛干嘛。
- 等你松手了，系统才通过 scene settings 把新尺寸真正告诉两个 app，app 再做自己的 layout。

**关键点：移动的是 surface 的合成参数（position/size），不是 view 的 layer frame。** 因为是 render server 在做，每帧都是原子的，不会出现"layer tree 动了但 surface 还在旧位置"的中间态。

这正好解释了我们 `side_window_flash.md` 里定位的那个副窗闪——我们是在 host 进程里改 `containerView.frame`（layer tree 动了），但 BackBoard settings 里的 surface position 没同步推，所以系统事后补了一次"纠正帧"，那一帧就是闪。**苹果自己做 Split View 时根本不会有这个问题，因为它就是用 render server 在移 surface，不是在 host UIKit 里移 frame。**

### 2.4 控制中心 / 通知中心下拉

背后的 app 怎么保持连续不闪？

- 下拉控制中心时，背后的 app **不进后台**。它只是 `willResignActive`（失去焦点），进程还活着、还在画。
- 控制中心是一个独立的 window（系统级 window level 很高），盖在 app 上面。
- app 的 view hierarchy 一帧都没动，surface 也没断。你下拉多少、背后的 app 就原封不动地露多少出来。
- 所以根本不需要快照——实时 view 一直就在那，只是被半透明的毛玻璃盖着。

**共同点：只要进程还活着、surface 没断，就根本不需要快照。快照只在"surface 必然要断"的时候才用。**

### 2.5 UIViewController 自定义转场：苹果给 app 的标准 API

这是 app 自己做转场时苹果教你的写法（[UIViewControllerContextTransitioning](https://developer.apple.com/library/content/featuredarticles/ViewControllerPGforiPhoneOS/CustomizingtheTransitionAnimations.html)）：

```
1. containerView 是 UIKit 给你的一个容器 view，所有转场动画都在它上面做。
2. fromVC.view 和 toVC.view 都是真实 view，但你不直接动画它们——
   你先对 fromVC.view 调 snapshotView(afterScreenUpdates: NO) 拍一张内存快照。
3. 把这个 snapshotView 加到 containerView 最上面，
   然后把 fromVC.view 从 containerView 里删掉（或藏起来）。
4. 你动画的是这个 snapshotView（位移/缩放/淡出），
   同时 toVC.view 在下面慢慢淡入。
5. 动画结束后，把 snapshotView 从 containerView 里删掉。
```

**为什么要拍快照而不是直接动画 fromVC.view？**
- 因为转场期间 fromVC 的真实 view 可能已经被 UIKit 拆走了（比如 dismiss 时 fromVC 要销毁），你不能在一个马上要销毁的 view 上做动画。
- snapshotView 是一张**独立的、内存里的位图/图层快照**，跟原 view 脱钩，你随便动它不会影响原 view。
- 全程在内存里，不写盘、不编解码、不跨进程。`snapshotView(afterScreenUpdates:)` 比你自己 `UIGraphicsImageRenderer` 再 `UIImageView` 快得多——它直接从 render server 拿已渲染好的图层树，不重绘。

### 2.6 总结：苹果什么时候用"实时 view 连续动画"，什么时候用"快照"

| 场景 | 用什么 | 为什么 |
|---|---|---|
| 控制中心下拉、通知中心下拉 | **实时 view 不动**，上面盖一个系统 window | 进程没死、surface 没断，啥都不用做 |
| Split View 拖分隔条 | **render server 连续移 surface**，app 不参与动画 | 系统层面做，每帧原子，不会有中间态 |
| App Switcher 划卡片 | **提前拍好的静态快照**，不是实时 view | app 已经挂起了，surface 早就没了，只能用快照 |
| 回前台 | **先铺系统快照，等真实帧到了再替换** | surface 重连需要时间，用快照填空窗 |
| app 内自定义转场 | **内存 snapshotView + containerView**，不写盘 | 转场期间 fromVC 可能被拆，需要一个脱钩替身 |

**一句话：苹果能用实时连续动画就用实时，只有在"surface 必然要断/进程必然要挂"的时候才上快照。而且快照永远是在转场开始前就准备好的内存图，不是转场中现拍现传的文件。**

---

## 三、我们当前实现的问题：跟苹果差在哪

### 3.1 现在的完整数据流（逐行确认过）

**guest 端拍照**（`TweakLoader/UIKit+GuestHooks.m:336-365` `LCGuestCaptureFrozenFrame`）：

```
1. 触发时机：
   - guest 自己的 willResignActiveNotification（:661）
   - guest 自己的 UISceneWillDeactivateNotification（:670）
   - 宿主通过 Darwin 通知 LCStageHostBackgrounding 叫它拍（:768）
   - 拍完还在 0.15s / 0.5s 补拍两次（:774-778），因为第一次拍的时候屏幕变暗动画还没走完
2. 怎么拍：
   - UIGraphicsImageRenderer + [window drawViewHierarchyInRect:bounds afterScreenUpdates:NO]（:341-344）
   - 这是在 guest 进程内拍的，guest 自己就是渲染进程，所以能截到真像素
3. 怎么存：
   - UIImageJPEGRepresentation(image, 0.7) 编码成 JPEG（:345）
   - [jpeg writeToFile:path atomically:YES] 写到 App Group 共享磁盘
     路径：.../LiveContainer/StageFrozenFrames/<uuid>.jpg（LCStageIPC.h:314-320）
4. 还有个亮度校验：拍出来如果是全黑（mean<0.005 && std<0.005）且之前有旧图，就不覆盖旧图（:354-359）
```

**host 端盖帧**（`MultitaskSupport/DecoratedAppSceneViewController.m:241-269` `showFrozenFrameAtPath:notOlderThan:`）：

```
1. 什么时候盖：
   - 宿主 willResignActive 时立刻盖一次（MultitaskDockView.swift:1920 coverCardsWithFrozenFrames()）
   - 0.1s 后再盖一次（:1946），0.5s 后再盖一次（:1949）——等 guest 这轮拍的 JPEG 落盘
   - 宿主回前台 willEnterForeground 时盖一次（:2023），带 freshness 时间戳过滤
2. 怎么盖：
   - 检查文件修改时间够不够新（:244-251）
   - [[UIImage alloc] initWithContentsOfFile:path] 从磁盘读 JPEG（:253）
   - 塞给 self.frozenFrameView.image，hidden=NO，alpha=1（:260-262）
```

**host 端揭帧**（`MultitaskDockView.swift:1882-1900` `handleGuestFrameReady`）：

```
1. guest 端有个 LCFrameReadySignaler（UIKit+GuestHooks.m:372-437）：
   - arm 后每 2 个 display tick 采一次 40x40 缩略图亮度
   - 连续 2 帧有真实内容（mean>0.02 或 std>0.01）就报 ready
   - 3s 兜底必报
2. guest 调 LCStageGuestMarkFrameReady(uuid)（LCStageIPC.h:223-232）：
   - 写一个时间戳到 App Group defaults
   - 发 Darwin 通知 LCStageFrameReadyNotificationName
3. host 收到 Darwin 通知（:1882）：
   - 读时间戳，比一下是不是新的
   - 调 hideContentCovers(animated: true)（:1893）
   - frozenFrameView.alpha 0.25s 淡出，然后 hidden=YES、image=nil（DecoratedAppSceneViewController.m:271-293）
```

### 3.2 跟苹果的对比表

| 环节 | 苹果做法 | 我们现在的做法 | 差距 |
|---|---|---|---|
| 谁拍快照 | 系统自动拍，app 无感 | guest 自己在 willResignActive 时调 drawViewHierarchyInRect | 我们已经是 guest 自己拍了（因为 host 截不到），这步其实对 |
| 拍什么格式 | 系统内部位图，直接存 render server 缓存 | JPEG 0.7 质量，编码后写磁盘 | **多了 JPEG 编解码** |
| 存哪 | 系统私有缓存，内存里 | App Group 共享磁盘文件 | **多了磁盘 I/O（写+读）** |
| 怎么传给 host | 不存在"传"这一步，系统直接用 | guest 写文件 → host 读文件 | **多了跨进程文件传递** |
| 时机 | 转场开始前就已经在那了 | willResignActive 才开始拍，0.1s/0.5s 补拍，回前台时还要等 guest 报 frame-ready 才揭 | **有好几帧的空窗** |
| host 能不能直接截 | 系统自己能截 | host 截 `_UISceneHostingView` 是黑的（LCStageIPC.h:102-107 注释实锤） | **这是跨进程架构的硬限制** |
| 揭帧时机 | 真实 surface 接上后系统自然替换 | guest 端像素验帧（连续 2 帧有内容）→ Darwin 通知 → host 淡出 | **多了一次跨进程通知往返** |

### 3.3 为什么会有"盖晚了露黑"的窗口

把时序拉出来看（宿主 willResignActive 到回前台）：

```
t=0.000  宿主 willResignActive
         ├─ LCStageNotifyHostBackgrounding() 发 Darwin 通知（跨进程，有延迟）
         └─ coverCardsWithFrozenFrames() 盖——但盖的是"上一轮"的 JPEG（这轮还没拍）
t=0.00x  guest 进程收到 Darwin 通知，开始 LCGuestCaptureFrozenFrame
         ├─ drawViewHierarchyInRect 拍照（主线程同步，~1-3ms）
         ├─ UIImageJPEGRepresentation 编码（~5-15ms，全屏分辨率）
         └─ writeToFile 写磁盘（~2-10ms，App Group 容器）
t=0.100  宿主 0.1s 定时器：coverCardsWithFrozenFrames(freshSince:)
         └─ 这时候 guest 的 JPEG 可能刚写完，也可能还在写
t=0.500  宿主 0.5s 定时器：再盖一次（这轮新 JPEG 基本肯定落盘了）
...锁屏期间...
t=T       用户解锁，宿主 willEnterForeground
         ├─ coverCardsWithFrozenFrames(freshSince:) 盖这轮 JPEG
         ├─ 但 surface 可能已经被系统收走了，frozenFrameView 下面是黑容器底
         └─ guest 开始渲染，LCFrameReadySignaler 每 2 tick 采样
t=T+0.033~0.1  guest 连续 2 帧有内容，报 frame-ready（写 defaults + Darwin 通知）
t=T+0.1~0.2    host 收到 Darwin 通知，hideContentCovers 0.25s 淡出
```

**问题点：**

1. **JPEG 编码+写盘要 7-25ms**。这期间如果系统已经开始撤 surface，guest 拍的可能就是黑的（代码里 :354 的 deadBuffer 检测就是为了防这个）。
2. **回前台时盖的是磁盘上的 JPEG**。`initWithContentsOfFile:` 要解码 JPEG（~5-20ms），这一帧如果还没解码完，frozenFrameView.image 是 nil 或者旧图，下面黑底就露出来了。
3. **揭帧靠 guest 像素验帧 + Darwin 通知往返**。从 surface 真接上到 host 收到通知再淡出，又有 50-200ms。这期间盖图一直盖着，虽然不露黑，但用户看到的是一张静态图"冻"在那。
4. **JPEG 有损**。0.7 质量在大面积渐变/文字边缘会有轻微块效应，静态盖在屏幕上放大看能看出来。苹果的系统快照是无损的。

**但要注意：这些问题都是"效率"问题，不是"方向"问题。** 方向是对的——guest 拍、host 盖、等真帧再揭。只是实现方式（JPEG 写盘）比苹果的内存快照慢了一个数量级。

---

## 四、规范化方案

### 4.1 核心思路：把"JPEG 写盘"换成"内存快照 + XPC 传位图"

苹果在 app 内转场用的是 `snapshotView(afterScreenUpdates:)`——全程内存。我们跨进程做不到直接 `snapshotView`（host 截远程 view 是黑的），但可以把"guest 拍内存位图 → XPC 传 CGImage → host 包成 UIImageView"这条路走通，**把磁盘 I/O 和 JPEG 编解码整个砍掉**。

#### 方案 A（最苹果）：guest 拍 CGImage，XPC 传内存，host 用 UIImageView 显示

**改什么：**

1. **guest 端**（`TweakLoader/UIKit+GuestHooks.m` `LCGuestCaptureFrozenFrame`）：
   - 现在是 `UIGraphicsImageRenderer` → JPEG → writeToFile。
   - 改成：拍一个 `CGImageRef`（不编 JPEG），通过现有的 Darwin 通知 + App Group defaults 机制，把 `CGImage` 的 raw bytes（或者更好——一个共享内存 CGSurface/ IOSurface）传给 host。
   - **不要用 JPEG**。要么传 RGBA8 raw bytes（全屏 ~12MB，iPhone 16 Pro 是 1206×2622×4 ≈ 12.6MB），要么用一个 `IOSurface`/`CVPixelBuffer` 做跨进程共享内存（零拷贝）。
   - 传 raw RGBA 的话，用 `NSData` 塞进 App Group defaults？不行——defaults 不适合塞 12MB。**应该用一个共享内存区域（`mmap` 一个 App Group 里的文件，或者 `IOSurfaceCreateMachPort`）。**

2. **host 端**（`DecoratedAppSceneViewController.m` `showFrozenFrameAtPath:`）：
   - 现在是 `[[UIImage alloc] initWithContentsOfFile:path]` 读 JPEG。
   - 改成：从共享内存里直接拿 `CGImageRef`，包成 `[UIImage imageWithCGImage:]`，塞给 `frozenFrameView.image`。
   - **没有文件 IO，没有 JPEG 解码，直接是一个可显示的 CGImage。**

**但这里有个硬问题要先验证：**

> host 端能不能用 `snapshotView(afterScreenUpdates:)` 直接对 `_UISceneHostingView` 拍？

根据 Apple Developer Forums 的说法（[这个帖子](https://developer.apple.com/forums/thread/108278)）：

> "UIView based snapshots can capture out of process content (e.g. remote views from extensions), thus it's not possible to get image bits out of it."

翻译一下：
- `snapshotView(afterScreenUpdates:)` **可以**对远程 view 生成一个 snapshot view（这个 view 本身是系统管理的，能显示远程内容）。
- 但你**不能**把这个 snapshot view 渲染成 UIImage/CGImage 拿像素（安全沙箱限制）。
- 所以 host 端拍出来的 snapshot view 是黑的或者拿不到 bitmap——LCStageIPC.h:102-107 的注释已经实锤了这一点。

**结论：host 端直接 snapshotView 这条路走不通。必须 guest 端拍。** 但 guest 端拍完之后，不一定要写 JPEG——可以走共享内存。

**共享内存方案的具体做法（推荐）：**

```
guest 端：
  1. 建一个 IOSurface（或者 CVPixelBufferPool），大小 = 屏幕 bounds
  2. [window drawViewHierarchyInRect:bounds afterScreenUpdates:NO] 画到这个 surface 上
  3. 把 IOSurface 的 mach port / XPC 端点通过现有的 Darwin 通知+defaults 通道传给 host
     （defaults 里传一个端口号/surface ID，不传像素本身）
host 端：
  4. 收到端口号，从 IOSurface 拿到 CVPixelBuffer/CGImage
  5. 包成 UIImage 塞进 frozenFrameView.image
  6. 零拷贝、零编码、零磁盘
```

**为什么这比现在好：**
- 现在：guest 拍位图 → JPEG 编码（CPU 5-15ms）→ 写磁盘（2-10ms）→ host 读磁盘（2-10ms）→ JPEG 解码（5-20ms）→ UIImage。总共 15-55ms。
- 改成 IOSurface：guest 拍位图（drawViewHierarchyInRect 1-3ms）→ host 直接拿 CGImage（0ms，零拷贝）。总共 1-5ms。
- **省掉 JPEG 编解码的画质损失和延迟。**
- **省掉磁盘 I/O 的抖动**（手机闪存写入偶尔会卡 20-50ms，这就是"盖晚了露黑"的元凶之一）。

**风险：**
- IOSurface/CVPixelBuffer 跨进程传递需要 Mach port/XPC，LiveContainer 现在的 IPC 通道是 Darwin 通知 + App Group defaults（LCStageIPC.h 全是这套）。要加一个真正的 XPC 连接来传 surface port，工作量不小。
- 退路：如果 IOSurface 太复杂，可以先用 `NSData` 存 RGBA8 bytes 写到 App Group 里的一个临时文件（不是 JPEG，是 raw RGBA），host `CGImageCreateWithDataProvider` 直接包成 CGImage。比现在快（省了 JPEG 编解码），但还是有磁盘 I/O。这是一个中间方案。

#### 方案 B：进后台时不盖帧，而是连续淡出——像苹果 App Switcher 那样

**思路：** 苹果 App Switcher 从桌面划到卡片时，卡片不是突然出现的，是背景渐变模糊+卡片从桌面图标放大展开。我们现在是 willResignActive 立刻盖一张静态图，回前台立刻盖回去。能不能改成：

- 宿主 willResignActive 时，**不盖帧**，而是把整个 stage（包括所有卡片）做一个 0.25s 的连续淡出（alpha → 0.92 的毛玻璃背景）。
- 锁屏期间屏幕本来就是黑的（系统锁屏），盖不盖帧用户看不见。
- 回前台时，从 0.92 连续淡回到 1.0。
- 这样 surface 在淡出期间断开/重连，用户看到的是一个平滑的透明度过渡，不会看到"黑一下"。

**但这个方案有个前提：surface 在后台期间真的不会断。** 我们现在已经有 keep-alive（音频/PiP/定位）+ scene pinning（前台钉住），目标就是让 surface 不断。如果 pinning 真的有效（guest 进程没死、surface 没被收走），那回前台时 surface 本来就是活的，根本不需要盖帧。

**什么时候方案 B 不够：** 如果系统真的把 guest jetsam 杀了（pinning 没保住），surface 就真的没了，回前台要冷启动——这时候必须有一张图盖着，不然就是纯黑。这就是我们现在 frozenFrameView 真正的用途场景。

**结论：方案 B 应该是主路径（pinning 有效时不盖帧，连续淡入淡出），方案 A 是兜底路径（pinning 失败/surface 断了时用内存快照盖）。**

#### 方案 C：用 CATransaction 把"surface 重连"和"快照显示"包成原子切换

现在的揭帧是：guest 报 frame-ready → host 收到 Darwin 通知 → `hideContentCovers(animated: true)` 0.25s 淡出。

问题：这 0.25s 里，frozenFrameView 在淡出、实时 surface 在淡入——如果 surface 那一帧还没准备好，淡到一半会露黑。

苹果的做法是原子的：在同一个 CATransaction 里，**先把 surface 切到新帧，再把快照 view 隐藏**，两个操作在同一帧提交，没有中间态。

具体改法：
- 现在 `hideContentCoversAnimated:` 是 `UIView animateWithDuration:0.25` 同时淡 placeholder 和 frozenFrameView（DecoratedAppSceneViewController.m:274-287）。
- 改成：**不要淡出，直接在 CATransaction 里把 frozenFrameView.hidden = YES 设上，同时确认 surface 已经有新帧了。**
- guest 端 frame-ready 的定义要改：不是"采样到有内容"就报，而是"我已经把新帧提交到 render server 了"才报。这样 host 收到通知时，surface 那一帧已经在屏幕上了，host 直接 hidden=YES，零过渡、零黑帧。
- 如果担心突兀，可以留一个 0.05-0.1s 的极短交叉淡化（不是 0.25s），但用 CATransaction 包起来确保两个 view 在同一帧提交。

**为什么现在用 0.25s 淡出？** 因为他们不确定 surface 什么时候真的好——用淡出做一个"保险"，即使 surface 晚到了，淡出期间盖图还在，不会露黑。但代价是用户看到一张静态图慢慢消失，不够利落。

### 4.2 换边（mirroring）副窗闪的规范化方案

根据 `side_window_flash.md` 的分析，副窗闪的根因是：动画落地时主窗调了 `commitHostedGeometry()`（把 hosting view 位置推给 BackBoard），副窗没推，导致 BackBoard 里 surface position 还停在旧槽位，系统事后补一次同步，那一帧就是闪。

**苹果会怎么做？**

苹果做 Split View 拖分隔条时，是 render server 在连续改 surface 合成参数，不存在"layer tree 动了但 settings 没同步"的问题——因为就是同一个东西在动。

我们现在是在 host UIKit 里改 `containerView.frame`（layer tree），surface 的 position 是靠 `applyViewGeometryToSettings:` 单独推的。这是两条路。

**规范化改法（已经在 side_window_flash.md 里写了）：**
- mirroring completion 里对**所有窗口**（不只是主窗）都调 `commitHostedGeometry()`。
- size 不变，所以 `updateFrameWithSettingsBlock` 是 no-op，真正起作用的只有 `applyViewGeometryToSettings:` 那步 XPC 推 position。
- 这样 BackBoard 里 surface position 跟 layer tree 同时更新，系统不需要事后纠正，副窗不闪。

**这是苹果风格吗？** 是的——苹果的 Split View 就是"surface position 和 view position 始终一致"。我们现在主窗做到了（completion 里推了），副窗漏了。补上就行。

**要不要在换边期间对副窗用快照？** 不需要。换边时所有 guest 进程都活着、都在实时渲染（`side_window_flash.md` 已确认副窗 scene 是 foreground=YES，触摸只是被 guest 自己吞了）。连续弹簧动画本身就是苹果风格（实时 view 连续动画），问题只是落地那一下 settings 没同步。补上 commit 就行，不需要上快照。

---

## 五、风险和验证

### 方案 A（内存快照/IOSurface 替代 JPEG 写盘）

**风险：**
1. **IOSurface 跨进程传递复杂度**。现在的 IPC 是 Darwin 通知 + App Group defaults，没有真正的 XPC 连接。要加一个 XPC listener 在 host 端、mach port 发送在 guest 端，涉及 entitlements 和进程间端口权限。
2. **内存占用**。每个 guest 一个全屏 IOSurface（~12MB），4 个 app 就是 ~48MB。比 JPEG（~200KB）大，但比现在同时存 JPEG 解码后的 UIImage（也是 ~12MB）没多占。
3. **drawViewHierarchyInRect 对远程 hosting view 行不行？** 注意：guest 端拍的是 guest 自己的 window（`LCGuestKeyWindow()`），不是 host 端的 `_UISceneHostingView`。guest 自己的 window 在 guest 进程里是本地的，`drawViewHierarchyInRect` 完全没问题——现在就是这么拍的，已经验证过能出图。

**验证方法：**
1. 先做最小验证：不改 IPC，只把现在的 JPEG 编码换成"写 raw RGBA 到 App Group 文件"，host 端用 `CGImageCreateWithDataProvider` 直接读。测一下延迟和画质。如果这一步就把闪黑消了，说明 JPEG 编解码是瓶颈，再考虑 IOSurface。
2. 对比日志：现在的日志已经打了"冻结帧已写入：XXX 字节"（UIKit+GuestHooks.m:363）和"冻结帧读取失败"（DecoratedAppSceneViewController.m:257）。改成内存方案后，加时间戳对比"guest 拍完"到"host 盖好"的间隔——从现在的 20-50ms 降到 <5ms 就成了。

### 方案 B（连续淡入淡出替代盖帧）

**风险：**
1. **pinning 失效时露黑**。如果系统真的杀了 guest 进程，surface 没了，连续淡出淡入期间下面就是黑容器底。所以方案 B 不能单独用，必须跟方案 A 组合（pinning 失败时用内存快照兜底）。
2. **用户体验**。回前台时整个 stage 淡入，而不是"立刻就是原来的画面"——可能感觉不如现在"秒回"。需要实测。

**验证方法：**
1. 先在 pinning 开着的情况下，把 willResignActive 时的 `coverCardsWithFrozenFrames()` 注释掉，看回前台闪不闪。如果不闪，说明 surface 确实没断，盖帧是多余的。
2. 再手动杀一个 guest 进程（从 App Switcher 划掉），看回前台是不是立刻露黑——如果是，就确认了"快照兜底"是必要的。

### 方案 C（CATransaction 原子揭帧）

**风险：**
1. **太突兀**。如果 surface 那一帧其实还没完全好（guest 报了 ready 但实际渲染管线还有延迟），直接 hidden=YES 会露一帧黑。现在的 0.25s 淡出是有保险作用的。
2. **guest 端 frame-ready 的判定要更严格**。现在是"连续 2 个 display tick 采样到有内容"（UIKit+GuestHooks.m:429），这其实是采样了 window 的 brightness，不是真的确认 surface 已经合成到屏幕上了。要改成 CADisplayLink 的 `frameInterval` 回调里确认 host side 的 surface 已经有新帧——但这在 guest 进程里做不到，guest 不知道 host 端 surface 什么时候显示。

**验证方法：**
1. 先把淡出时长从 0.25s 降到 0.1s，看用户感知。如果 0.1s 不闪，再试 0.05s，最后试 0（直接 hidden=YES）。
2. 如果 0 太突兀，留一个 0.05s 的交叉淡化，用 `CATransaction.begin()` / `CATransaction.commit()` 包起来，确保两个 view 在同一帧提交。

### 换边副窗 commit 补全

**风险：** 极低。size 不变，`applyViewGeometryToSettings:` 只推 position metadata，不重分配 surface buffer。主窗已经这么做了，验证过安全。
**验证方法：** 在 mirroring completion 里对副窗也调 `commitHostedGeometry()`，快速连按换边，看副窗还闪不闪。

---

## 六、哪些可以保留

### 6.1 必须保留的（被跨进程架构逼出来的，删了就真黑）

1. **guest 端拍照这个动作本身**。host 截不到远程 surface 是硬限制（Apple 安全沙箱），guest 自己拍是唯一出路。区别只是"拍完存哪"——从 JPEG 文件改成内存/IOSurface。
2. **frozenFrameView 这个 view 容器**。不管快照从哪来（JPEG/内存/IOSurface），host 端都需要一个 UIImageView/UIImage 来盖。view 容器保留，只是 image 的来源改。
3. **frame-ready 通知机制**。guest 报"我出新帧了"、host 揭盖，这个握手是必要的——host 不能假设 surface 什么时候好。区别只是揭盖方式（从 0.25s 淡出改成原子切换或极短淡化）。
4. **pixel 验帧（LCGuestRenderLumaStats）**。guest 端采样 40x40 缩略图亮度来判断"是不是真的画出内容了"，这个是对的——因为 guest 进程里"提交了一帧"和"surface 真的合成到屏幕上"之间有延迟，亮度采样是最朴素的真实验证。保留。

### 6.2 可以优化但不用删的

1. **三次补拍（0.15s / 0.5s）**。现在 willResignActive 拍一次，再补两次是因为第一次拍的时候屏幕变暗动画还没走完。如果改成内存快照，拍照本身只要 1-3ms，可以在 `drawViewHierarchyInRect:afterScreenUpdates:NO` 之后立刻在同一个 runloop 里拍 2-3 次取最后一次，不需要 asyncAfter 补拍。
2. **freshSince 时间戳过滤**。现在用文件修改时间判断"这轮 JPEG 够不够新"。改成内存快照后，用 Darwin 通知携带的时间戳（或者一个递增的 generation 数）来判断，比文件 mtime 更准。
3. **deadBuffer 检测（mean<0.005 && std<0.005 不覆盖旧图）**。这个逻辑保留——不管快照从哪来，拍到全黑就不应该覆盖之前的好图。

### 6.3 可以删掉的

1. **JPEG 编码/解码**。`UIImageJPEGRepresentation(image, 0.7)` 和 `initWithContentsOfFile:` 读 JPEG——这是整个链路里最慢、画质最差的一环。换成 CGImage 直传后整个删掉。
2. **磁盘文件路径 `StageFrozenFrames/<uuid>.jpg`**。改成共享内存后，App Group 里这个目录就不需要了（冷启动时没有快照，用 launchPlaceholder 图标兜底，那个本来就在）。
3. **0.1s / 0.5s 定时器补盖**（`MultitaskDockView.swift:1945-1950`）。现在是因为 JPEG 写盘有延迟，host 不知道什么时候写完，所以隔 0.1s、0.5s 回去再盖一次。内存快照是同步的，guest 拍完 XPC 传过来 host 立刻就能盖，不需要定时器猜。

---

## 七、一句话总结

**苹果不闪黑的秘诀不是"用快照盖住黑"，而是"快照在转场开始前就已经在内存里准备好了，surface 切换和快照替换在同一个渲染帧里原子完成"。** 我们现在的方向（guest 拍、host 盖、等真帧再揭）是对的，但实现方式是 JPEG 写盘——多了编码、磁盘 I/O、解码三道工序，每道都可能慢一帧，这就是"盖晚了露黑"的根因。规范化的改法是把 JPEG 文件换成 IOSurface/共享内存 CGImage 直传，把 0.25s 淡出改成 CATransaction 原子切换，同时保留 pinning 有效时连续淡入淡出（不盖帧）作为主路径、内存快照作为兜底。换边副窗闪是另一个独立问题——补上落地时的 geometry commit 就行，跟快照无关。
