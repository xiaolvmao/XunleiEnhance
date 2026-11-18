# 迅雷增强 · XunleiEnhance

针对 **迅雷 iOS（`com.xunlei.mvideo`，25.2.90 / build 28156）** 的 TrollStore / 越狱 dylib 插件：
去掉开屏与信息流广告、关掉摇一摇误触跳转。开关面板挂在 **迅雷 App 内的「设置」页最后一行**
（点「迅雷增强」进入，开关样式），不需要 PreferenceLoader，也不需要连点版本号之类的隐藏手势。

* **零越狱依赖**：不用 Logos（Logos 会链 `CydiaSubstrate`，TrollStore 注入环境没有它），
  自带 `method_setImplementation` hook 运行时，dylib 只依赖 Foundation / UIKit / libobjc，
  可以直接被 TrollFools 注入。
* **不猜类名**：30 个 hook 点全部从 `TDMVideo` 主二进制的 `__objc_classlist` 静态解析得到，
  方法名 + 类型编码逐条核对（`tools/verify_hooks.py`，当前 30/30 通过）。

## 功能

| 开关 | 默认 | 说明 | 落点 |
| --- | --- | --- | --- |
| 启用迅雷增强 | 开 | 总开关，关闭后全部逻辑短路 | — |
| 去除开屏广告 | 开 | 自渲染开屏出现即关闭；第三方/聚合开屏的展示入口直接拦截 | `ZY*SplashViewController` / `GMSplashAd` / `JHSplashAd` / `UBiXSplashAd` / `EMNativeAdViewController` |
| 去除信息流广告 | 开 | 广告不再从出价池取出 | `XCAdCoreCacheManager` |
| 拦截广告预加载 | 开 | 预加载数量与缓存计数归零，顺带省流量 | `XCAdCoreCacheManager` |
| 隐藏广告卡片 | 开 | 广告 cell 不挂载广告内容（不改高度，不动列表布局） | `DJXAdCollectionViewCell` |
| 屏蔽全部广告位（激进） | 关 | 允许投放的广告位集合清空 + 拒绝一切广告请求 | `XCAdConfigManager` / `XCAdCoreSlotRequestFrequencyControlManager` |
| 关闭个性化广告推荐 | 开 | 等价于 App 内「广告设置 → 个性化推荐」关闭 | `XCAdConfigManager` |
| 关闭摇一摇 / 扭一扭跳转 | 开 | 误触重灾区，配置层直接关掉 | `XCAdConfigModel` |
| 限制广告自动跳转 | 开 | 禁止广告点击后自动唤起 App Store / 第三方 App | `XCAdConfigManager` |
| 输出调试日志 | 关 | `XunleiEnhance` 前缀日志，便于自查 | — |

改开关即时热加载（Darwin 通知）；开屏相关的判断在下次启动迅雷时读取。

## 安装

### A. TrollStore + TrollFools（推荐）

1. 下载 `com.xiaolvmao.xunleienhance_1.1.0_iphoneos-arm.deb`（Releases 或 Actions 工件）
2. **TrollFools** → `+` → 选这个 deb → 选「迅雷」→ 注入 → 重启迅雷
3. 打开迅雷 → **我的 → 设置** → 拉到最底部 → **迅雷增强**

插件本体不需要 Substrate。设置入口就插在迅雷自己的设置列表里，纯 TrollStore 环境同样可用；
偏好存在 App 容器内（`NSUserDefaults`），注入方式无关，不需要动 `/var/mobile/Library/Preferences`。

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

## 设置界面

入口在迅雷自己的设置列表里，作为**最后一行**出现（不改分组、不动行序，只多一行）：

```
迅雷 → 我的 → 设置
├── …（迅雷原有的设置项）
└── 迅雷增强  去广告 ›        ← 插件加的那一行
     │
     └── 迅雷增强（开关面板）
         ├─ 通用              1 个开关
         ├─ 广告拦截          4 个开关
         ├─ 深度屏蔽（激进）  1 个开关
         ├─ 体验优化          3 个开关
         ├─ 调试              1 个开关
         └─ 恢复默认设置
```

实现方式：hook 迅雷设置页（`_TtC8TDMVideo28CommonSettingsViewController`，类名以
`SettingsViewController` 结尾 + 带表格数据源特征，改名也能兜住）的 6 个索引路径方法，
把「多出来的那一行」拦下来，其余全部原样转发：

| 方法 | 我们的处理 |
| --- | --- |
| `tableView:numberOfRowsInSection:` | 最后一段 +1（读 `[tableView numberOfSections]` 动态取） |
| `tableView:cellForRowAtIndexPath:` | 该行返回自建 cell（`迅雷增强 / 去广告 ›`） |
| `tableView:didSelectRowAtIndexPath:` | 该行 push 插件面板 |
| `tableView:heightForRowAtIndexPath:` | 该行复用首行高度 |
| `tableView:canEditRowAtIndexPath:` | 该行禁止编辑 |
| `tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:` | 该行无滑动菜单 |

其余文件：

| 文件 | 作用 |
| --- | --- |
| `Tweak.m` | hook 运行时 + 广告拦截 + 设置面板（`XESettingsController`） |
| `layout/.../PreferenceLoader/Preferences/XunleiEnhance.plist` | 仅越狱：系统设置里的入口行 |
| `layout/.../XunleiEnhancePrefs.bundle/Root.plist` | 仅越狱：系统设置里的二级页面 |

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
