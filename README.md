# 迅雷增强 · XunleiEnhance

针对 **迅雷 iOS（`com.xunlei.mvideo`，25.2.90 / build 28156）** 的 TrollStore / 越狱 dylib 插件：
开屏**秒进**、去掉信息流与广告位、关掉摇一摇误触跳转，并把「我的」页的推广板块整块隐掉。
开关面板**三个入口任选其一**（都不是隐藏手势）：屏幕右侧的**悬浮齿轮**、
迅雷 **我的 → 设置 → 列表最下面一行「迅雷增强」**（设置页右上角还有「增强」按钮）、
以及升级后首次启动的提示框。不需要 PreferenceLoader，也不需要连点版本号。

* **零越狱依赖**：不用 Logos（Logos 会链 `CydiaSubstrate`，TrollStore 注入环境没有它），
  自带 `method_setImplementation` hook 运行时，dylib 只依赖 Foundation / UIKit / libobjc，
  可以直接被 TrollFools 注入。
* **不猜类名**：27 个 hook 点全部从 `TDMVideo` 主二进制的 `__objc_classlist` 静态解析得到，
  方法名 + 类型编码逐条核对（`tools/verify_hooks.py`，当前 27/27 通过）。
* **入口不依赖数据源**：设置页那一行是直接替换 `tableFooterView` 注入的视图，
  不需要命中 `UITableView` 的 dataSource，也不受设置页换实现影响。

## 功能

| 开关 | 默认 | 说明 | 落点 |
| --- | --- | --- | --- |
| 启用迅雷增强 | 开 | 总开关，关闭后全部逻辑短路 | — |
| 去除开屏广告 | 开 | 自渲染开屏出现即走「跳过」；第三方/聚合开屏的展示入口直接拦截 | `ZY*SplashViewController` / `GMSplashAd` / `JHSplashAd` / `UBiXSplashAd` / `EMNativeAdViewController` |
| 开屏秒进（不等待） | 开 | 启动链路直接返回「没有开屏要处理」，不展示占位图、不等超时，点图标即进主界面 | `XCSplashService` / `XCSplashView` / `XCSplashContainerViewController` |
| 去除信息流广告 | 开 | 广告不再从出价池取出 | `XCAdCoreCacheManager` |
| 拦截广告预加载 | 开 | 预加载数量与缓存计数归零，顺带省流量 | `XCAdCoreCacheManager` |
| 隐藏广告卡片 | 开 | 广告 cell 不挂载广告内容（不改高度，不动列表布局） | `DJXAdCollectionViewCell` |
| 屏蔽全部广告位（激进） | 关 | 允许投放的广告位集合清空 + 拒绝一切广告请求 | `XCAdConfigManager` / `XCAdCoreSlotRequestFrequencyControlManager` |
| 关闭个性化广告推荐 | 开 | 等价于 App 内「广告设置 → 个性化推荐」关闭 | `XCAdConfigManager` |
| 关闭摇一摇 / 扭一扭跳转 | 开 | 误触重灾区，配置层直接关掉 | `XCAdConfigModel` |
| 限制广告自动跳转 | 开 | 禁止广告点击后自动唤起 App Store / 第三方 App | `XCAdConfigManager` |
| 隐藏会员 / 充值推广 | 开 | 会员卡、充值 banner、快鸟试用条整块塌掉 | `VipInfoItemView` / `VipInfoPopView` / `KuaiNiaoVipTryEntranceBar` / `VipPrivilegeCardCollectionViewCell` |
| 隐藏游戏中心 | 开 | 游戏中心整块塌掉 | `GameEntryView` / `GameCenterHeadView` / `GameCenterCell` |
| 隐藏活动 / 运营卡 | 开 | 活动卡、运营位、签到/福利/任务卡整块塌掉 | `ActivityCardView` / `OperationCard` / `WelfareCard` 等 |
| 隐藏推荐位 / banner | 开 | 推荐位与 banner 卡整块塌掉 | `RecommendItemView` / `BannerServiceCollectionCell` |
| 隐藏云盘空间卡 | 关 | 云盘空间那块卡片（功能入口） | `CloudSpaceCardView` / `AssetsCard` |
| 隐藏常用功能九宫格 | 关 | 入口九宫格与标题条（功能入口） | `EntranceItemView` / `EntranceTitleBar` |
| 隐藏用户信息 / 资产区 | 关 | 头像昵称与资产统计区（功能区域） | `UserInfoSlider` |
| 隐藏所有非功能板块 | 关 | 极简模式：按尺寸认板块，内置清单没覆盖到的也一并清掉，只留云盘/九宫格/用户信息/设置 | 视图层，仅在「我的」页生效 |
| 启用自定义隐藏 | 关 | 填类名片段一起隐藏，兜住内置清单漏掉的板块 | 面板里手填，逗号分隔 |
| 显示悬浮入口 | 开 | 右侧半透明齿轮，可拖动；关掉后只剩设置页那一行 | — |
| 升级后提示已生效 | 开 | 每个版本首次启动弹一次，兼作注入自证 | — |
| 输出调试日志 | 关 | `XunleiEnhance` 前缀日志，便于自查 | — |

改开关即时热加载（Darwin 通知）；「我的」页净化改完**重进该页**生效；
开屏秒进在下次启动迅雷时读取。

## 安装

### A. TrollStore + TrollFools（推荐）

1. 下载 `com.xiaolvmao.xunleienhance_2.3.0_iphoneos-arm.deb`（Releases 或 Actions 工件）
2. **TrollFools** → `+` → 选这个 deb → 选「迅雷」→ 注入 → 重启迅雷
3. 打开迅雷，**核对入口**：应在 2 秒内弹出「迅雷增强 v2.3.0 已生效」；
   同时屏幕右侧出现半透明齿轮（可拖动，位置会记住）

如果没有弹窗、也没有齿轮，说明 **dylib 没被加载**（注入失败），与插件逻辑无关 ——
换 TrollFools 版本重注入，或改用 `.tipa`。

插件本体不需要 Substrate。偏好存在 App 容器内（`NSUserDefaults`），注入方式无关，
不需要动 `/var/mobile/Library/Preferences`。

越狱环境下 deb 的 `layout` 会装到系统里，此时**额外**会多一个「设置 → 迅雷增强」入口，
两处改的是同一份配置。

### B. 打包成 .tipa（macOS）

```bash
./scripts/make_tipa.sh ~/Downloads/迅雷.ipa packages/*.deb
# 产出 XunleiEnhance.tipa，直接拖进 TrollStore 安装
```
依赖 `insert_dylib`、`ldid`、`unzip`。

### C. 越狱

```bash
make package install          # rootful
THEOS_PACKAGE_SCHEME=rootless make package install
```

## 构建

`push` 即触发 GitHub Actions 编译（ubuntu + Theos），产物在 Actions 工件里；
打 `v*` tag 会自动发 Release，内含 `.deb` 与裸 `XunleiEnhance.dylib`。

本地：

```bash
export THEOS=~/theos
make package FINALPACKAGE=1
```

## 入口与设置面板

**三个入口互相独立**，任何一个失效都不影响另外两个：

| # | 入口 | 依赖 | 说明 |
| --- | --- | --- | --- |
| ① | 迅雷 `我的 → 设置` 列表最下面一行「迅雷增强 去广告 · 开屏秒进 · 我的页净化」 | 只需设置页的 tableView | 视图注入，最原生 |
| ② | 屏幕右侧半透明**悬浮齿轮** | 无（挂 keyWindow） | 版本更新也不会失效；可在面板里关掉 |
| ③ | 升级后首次启动的「已生效」提示框 | 无 | 兼作注入是否成功的自证 |

设置页右上角还会额外挂一个「增强」按钮（页面自带右侧按钮时不覆盖）。

```
迅雷增强（开关面板）
├─ 通用              启用迅雷增强
├─ 广告拦截          去除开屏 / 开屏秒进 / 信息流 / 预加载 / 卡片
├─ 「我的」页推广    会员充值 / 游戏中心 / 活动运营 / 推荐位
├─ 「我的」页功能    云盘卡 / 九宫格 / 用户信息（默认保留，可选隐藏）
├─ 「我的」页极简    一键清掉所有非功能板块（兜底）
├─ 「我的」页自定义  填类名片段，兜住内置清单漏掉的板块
├─ 深度屏蔽（激进）  屏蔽全部广告位
├─ 体验优化          关个性化 / 关摇一摇 / 限制自动跳转
├─ 入口              显示悬浮入口 / 升级后提示
├─ 调试              输出调试日志
└─ 诊断              版本 · Hook 安装 · 入口状态 · 一键复制诊断文本
```

### ① 设置页那一行是怎么插的

v2.0 走的是「hook 设置页 dataSource，把最后一段的行数 +1」：只要设置页的
`UITableView` 的 dataSource 不是 VC 本身（Swift 页面很常见），这条路就彻底失效 ——
表现就是**齿轮在、设置里那行不在**。

v2.1 换成视图级注入，跟数据源完全无关：

1. 0.5s 一次的轻量探针（`NSRunLoopCommonModes`，滚动中也不会停）取当前顶层 VC；
2. 类名含 `Setting`（或标题是「设置 / 設定 / Settings」）即认为是设置页；
3. 在它的视图树里找第一个 `UITableView`，把 `tableFooterView` 换成自建条目
   （圆角卡片 + `迅雷增强` / `去广告 · 开屏秒进 · 我的页净化` + 箭头）；
   页面原本有 footer 时用容器包一层，不覆盖原内容；
4. 没有 tableView 的页面退化成贴底一条，位置固定在安全区上方；
5. 同一 VC 用关联对象打标，只注入一次；页面自带右侧按钮时不覆盖，否则挂「增强」。

因为位置是「列表最后一行」本身，不需要猜段数、不需要类自己实现数据源方法，
也不会因为迅雷改设置页实现而失效。

### ② 「我的」页是怎么净化的

「我的」页是 Swift 页面，结构是：

```
AccountContainerViewController          tab 上挂的容器，类名里没有 Mine
  └─ PersonalCenterViewController       真正的页面（Swift，运行时才注册）
       ├─ 竖向堆叠的卡片（CardBaseView / ActivityCardView / VipInfoItemView …）
       └─ 若干 UICollectionView（BannerServiceCollectionCell 等）
```

三个坑，前两版各踩了一个：

1. **作用域判定写错**（v2.1）：按 VC 类名找 `Mine` / `PersonalCenter`，可顶层是
   `AccountContainerViewController`，第一个 VC 不匹配就 `return NO` —— 等于把所有隐藏
   全关掉。v2.3 直接去掉这层判定：上面那些类名本来就只在个人中心出现，够特异。
2. **摘视图树导致崩溃**（v2.2.0）：`removeFromSuperview` 把卡片摘走后，迅雷的 Swift
   代码再遍历自己持有的数组时强制解包 → `_assertionFailure`。视图树属于 App，不能摘。
3. **启动熔断把净化锁死**（v2.2.1，这就是「板块并没隐藏」的直接原因）：
   熔断用「上次启动有没有活过 20 秒」判断崩溃，但用户装完立刻测、测完就退，
   20 秒内退出就打不上存活标记，下次启动继续判「崩过」→ **永远熔断、永远不隐藏**。
   v2.3 改成熔断最多触发一次，第二次启动一定恢复；阈值降到 6 秒；面板里还有
   「重置保护状态」可以手动清掉。

现在只做一件事：**改属性，不改结构**。

- 命中板块后 `hidden = YES`，再把自身高度约束压到 0、补一条 0 高度兜底约束（优先级 990）；
- frame 布局的卡片没有约束，就把 `frame.height` 直接压 0，并靠 `UIView layoutSubviews`
  每次重新压一次（App 每次布局都会把 frame 写回来，只压一次等于没压）；
- 在 `UIStackView` 里只设 `hidden`，stack 自己会塌成 0；
- collection view 的 cell 优先向上取「整张卡」来隐藏；实在找不到才隐藏 cell 本身，
  且不给自己打标（cell 会被复用池拉去显示别的板块）。

所有改动都**排队到下一轮 runloop** 执行，不在 `addSubview` / `layoutSubviews` 的调用栈里
改视图（那会和 App 自己的布局循环打架）。触发点：`addSubview:` / `insertSubview:atIndex:`
（卡片上屏）、`UICollectionView layoutSubviews`（cell 是布局摆出来的）、0.3 秒轻量探针
（服务端配置回来的板块是异步加的）。

### 诊断

面板最后一组实时显示：版本、hook 装上几项、设置页入口类名与注入次数、
「我的」页识别到哪个 VC、拦下了几块、**当前这些板块的类名与尺寸**、视图树快照、
净化保护状态、悬浮入口是否在屏。

`复制诊断信息` 会把开关状态、板块清单、整棵视图树一起复制出来。如果有板块没被隐藏，
把这段发出来就能直接看到漏掉的类名 —— 内置清单补进去，或者你自己在
「编辑自定义类名」里填上就可以。

「重置保护状态」用于万一净化被熔断停掉时手动复位。

其余文件：

| 文件 | 作用 |
| --- | --- |
| `Tweak.m` | hook 运行时 + 广告拦截 + 三个入口 + 设置面板（`XESettingsController`） |
| `layout/.../PreferenceLoader/Preferences/XunleiEnhance.plist` | 仅越狱：系统设置里的入口行 |
| `layout/.../XunleiEnhancePrefs.bundle/Root.plist` | 仅越狱：系统设置里的二级页面（16 个开关） |

偏好存储：**App 容器内的 `NSUserDefaults`（主）**，兼容读取
`com.xunlei.mvideo.xunleienhance` 偏好域（越狱面板写入的值）。改动即时生效（Darwin 通知热加载）。

## 技术说明

### 广告链路怎么收敛

迅雷 25.x 的广告是 **自建聚合 SDK（XC 模块，500 个类）+ 一堆第三方 SDK**
（穿山甲 BU/CSJ、优量汇 GDT、快手 KS、百度、倍孜 AdScope、UBiX、JHAd、JADYun…），
逐家打不可维护。插件只打三层收敛点：

1. **出价池**：`-[XCAdCoreCacheManager popTopPriceAdFromCacheWithStrategy:slotTag:ext:bindContext:adStyle:throughModel:]`
   所有广告最终都从这儿取出；返回 `nil` 时业务侧走「无广告」分支，表现与拉取失败一致，
   不会留占位空洞。
2. **广告位闸门**：`-[XCAdConfigManager filterSlotTags:]`、
   `-[XCAdCoreSlotRequestFrequencyControlManager isAllowRequestAdWithSlot:slotTag:traceId:]`。
3. **展示入口**：开屏的自渲染 VC + 各聚合 SDK 的展示方法，逐个拦截。

### hook 运行时

`%hook`（Logos）生成的代码调用 `MSHookMessageEx`，链接 `CydiaSubstrate`；
TrollStore 环境下没有这个 dylib，注入后直接加载失败。所以这里自己维护一张表：

```c
#define XE_HOOK(C, S, IMPL, ORIG) { #C, #S, (IMP)(IMPL), (IMP *)&(ORIG) }
```

`constructor` 里遍历表，`class_getInstanceMethod` + `method_setImplementation`，
原始 IMP 存进 `orig` 指针供转发。类/方法缺失时跳过并记日志，跨版本不会崩。

`%orig` 的对等物就是手动转发：

```c
return xe_orig_popTopPrice(self, _cmd, strategy, slotTag, ext, ctx, adStyle, model);
```

### 符号是怎么挖出来的

```bash
python3 tools/dump_macho_objc.py Payload/TDMVideo.app/TDMVideo tools/symbols.json
python3 tools/verify_hooks.py --strict
```

解析链路（纯 Python，无依赖）：

```
__DATA_CONST,__objc_classlist → class_t → class_ro_t（chained fixup 解码）
  → baseMethodList（relative method list, entsize=12）
  → name 偏移 → __objc_selrefs 槽位（再解一次 chained pointer）→ __objc_methname
```

坑点：`name` 的相对偏移指向的是 **selref 槽位**，不是字符串本身，必须二次解码，
否则拿到的是乱码；`types` 的偏移才是直接落在 `__objc_methtype` 上的。

### 兼容性

* 目标：迅雷 25.2.90（`CFBundleVersion 28156`），架构 arm64
* 其它版本的类名/方法大概率一致但不保证；升级后先跑 `verify_hooks.py`
* 遇到页面异常/内容加载不出来，先关掉「屏蔽全部广告位」再排查

## 免责声明

仅供个人学习与逆向研究，请勿用于商业用途，请支持正版与官方会员。
使用本插件造成的账号异常、功能缺失等后果由使用者自行承担。
