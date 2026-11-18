# 迅雷增强 · XunleiEnhance

针对 **迅雷 iOS（`com.xunlei.mvideo`，25.2.90 / build 28156）** 的 TrollStore / 越狱 dylib 插件：
去掉开屏与信息流广告、关掉摇一摇误触跳转，所有开关放在 **设置 → 迅雷增强**（二级菜单，开关样式）。

* **零越狱依赖**：不用 Logos（Logos 会链 `CydiaSubstrate`，TrollStore 注入环境没有它），
  自带 `method_setImplementation` hook 运行时，dylib 只依赖 Foundation / UIKit / libobjc，
  可以直接被 TrollFools 注入。
* **不猜类名**：24 个 hook 点全部从 `TDMVideo` 主二进制的 `__objc_classlist` 静态解析得到，
  方法名 + 类型编码逐条核对（`tools/verify_hooks.py`，当前 24/24 通过）。

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

1. 下载 `com.xiaolvmao.xunleienhance_1.0.0_iphoneos-arm.deb`（Releases 或 Actions 工件）
2. **TrollFools** → `+` → 选这个 deb → 选「迅雷」→ 注入 → 重启迅雷

插件本体不需要 Substrate。设置入口需要 PreferenceLoader 环境（越狱设备天然具备）；
纯 TrollStore 设备上插件按默认配置直接生效，要改配置可编辑
`/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist`（TrollStore 应用带
`platform-application` 权限，沙盒内可读）。

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

```
设置
└── 迅雷增强                ← 二级菜单入口（PreferenceLoader）
    ├─ 总开关              1 个开关
    ├─ 广告拦截            4 个开关
    ├─ 深度屏蔽（激进）    1 个开关
    ├─ 体验优化            3 个开关
    └─ 调试                1 个开关
```

| 文件 | 作用 |
| --- | --- |
| `layout/.../PreferenceLoader/Preferences/XunleiEnhance.plist` | 设置里的入口行 |
| `layout/.../XunleiEnhancePrefs.bundle/Root.plist` | 二级页面，全部 `PSSwitchCell` |
| `XunleiEnhancePrefs/XEPrefsListController.m` | 变更后发 `com.xiaolvmao.xunleienhance/reload` 热加载 |

偏好域：`com.xunlei.mvideo.xunleienhance`。

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
