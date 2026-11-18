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
| 隐藏会员 / 充值推广 | 开 | 会员卡、充值 banner、快鸟试用条整块从布局里塌掉 | 视图层（`VipInfoItemView` / `VipInfoPopView` / `KuaiNiaoVipTryEntranceBar`） |
| 隐藏游戏中心 | 开 | 游戏中心整块塌掉 | 视图层（`GameEntryView` / `GameCenterHeadView`） |
| 隐藏运营推荐位 | 开 | banner、推荐位、活动卡整块塌掉 | 视图层（`RecommendItemView` / `BannerServiceCollectionCell` / `ActivityCardView`） |
| 显示悬浮入口 | 开 | 右侧半透明齿轮，可拖动；关掉后只剩设置页那一行 | — |
| 升级后提示已生效 | 开 | 每个版本首次启动弹一次，兼作注入自证 | — |
| 输出调试日志 | 关 | `XunleiEnhance` 前缀日志，便于自查 | — |

改开关即时热加载（Darwin 通知）；「我的」页净化是**在布局里摘掉**，关掉后需重进该页才恢复；
开屏秒进在下次启动迅雷时读取。

## 安装

### A. TrollStore + TrollFools（推荐）

1. 下载 `com.xiaolvmao.xunleienhance_2.2.1_iphoneos-arm.deb`（Releases 或 Actions 工件）
2. **TrollFools** → `+` → 选这个 deb → 选「迅雷」→ 注入 → 重启迅雷
3. 打开迅雷，**核对入口**：应在 2 秒内弹出「迅雷增强 v2.2.1 已生效」；
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
├─ 「我的」页净化    会员充值 / 游戏中心 / 运营推荐位（真正从布局移除）
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
  └─ _LayoutPersonalCenterViewController 真正的页面，纯 Swift 类
       ├─ 竖向堆叠的卡片（CardBaseView / ActivityCardView / VipInfoItemView …）
       └─ 少量 UICollectionView（BannerServiceCollectionCell）
```

v2.1 有两处硬伤，v2.2 都修掉了：

1. **作用域判定写错**：原来按 VC 类名找 `Mine` / `PersonalCenter`，可顶层是
   `AccountContainerViewController`，第一个 VC 不匹配就 `return NO` —— 等于把所有隐藏
   全关掉。现在判定会往下钻一层看 child VC，且不再「第一个不匹配就放弃」。
2. **只设 `hidden` 不改布局**：卡片自带固定高度约束，`hidden` 只是不绘制，位置照旧
   占着，看起来就是「没隐藏」。现在命中后会把自身高度约束压到 0 并补一条 0 高度约束，
   布局自己塌下去。

> **v2.2.0 曾经在这里用 `removeFromSuperview`，会闪退**：迅雷的 Swift 代码自己持有
> 这些卡片视图，我们把它从视图树上摘走后，它遍历时强制解包就
> `_assertionFailure`（崩溃栈是 `Sequence.forEach` → Swift 断言）。
> 视图树属于 App，不能摘 —— v2.2.1 起只改尺寸，不动树。

所有改动都**排队到下一轮 runloop** 执行，不在 `addSubview` / `layoutSubviews` 的
调用栈里改视图（那会和 App 自己的布局循环打架）。触发点有四个：

- `viewDidAppear`（延迟 0.15s 等布局落定）
- 0.3s 探针（服务端配置回来的板块是异步加的）
- `UIView addSubview:` / `insertSubview:atIndex:`（卡片容器上屏时往下挖一层）
- `UICollectionView layoutSubviews`（cell 是 layout 摆出来的，拦不到内部）

cell 类不单独处理尺寸，改为把它所在的那张卡一起压掉。

另外还有一个**启动熔断**：如果上一次启动没活过 20 秒（说明崩在启动阶段），这次启动会
直接把「我的」页净化停掉，保证 App 能进去 —— 诊断里会显示「已自动停用」。正常使用
（活过 20 秒）不会触发，下次启动自动恢复。

### 诊断

面板最后一组实时显示：版本、hook 装上几项、**最近一次注入的设置页类名与注入次数**、
**「我的」页识别到哪个 VC、拦下了几块、视图树快照**、悬浮入口是否在屏。
「我的页结构」那一项显示抓到的节点数，`复制诊断信息` 会把整棵树一起复制出来。整段可一键复制，排查时直接发出来即可判断是哪一环断了。

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
