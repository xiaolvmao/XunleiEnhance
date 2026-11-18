# 迅雷增强 · XunleiEnhance

针对 **迅雷 iOS (com.xunlei.mvideo, 25.2.90)** 的 TrollStore / 越狱 dylib 插件：
去掉广告与迷惑性跳转，功能开关全部放在 **设置 → 迅雷增强**（二级菜单，开关样式）。

> 所有 hook 点都是从 `TDMVideo` 主二进制里静态解析出来的真实类与方法，
> 由 `tools/verify_hooks.py` 逐条核对（当前 24/24 通过），不是凭经验猜的类名。

## 功能

| 开关 | 说明 | 实现层 |
| --- | --- | --- |
| 启用迅雷增强 | 总开关，关闭后全部逻辑短路 | — |
| 去除开屏广告 | 自渲染开屏出现即关闭；第三方/聚合开屏的展示入口直接拦截 | `ZY*SplashViewController` / `GMSplashAd` / `JHSplashAd` / `UBiXSplashAd` / `EMNativeAdViewController` |
| 去除信息流广告 | 信息流广告不再从出价池取出 | `XCAdCoreCacheManager` |
| 拦截广告预加载 | 预加载数量与缓存计数直接归零，省流量 | `XCAdCoreCacheManager` |
| 隐藏广告卡片 | 广告 cell 不再挂载广告内容（不改高度，不破坏列表布局） | `DJXAdCollectionViewCell` |
| 屏蔽全部广告位（激进） | 允许投放的广告位集合清空 + 拒绝一切广告请求 | `XCAdConfigManager` / `XCAdCoreSlotRequestFrequencyControlManager` |
| 关闭个性化广告推荐 | 等价于 App 内「广告设置 → 个性化推荐」关闭 | `XCAdConfigManager` |
| 关闭摇一摇 / 扭一扭跳转 | 误触重灾区，配置层直接关掉 | `XCAdConfigModel` |
| 限制广告自动跳转 | 禁止广告点击后自动唤起 App Store / 第三方 App | `XCAdConfigManager` |
| 输出调试日志 | `XunleiEnhance` 前缀日志，便于自查 | — |

改动即时热加载（Darwin 通知），只有开屏类判断在下次启动时读取。

## 安装

### A. TrollStore（推荐，无需越狱）

1. 从 [Releases](../../releases) 或 Actions 工件下载 `com.xiaolvmao.xunleienhance_*.deb`
2. 用 **TrollFools** 打开 → `+` → 选择这个 deb → 选择「迅雷」→ 注入
3. 重启迅雷

设置入口需要 PreferenceLoader 环境（越狱设备原生支持）。在纯 TrollStore 环境下
插件本身照常生效，默认设置即为推荐配置；如需调整，可先用 A 路径注入后
手动改写 `/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist`。

### B. 打包成 .tipa（macOS）

```bash
./scripts/make_tipa.sh ~/Downloads/迅雷.ipa packages/*.deb
# 产出 XunleiEnhance.tipa，可直接拖进 TrollStore 安装
```

### C. 越狱（rootful）

```bash
make package install
```
rootless（Dopamine 等）请加 `THEOS_PACKAGE_SCHEME=rootless`。

## 构建

仓库自带 GitHub Actions（`.github/workflows/build.yml`），push 即编译，产物在
Actions 工件里；打 `v*` tag 会自动发 Release。

本地构建需要 [Theos](https://github.com/theos/theos)：

```bash
export THEOS=~/theos
make package FINALPACKAGE=1
```

## 设置界面

```
设置
└── 迅雷增强            ← 二级菜单入口（PreferenceLoader）
    ├── 总开关
    ├── 广告拦截        （4 个开关）
    ├── 深度屏蔽        （1 个开关）
    ├── 体验优化        （3 个开关）
    └── 调试            （1 个开关）
```

* 入口：`layout/Library/PreferenceLoader/Preferences/XunleiEnhance.plist`
* 页面：`XunleiEnhancePrefs.bundle/Root.plist`（全部 `PSSwitchCell`）
* 存储：`com.xunlei.mvideo.xunleienhance` 域
* 变更后由 `XEPrefsListController` 发 `com.xiaolvmao.xunleienhance/reload` 通知热加载

## 技术说明

### 广告链路

迅雷 25.x 的广告是 **自建聚合 SDK（XC 模块，500 个类）+ 一堆第三方 SDK**
（穿山甲 BU/CSJ、优量汇 GDT、快手 KS、百度、倍孜 AdScope、UBiX、JHAd、JADYun…）。
逐家 SDK 去打是不可维护的，所以插件只打三处**收敛点**：

1. **出价池**：`-[XCAdCoreCacheManager popTopPriceAdFromCacheWithStrategy:slotTag:ext:bindContext:adStyle:throughModel:]`
   所有广告（开屏/信息流/激励）最终都从这里取出；返回 `nil` 时业务侧走「无广告」分支，
   表现与拉取失败一致，不会出现占位空洞。
2. **广告位闸门**：`-[XCAdConfigManager filterSlotTags:]` 与
   `-[XCAdCoreSlotRequestFrequencyControlManager isAllowRequestAdWithSlot:slotTag:traceId:]`。
3. **展示入口**：开屏的几个展示方法（自渲染 + 各聚合 SDK）逐个拦截。

### 符号是怎么来的

`tools/symbols.json` 由自写 Mach-O 解析器从 IPA 里导出：

```
__DATA_CONST,__objc_classlist → class_t → class_ro_t
  → baseMethodList（relative method list, entsize=12）
  → nameOffset 指向 selref slot（chained fixup）→ __objc_methname
```

坑点：`nameOffset` 是相对偏移，但指向的是 **selref 槽位**而不是字符串本身，
要再解一次 chained pointer 才能拿到 selector；`types` 才是相对 `__objc_methtype` 的直接偏移。

校验：

```bash
python3 tools/verify_hooks.py --strict
```

### 兼容性

* 目标版本：迅雷 25.2.90（`CFBundleVersion 28156`）
* 其它版本的类名/方法大概率一致但不保证；升级后先跑 `verify_hooks.py`
* 架构：arm64 / arm64e

## 免责声明

仅供个人学习与逆向研究使用，请勿用于商业用途；请支持正版与官方会员。
使用本插件造成的账号异常、功能缺失等后果由使用者自行承担。
