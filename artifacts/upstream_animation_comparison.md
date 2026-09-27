# LiveContainer 多任务动画：上游对比与 fork 演进

> 调研对象：`/Users/xzy/TraeCodeCN/LiveContainer-MT`
> 调研时间：2026-09-27
> 原则：下面每一条都标了【确证】（git 历史 / 官方文档实锤）还是【推测】（我读代码推断的）。

---

## 一、上游仓库到底是谁

**【确证】** origin 是 `https://github.com/xzy-dzw/LiveContainer-MT.git`（你自己的 fork），本地**没有** upstream 远程。

但从 README 和 git 历史能把上游坐死：

- README 明写：「本项目是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的非官方中文分支，在官方预发行版（nightly，基线提交 `4dbe0f9`）完整源码之上」。
- `.gitmodules` 里子模块都挂在 `github.com/LiveContainer/` 这个 org 下（fishhook、litehook）。
- git log 里有 `Co-authored-by: Duy Tran <khanhduytran0@users.noreply.github.com>`，还有 `Merge branch 'LiveContainer:main' into main`。
- 本地 tag `nightly` 就指向 `4dbe0f9`（`Update litehook: add arm64e_x1 dsc suffix`）。

**结论：上游 = `github.com/LiveContainer/LiveContainer`**（这个 org 就是当年 khanhduytran0 那个项目搬过来的，不是另一个仓库）。本地历史里完整保留了上游从 `420c7a0 Initial commit` 一路到 `4dbe0f9` 的全部提交。

---

## 二、上游到底有没有"多任务"？——有，但不是我们这个

**【确证】上游有两套多任务模式**（官方文档 https://livecontainer.github.io/docs/guides/multitask 写得很清楚）：

| 模式 | 干什么 |
|---|---|
| **虚拟窗口（Virtual Window）** | App 跑在自己装饰的浮动窗口里，配一个侧边 Dock 栏，窗口可以拖、可以最大化/最小化、可以 PiP |
| **原生窗口（Native Window）** | 每个 App 直接开在 iPadOS 系统原生窗口里（iPadOS 16.1+），没有 Dock |

DeepWiki（2026-09-18 索引）对上游的描述是：「guest apps run in **decorated windows** managed by `DecoratedAppSceneViewController`, all within a single window scene」——也就是**自由漂浮、可拖拽的独立窗口**。

**【确证】关键差别：上游根本没有"一主三副固定舞台"这个东西。**
- 上游窗口是彼此独立、随便拖到哪的浮动窗；点一个窗只是把它 z 轴提到前面（bring to front），窗口之间**不换位置**。
- 我们这个 fork 的"1+3 固定舞台"（一主三副、点副窗切主位、左右镜像换边）——**上游没有对应概念**。

**【确证】那 fork 的舞台是哪来的？** 上游在基线 `4dbe0f9` 之前其实已经有一个实验性的"虚拟窗口 mode"PoC：
- `05684da poc`、`a967d83 Fix virtual window mode crashing in background`、`527731b Adjust appear animation from dock, add Only 1 App On Stage switch`——这三个提交**都在基线里**（`git merge-base --is-ancestor` 验证过），是上游作者自己写的 PoC。
- fork 的第一个提交 `15e8ad5 Rework the virtual window stage into a 1+3 multitask layout`（2026-09-20，xzy-dzw）就是把这个上游 PoC 拿过来，**整个推翻重做成固定 1+3 舞台**。这一提交删了 1431 行、加了 744 行，`MultitaskDockView.swift` 从上游的 1200 行缩到 603 行。

**一句话：多任务这个"壳"是上游的（进程隔离、FBScene、DecoratedVC、PiP、Dock 栏），但"一主三副卡片舞台 + 切主位 + 换边"这套布局和它的动画，是本 fork 独有的，上游没有可直接对照的参考。**

---

## 三、上游（基线 4dbe0f9）动画是怎么写的

**【确证】** 上游 `MultitaskDockView.swift`（作者 boa-z，2025/6/28）动画走的是**教科书式 UIKit 弹簧**，没有任何手搓 CA：

- 统一常量（`MultitaskDockManager.Constants`）：
  - `standardAnimationDuration = 0.3s`，`longAnimationDuration = 0.4s`，短动画 0.15s / 0.1s
  - `standardSpringDamping = 0.8`（带 20% 过冲回弹），`standardSpringVelocity = 0.3`
  - `bringToFrontScale = 1.02`（提到前面时轻轻放大 2%）
- 动窗口位置：`UIView.animate(withDuration: 0.3, delay:0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3, options: .curveEaseOut) { hostingController.view.frame = finalFrame }`
- 从隐藏态把窗口调出来：先 `transform = 0.1 缩放到一个点`、`center 移到点击处`，再一个弹簧动画同时把 alpha=1、transform=identity、frame 回到原位——像图标"长出来"。
- 已经在屏幕上的窗提到前面：先放大到 1.02，再弹回 1.0（短动画 0.15+0.1）。
- Dock 栏本身（SwiftUI）：`withAnimation(.spring(response: 0.4, dampingFraction: 0.8))`。

**【确证】上游为什么没有"黑闪"问题？** 因为上游窗口是自由拖拽、独立浮动的——你从来不会让两个窗口在半秒内互换位置。它只做"某一个窗自己的 frame 弹簧过去"，跨进程的渲染面（FBScene）不会因为一次布局就拆掉重挂，所以**上游根本不用处理"换边黑闪"**。3.8.0 release notes 里那句 "Added more multitask window animations" 指的也是窗口拖拽/最大化的补间，不是卡片互换。

---

## 四、我们 fork 的动画演进时间线（git 实锤）

fork 在基线之上一共 **76 个提交**。动画写法经历了三个阶段：

### 阶段 0：基线拿来时（4dbe0f9）
- `MultitaskDockView.swift` 1200 行，纯 SwiftUI `withAnimation`（3 处），0 个 UIViewPropertyAnimator，0 个手搓 CA。

### 阶段 1：1+3 重做（15e8ad5，2026-09-20）
- 把浮动窗口模型改成固定舞台。
- **第一次引入 `UIViewPropertyAnimator`**：
  ```swift
  let animator = UIViewPropertyAnimator(
      duration: MultitaskDockManager.layoutAnimationDuration,
      timingParameters: UISpringTimingParameters(dampingRatio: 1.0))
  animator.addAnimations(update); animator.startAnimation()
  ```
  注意：`dampingRatio: 1.0` = **临界阻尼，零过冲**。这时候就已经不要弹跳了。
- SwiftUI 的 `withAnimation` 全部删掉（从 3 处掉到 0）。
- 之后一大串提交（`47c024d`、`f8857e3`、`cbbd468`、`d3d6969`…）全在修**触摸路由、黑屏、保活**，动画本身没大动。

### 阶段 2：关键转折 —— `278bb7a Keep the stage chrome still and let the cards carry the motion`
这是动画写法真正分叉的点：
- **UIViewPropertyAnimator 归零**（0），**手搓 CA 动画出现**（CATransaction / CABasicAnimation，4 处）。
- 提交说明里干了三件事，全是黑闪/观感的教训：
  1. 把窗口控件（chrome）钉死在一个位置——以前主窗变大时控件会跳 6pt，看着像按钮从手指底下裂开。
  2. **撤掉窗口块背后那块黑色底板**——以前四块窗是当一个整体黑块画的，两个窗一换位置，缝隙里就漏出一块黑矩形。改成每页铺一层 22% 灰罩，每扇窗自己带阴影。
  3. 给每扇窗配一个"影子替身"（shadow caster）：卡片自己 corner radius 裁内容会把阴影一起裁掉，所以底下放一个透明孪生视图专门画阴影，而且**阴影的 shadowPath 从 presentation 当前值开始补间**，保证换窗中途影子跟着窗走、不留旧尺寸的光晕。
- 顺带把显示链路请求到 60–120Hz 全范围（ProMotion）。

### 阶段 3：跟"换边黑闪"死磕（50de491 → 073f288）
后面所有动画提交几乎都是为了**干掉左右换边时的整屏黑闪**：

| commit | 干了啥（大白话） |
|---|---|
| `50de491` | 消冷启动黑屏/切回闪黑：失活时冻结最后一屏，回前台先盖真画面再换新帧。FPS 改电竞 OSD。 |
| `d34c010` v4.1.0 | **闪黑根治**：宿主 willResignActive 主动叫 guest 拍一张冻结 JPEG 盖卡；回前台只认真帧揭图；封面 0.3s 懒显示 + 8s 兜底。 |
| `9af53c7` v4.1.2 | 防闪升级：像素级验帧（2 个 40×40 采样点 + 3s 兜底）、同步盖冻结帧、主窗几何 commit 推迟到揭图时。 |
| `6d6f29b` | **左右换边改成瞬切（不要弹簧）**，宁可牺牲丝滑也要杀掉整屏闪烁。 |
| `41d695b` | 换边只重铺卡片 frame + 圆角遮罩，不动 z 轴、不重排 Dock、不重提交 scene 几何——最小化重铺。 |
| `8fe2df5` | 换边在**同一个事务**里重铺所有卡片 + `layoutIfNeeded()`，否则外容器动了、内部跨进程内容晚一帧，就是整屏闪。此时 `performWithoutAnimation` 出现（3 处）。 |
| `708b1fb` | 根因坐实：换边把 hosting view 挪半屏会**拆掉重挂跨进程渲染面**，露出黑色容器底。盖上 guest 自冻结的 JPEG（绝不用宿主截图，因为宿主自己也是黑的）。 |
| `073f288`（最新） | 盖图兜底：有冻结 JPEG 用 JPEG，没有就用 App 图标——保证全新启动（从没退过、没 JPEG）也不闪纯黑。0.6s 硬兜底揭盖。 |

### 当前 main 长这样（2843 行）
- 主布局弹簧：`UIView.animate(withDuration: 0.4, delay:0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { update() }`
  - **damping = 1.0**（临界阻尼，零弹跳），`.beginFromCurrentState`（半路来的切换从当前屏上值接着走，不打断）。
- 手搓 CA 只剩 2 处真动画：
  - 阴影 `shadowPath` 用 `CABasicAnimation`，`fromValue = presentation().shadowPath`，缓动用 `CAMediaTimingFunction(0.42,0,0.2,1)`（就是标准 ease-in-out）。
  - 换边按钮图标 `transform.rotation.y` 半圈翻牌，`CASpringAnimation(damping:12, stiffness:180, duration:0.4)`。
- `performWithoutAnimation` 3 处：换边时把 backdrop、chrome、卡片 frame 三组更新分别冻结，不让它们跟着卡片弹簧一起跑（一跑就整块闪）。
- 进/出舞台：纯 `UIView.animate` 0.22s alpha 交叉淡入淡出；Reduce Motion 时换 `.transitionCrossDissolve`。
- 整个 `MultitaskSupport/` 只剩 1 处 SwiftUI 弹簧（一个按钮按压反馈 `.spring(response:0.28, dampingFraction:0.62)`）。

---

## 五、早期 vs 当前，动画写法对比表

| 维度 | 上游基线 4dbe0f9 | fork 早期（15e8ad5 ~ 278bb7a 之前） | fork 当前 main |
|---|---|---|---|
| 布局模型 | 自由拖拽浮动窗 | 固定 1+3 舞台 | 固定 1+3 舞台 |
| 主动画 API | `UIView.animate(spring)` 块 | `UIViewPropertyAnimator` + `UISpringTimingParameters` | `UIView.animate(spring)` 块 |
| 弹簧阻尼 | 0.8（明显回弹） | 1.0（零过冲） | 1.0（零过冲） |
| 时长常量 | 0.3s / 0.4s 集中在 Constants | 0.4s（layoutAnimationDuration） | 0.4s |
| SwiftUI `withAnimation` | 多处（Dock UI） | 0 | 仅 1 处（按钮按压） |
| 手搓 CA | 无 | 无（PropertyAnimator 包打） | CABasicAnimation(shadowPath) + CASpringAnimation(图标翻牌) + CATransaction |
| `performWithoutAnimation` | 无 | 无 | 3 处（换边冻结 backdrop/chrome/卡片） |
| 可中断性 | 一般 | PropertyAnimator 天然可暂停 | `.beginFromCurrentState` + presentation() 续接 |
| 黑闪对策 | 不需要（窗不换位） | 一开始没管，靠试 | 冻结帧 JPEG 封面 / 图标兜底 / 同事务重铺 / 几何 commit 延迟 |
| 影子 | 无专门处理 | 无 | 每窗一个透明"影子替身"，path 从 presentation 值补间 |

---

## 六、上游 vs 我们：谁更规范、哪些是手搓

**【确证】上游更规范的地方：**
1. **动画参数集中常量化**。上游把时长、阻尼、速度、缩放全收在 `Constants` 里，一处改全局生效。我们 fork 把 0.4、0.22、0.6、12/180、0.42/0/0.2/1 这些数字散落在代码各处（`layoutAnimationDuration` 还留了一个，但其它全是字面量）。**重构时最该抄的就是这个——把动画曲线/时长/阻尼收一个 enum/struct。**
2. **上游用阻尼 0.8 的"活"弹簧**，我们被逼成阻尼 1.0 的"死"弹簧。这不是我们品味差，是跨进程 FBScene 一弹就露黑底，只能牺牲回弹换稳定。
3. **上游窗口独立、不换位**，天然没黑闪。这是架构红利，不是动画技巧。

**【确证】我们 fork 独有的手搓（上游没有的）：**
1. 每窗一个 `shadowCaster` 透明替身 + `CABasicAnimation` 从 `presentation().shadowPath` 补间——这是为了让换窗中途影子跟着新尺寸走。
2. 换边按钮图标的 `CASpringAnimation(rotation.y)` 半圈翻牌。
3. `performWithoutAnimation` 三段冻结 backdrop/chrome/卡片——纯为压整屏闪。
4. 换边时的"冻结帧 JPEG 封面 / 图标兜底 / 0.6s 硬揭盖"——上游连这个问题都没有。
5. 像素级验帧（2 个 40×40 采样）才揭盖。

**【推测】** 我们现在这套"手搓 CA + performWithoutAnimation + 封面盖图"的组合，本质是在用 UIKit 动画原语硬绕开跨进程 surface 重挂那一帧黑。上游的 block 弹簧之所以能优雅，是因为它不触发 surface 重挂。**真要重构，方向不是"把 CA 动画改回 UIView.animate"，而是想办法让换边别触发跨进程 surface 拆挂**（比如真的把内容做在离屏渲染层里做镜像位移，而不是挪 hosting view 的 frame）——但这属于架构改动，不是动画层能单独解决的。

---

## 七、对重构的参考价值（能直接抄的）

1. **抄上游的 Constants 集中式动画参数表**（上游 `MultitaskDockManager.Constants` 就是范本）。把现在散在 2843 行里的 0.4 / 0.22 / 0.6 / damping12 / stiffness180 / 缓动曲线全部收进一个 `StageAnimation` 枚举。
2. **保留现在的"阻尼 1.0 + `.beginFromCurrentState` + presentation() 续接"**——这部分其实是对的，是为可中断连续切换专门设计的，别退回 0.8 的弹跳。
3. **shadowCaster 从 `presentation().shadowPath` 起补间**这个做法是对的，重构时原样保留，别简化。
4. **换边那三段 `performWithoutAnimation` 别动**——它们是 6 个 commit 才压出来的最小重铺边界（只动卡片 frame+圆角，不碰 z 轴/Dock/几何 commit），动一个就回闪。
5. **封面盖图（冻结 JPEG → 图标兜底 → 0.6s 硬揭）**这套是 fork 独有的兜底，上游没法学，重构时保留，别想着"优雅地删掉它"——根因（跨进程 surface 重挂漏黑）没解决前它不能删。

---

## 八、一句话总结

> 上游 LiveContainer/LiveContainer 的多任务是"自由拖拽浮动窗 + 侧边 Dock"，动画是规规矩矩的 UIKit 弹簧（阻尼 0.8、参数常量化），因为窗不换位所以从没有黑闪。我们 fork 拿上游的虚拟窗口 PoC 重做了"一主三副固定舞台"，这层布局和它的动画**全部是 fork 自己写的**；动画经历了"PropertyAnimator → 手搓 CA + performWithoutAnimation + 冻结帧封面"的被迫演进，现在的死弹簧和黑闪兜底都是被跨进程 surface 重挂逼出来的，不是随手写的。重构能直接借鉴的只有上游的"动画参数集中常量化"，其余 fork 独有部分的思路（可中断续接、影子替身、三段冻结、封面兜底）都应保留。
