#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────────
//  迅雷增强 / XunleiEnhance
//  目标：com.xunlei.mvideo (迅雷 25.2.90, TDMVideo)
//
//  设计要点
//  1. 不用 Logos：Logos 生成的代码依赖 CydiaSubstrate 的 MSHookMessageEx，
//     而 TrollStore 注入环境没有 Substrate。这里用 method_setImplementation
//     自己接管，dylib 因此只依赖 Foundation / UIKit / libobjc，可以直接被
//     TrollFools 注入。
//  2. 所有 hook 点来自对 TDMVideo 主二进制 __objc_classlist 的静态解析，
//     方法名与类型编码逐条核对（tools/verify_hooks.py）。
// ─────────────────────────────────────────────────────────────────────────────

#define XE_PREF_DOMAIN_STR "com.xunlei.mvideo.xunleienhance"
#define XE_NOTIFY_STR "com.xiaolvmao.xunleienhance/reload"
#define XE_VERSION @"2.3.0"

static NSDictionary *gXEPrefs = nil;

// 由「入口」段实现，各段都要用，先声明
static UIViewController *XETopViewController(void);

#pragma mark - 日志

static inline void XELog(NSString *fmt, ...) {
    if (![gXEPrefs[@"debugLog"] boolValue]) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[XunleiEnhance] %@", msg);
}

#pragma mark - 偏好存储
// TrollStore / TrollFools 注入时，deb 里的 PreferenceBundle 根本不会落到
// /Library/PreferenceBundles，系统「设置」里不会有入口；沙盒进程也未必写得进
// /var/mobile/Library/Preferences。所以偏好主存储放在 App 自己的
// NSUserDefaults（容器内，任何注入方式都能读写），越狱偏好域只作兼容读源。

static NSDictionary *XEDefaults(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"enabled": @YES,
            @"blockSplash": @YES,
            @"instantSplash": @YES,   // 开屏秒进：不展示、不等待
            @"blockFeedAd": @YES,
            @"blockAdLoad": @YES,
            @"hideAdCell": @YES,
            @"blockAllSlots": @NO,
            @"disablePersonalize": @YES,
            @"disableShake": @YES,
            @"limitAutoJump": @YES,
            // 「我的」页净化（推广类默认开，功能类默认关）
            @"hideMineVip": @YES,        // 会员 / 充值推广
            @"hideMineGame": @YES,       // 游戏中心
            @"hideMineActivity": @YES,   // 活动 / 运营卡
            @"hideMineFeed": @YES,       // 推荐位 / banner
            @"hideMineCloud": @NO,       // 云盘空间卡
            @"hideMineGrid": @NO,        // 常用功能九宫格
            @"hideMineUser": @NO,        // 用户信息 / 资产区
            @"hideMineAll": @NO,         // 极简模式：隐藏所有非功能板块
            @"hideMineCustomOn": @NO,    // 自定义关键词总开关
            @"hideMineCustom": @"",      // 自定义关键词（逗号分隔）
            @"debugLog": @NO,
            // 入口相关
            @"floatingEntry": @YES,   // 悬浮球（不依赖 App 任何页面结构）
            @"showBeacon": @YES,      // 每次升级后首次启动弹一次「已注入」
        };
    });
    return d;
}

static NSString *XEPrefFilePath(void) {
    static NSArray<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            @"/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist",
            @"/var/jb/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist",
        ];
    });
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static void XEReloadPrefs(void) {
    NSMutableDictionary *dict = [XEDefaults() mutableCopy];
    NSArray<NSString *> *keys = [XEDefaults() allKeys];

    // 1) 越狱偏好域（/Library/PreferenceBundles 面板写入的值）
    for (NSString *k in keys) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k,
                                                       CFSTR(XE_PREF_DOMAIN_STR));
        if (v) dict[k] = (__bridge_transfer id)v;
    }

    // 2) 兜底：直接读 plist（沙盒内 CFPreferences 被重定向时使用）
    NSString *path = XEPrefFilePath();
    if (path) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) {
            for (NSString *k in keys) {
                if (d[k]) dict[k] = d[k];
            }
        }
    }

    // 3) App 内设置面板（最高优先级）：写在 App 自己的 NSUserDefaults 里
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in keys) {
        id v = [ud objectForKey:k];
        if (v) dict[k] = v;
    }

    gXEPrefs = [dict copy];
}

static void XEPrefsDidChange(void) {
    XEReloadPrefs();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(XE_NOTIFY_STR), NULL, NULL, true);
}

// 面板里改一个开关：先写 App 内存储（一定成功），再尽力同步到越狱偏好域，
// 这样越狱环境下系统设置面板里看到的也是同一个值。
static void XESavePref(NSString *key, id value) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:value forKey:key];
    [ud synchronize];
    @try {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 CFSTR(XE_PREF_DOMAIN_STR));
        CFPreferencesAppSynchronize(CFSTR(XE_PREF_DOMAIN_STR));
    } @catch (NSException *e) {
        // 沙盒内写全局偏好域会被拒，忽略即可
    }
    XEPrefsDidChange();
    XELog(@"pref %@ = %@", key, value);
}

static void XEResetPrefs(void) {
    for (NSString *k in [XEDefaults() allKeys]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:k];
        @try {
            CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, CFSTR(XE_PREF_DOMAIN_STR));
        } @catch (NSException *e) {
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    CFPreferencesAppSynchronize(CFSTR(XE_PREF_DOMAIN_STR));
    XEPrefsDidChange();
}

static BOOL XEBool(NSString *key, BOOL fallback) {
    if (!gXEPrefs) XEReloadPrefs();
    id v = gXEPrefs[key];
    return v ? [v boolValue] : fallback;
}

static inline BOOL XEEnabled(void)          { return XEBool(@"enabled", YES); }
static inline BOOL XE_BlockSplash(void)     { return XEEnabled() && XEBool(@"blockSplash", YES); }
static inline BOOL XE_InstantSplash(void)   { return XE_BlockSplash() && XEBool(@"instantSplash", YES); }
static inline BOOL XE_HideMineVip(void)      { return XEEnabled() && XEBool(@"hideMineVip", YES); }
static inline BOOL XE_HideMineGame(void)     { return XEEnabled() && XEBool(@"hideMineGame", YES); }
static inline BOOL XE_HideMineActivity(void) { return XEEnabled() && XEBool(@"hideMineActivity", YES); }
static inline BOOL XE_HideMineFeed(void)     { return XEEnabled() && XEBool(@"hideMineFeed", YES); }
static inline BOOL XE_HideMineCloud(void)    { return XEEnabled() && XEBool(@"hideMineCloud", NO); }
static inline BOOL XE_HideMineGrid(void)     { return XEEnabled() && XEBool(@"hideMineGrid", NO); }
static inline BOOL XE_HideMineUser(void)     { return XEEnabled() && XEBool(@"hideMineUser", NO); }
static inline BOOL XE_HideMineCustom(void)   { return XEEnabled() && XEBool(@"hideMineCustomOn", NO); }
static inline BOOL XE_HideMineAll(void)      { return XEEnabled() && XEBool(@"hideMineAll", NO); }
static inline BOOL XE_BlockFeedAd(void)     { return XEEnabled() && XEBool(@"blockFeedAd", YES); }
static inline BOOL XE_BlockAdLoad(void)     { return XEEnabled() && XEBool(@"blockAdLoad", YES); }
static inline BOOL XE_HideAdCell(void)      { return XEEnabled() && XEBool(@"hideAdCell", YES); }
static inline BOOL XE_BlockAllSlots(void)   { return XEEnabled() && XEBool(@"blockAllSlots", NO); }
static inline BOOL XE_DisablePersonalize(void){ return XEEnabled() && XEBool(@"disablePersonalize", YES); }
static inline BOOL XE_DisableShake(void)    { return XEEnabled() && XEBool(@"disableShake", YES); }
static inline BOOL XE_LimitAutoJump(void)   { return XEEnabled() && XEBool(@"limitAutoJump", YES); }

static void XEPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    XEReloadPrefs();
    XELog(@"prefs reloaded: %@", gXEPrefs);
}

#pragma mark - 极简 hook 运行时

typedef struct {
    const char *cls;
    const char *sel;
    IMP imp;
    IMP *orig;
} XEHookEntry;

#define XE_HOOK(C, S, IMPL, ORIG) { #C, #S, (IMP)(IMPL), (IMP *)&(ORIG) }

// 装一个 hook：类或方法不存在就跳过并记录（不同版本不至于崩）
static BOOL XEInstallOn(Class cls, const char *selName, IMP imp, IMP *orig) {
    if (!cls || !selName) return NO;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return NO;
    IMP prev = method_setImplementation(m, imp);
    if (orig && *orig == NULL) *orig = prev;
    return YES;
}

static BOOL XEInstall(XEHookEntry e) {
    Class cls = objc_getClass(e.cls);
    if (!cls) {
        XELog(@"skip %s (class not found)", e.cls);
        return NO;
    }
    if (!XEInstallOn(cls, e.sel, e.imp, e.orig)) {
        XELog(@"skip %s %s (method not found)", e.cls, e.sel);
        return NO;
    }
    return YES;
}

#pragma mark - 广告核心：出价池拦截
// XC SDK 的开屏 / 信息流 / 激励广告最终都从 CacheManager 的出价池 pop 出来。
// 这里返回空 == 「没有任何可用广告」，业务侧走无广告分支（与拉取失败表现一致）。

static id (*xe_orig_popTopPrice)(id, SEL, id, id, id, id, NSUInteger, id);
static id xe_popTopPrice(id self, SEL _cmd, id strategy, id slotTag, id ext,
                         id ctx, NSUInteger adStyle, id model) {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) {
        XELog(@"block popTopPrice slot=%@ style=%lu", slotTag, (unsigned long)adStyle);
        return nil;
    }
    return xe_orig_popTopPrice(self, _cmd, strategy, slotTag, ext, ctx, adStyle, model);
}

static id (*xe_orig_popAll)(id, SEL, id, id, NSUInteger);
static id xe_popAll(id self, SEL _cmd, id ctx, id slotTag, NSUInteger adStyle) {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) {
        XELog(@"block popAll slot=%@", slotTag);
        return @[];
    }
    return xe_orig_popAll(self, _cmd, ctx, slotTag, adStyle);
}

static NSUInteger (*xe_orig_preloadCount)(id, SEL, id, NSUInteger);
static NSUInteger xe_preloadCount(id self, SEL _cmd, id strategy, NSUInteger adStyle) {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) return 0;
    return xe_orig_preloadCount(self, _cmd, strategy, adStyle);
}

static NSUInteger (*xe_orig_cacheCount)(id, SEL, id, NSUInteger);
static NSUInteger xe_cacheCount(id self, SEL _cmd, id slotTag, NSUInteger adStyle) {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) return 0;
    return xe_orig_cacheCount(self, _cmd, slotTag, adStyle);
}

#pragma mark - 广告位闸门

static id (*xe_orig_filterSlotTags)(id, SEL, id);
static id xe_filterSlotTags(id self, SEL _cmd, id tags) {
    if (XE_BlockAllSlots()) {
        XELog(@"block all slot tags (%lu)", (unsigned long)[tags count]);
        return @[];
    }
    return xe_orig_filterSlotTags(self, _cmd, tags);
}

static void (*xe_orig_fetchRealtime)(id, SEL);
static void xe_fetchRealtime(id self, SEL _cmd) {
    if (XE_BlockAllSlots()) {
        XELog(@"skip realtime ad config fetch");
        return;
    }
    xe_orig_fetchRealtime(self, _cmd);
}

static BOOL (*xe_orig_effDisablePersonalize)(id, SEL);
static BOOL xe_effDisablePersonalize(id self, SEL _cmd) {
    if (XE_DisablePersonalize()) return YES;
    return xe_orig_effDisablePersonalize(self, _cmd);
}

static BOOL (*xe_orig_disablePersonalize)(id, SEL);
static BOOL xe_disablePersonalize(id self, SEL _cmd) {
    if (XE_DisablePersonalize()) return YES;
    return xe_orig_disablePersonalize(self, _cmd);
}

static BOOL (*xe_orig_autoClickJumpLimit)(id, SEL);
static BOOL xe_autoClickJumpLimit(id self, SEL _cmd) {
    if (XE_LimitAutoJump()) return YES;
    return xe_orig_autoClickJumpLimit(self, _cmd);
}

static BOOL (*xe_orig_allowRequest)(id, SEL, id, id, id);
static BOOL xe_allowRequest(id self, SEL _cmd, id slot, id slotTag, id traceId) {
    if (XE_BlockAllSlots()) {
        XELog(@"deny ad request slot=%@ tag=%@", slot, slotTag);
        return NO;
    }
    return xe_orig_allowRequest(self, _cmd, slot, slotTag, traceId);
}

#pragma mark - 配置模型：摇一摇 / 扭一扭

static BOOL (*xe_orig_disableShake)(id, SEL);
static BOOL xe_disableShake(id self, SEL _cmd) {
    if (XE_DisableShake()) return YES;
    return xe_orig_disableShake(self, _cmd);
}

static int (*xe_orig_shakeState)(id, SEL);
static int xe_shakeState(id self, SEL _cmd) {
    if (XE_DisableShake()) return 0;
    return xe_orig_shakeState(self, _cmd);
}

#pragma mark - 开屏广告：自渲染

// 「秒进」的关键：不是把已经显示的开屏动画关掉（那一定会有 0.1~0.3s 的闪现），
// 而是在开屏还没被展示前就走「跳过」分支——
//   ① XCSplashService 的启动入口直接返回「没有开屏要处理」，主界面立刻出来；
//   ② XCSplashView 拒绝展示广告；
//   ③ 容器真的出现了（旧版本 / 后台回前台），立刻 stopCutDown + skipAction，0 延迟。
static void xe_closeSplash(id vc) {
    SEL stop = NSSelectorFromString(@"stopCutDown");
    SEL skip = NSSelectorFromString(@"skipAction");
    SEL close = NSSelectorFromString(@"closeAd");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([vc respondsToSelector:stop]) [vc performSelector:stop];
    // skipAction 才是用户在「跳过」按钮上点的那条路：报表 / 回调 / 关窗都走完整流程
    if ([vc respondsToSelector:skip]) {
        [vc performSelector:skip];
    } else if ([vc respondsToSelector:close]) {
        [vc performSelector:close];
    } else {
        XELog(@"%@ has neither skipAction nor closeAd", NSStringFromClass([vc class]));
        return;
    }
#pragma clang diagnostic pop
    XELog(@"skipped self-rendered splash: %@", NSStringFromClass([vc class]));
}

static void (*xe_orig_mixSplashWillAppear)(id, SEL, BOOL);
static void xe_mixSplashWillAppear(id self, SEL _cmd, BOOL animated) {
    xe_orig_mixSplashWillAppear(self, _cmd, animated);
    if (!XE_BlockSplash()) return;
    // 0 延迟：本 runloop 结束就跳过，肉眼看不到开屏
    dispatch_async(dispatch_get_main_queue(), ^{
        xe_closeSplash(self);
    });
}

static void (*xe_orig_customSplashWillAppear)(id, SEL, BOOL);
static void xe_customSplashWillAppear(id self, SEL _cmd, BOOL animated) {
    xe_orig_customSplashWillAppear(self, _cmd, animated);
    if (!XE_BlockSplash()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        xe_closeSplash(self);
    });
}

#pragma mark - 开屏秒进：启动链路拦截

// 保险丝：万一某个版本的启动流程在「没有开屏」之后仍然卡在开屏容器上，
// 1.5s 后把还停在屏幕上的 Splash VC 关掉，保证一定进得了主界面。
static void XESplashWatchdog(void) {
    static BOOL armed = NO;
    if (armed) return;
    armed = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = XETopViewController();
        NSString *cls = NSStringFromClass([top class]);
        if (!cls || [cls rangeOfString:@"Splash" options:NSCaseInsensitiveSearch].location == NSNotFound)
            return;
        XELog(@"watchdog: dismiss stuck splash %@", cls);
        UIViewController *presenter = top.presentingViewController ?: top;
        [presenter dismissViewControllerAnimated:NO completion:nil];
    });
}

// 返回 NO == 「这次启动没有开屏要处理」，App 直接进主界面，不占位、不等待。
static BOOL (*xe_orig_splashLaunch)(id, SEL, id, id);
static BOOL xe_splashLaunch(id self, SEL _cmd, id slotTag, id ext) {
    if (XE_InstantSplash()) {
        XELog(@"skip splash at launch (slotTag=%@)", slotTag);
        XESplashWatchdog();
        return NO;
    }
    return xe_orig_splashLaunch(self, _cmd, slotTag, ext);
}

static BOOL (*xe_orig_splashShow)(id, SEL, id, id);
static BOOL xe_splashShow(id self, SEL _cmd, id ad, id strategy) {
    if (XE_InstantSplash()) {
        XELog(@"refuse to present splash view");
        XESplashWatchdog();
        return NO;
    }
    return xe_orig_splashShow(self, _cmd, ad, strategy);
}

static void (*xe_orig_splashContainerAppear)(id, SEL, BOOL);
static void xe_splashContainerAppear(id self, SEL _cmd, BOOL animated) {
    xe_orig_splashContainerAppear(self, _cmd, animated);
    if (!XE_BlockSplash()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        xe_closeSplash(self);
    });
}

#pragma mark - 开屏广告：第三方 / 聚合 SDK 展示入口

static void (*xe_orig_gmShowSplash)(id, SEL, id);
static void xe_gmShowSplash(id self, SEL _cmd, id vc) {
    if (XE_BlockSplash()) { XELog(@"block GM splash"); return; }
    xe_orig_gmShowSplash(self, _cmd, vc);
}

static void (*xe_orig_gmShowCard)(id, SEL, id);
static void xe_gmShowCard(id self, SEL _cmd, id vc) {
    if (XE_BlockSplash()) return;
    xe_orig_gmShowCard(self, _cmd, vc);
}

static void (*xe_orig_jh1)(id, SEL, id);
static void xe_jh1(id self, SEL _cmd, id a) {
    if (XE_BlockSplash()) { XELog(@"block JH splash"); return; }
    xe_orig_jh1(self, _cmd, a);
}

static void (*xe_orig_jh2)(id, SEL, id, id);
static void xe_jh2(id self, SEL _cmd, id a, id b) {
    if (XE_BlockSplash()) return;
    xe_orig_jh2(self, _cmd, a, b);
}

static void (*xe_orig_jh3)(id, SEL, id, id, id);
static void xe_jh3(id self, SEL _cmd, id a, id b, id c) {
    if (XE_BlockSplash()) return;
    xe_orig_jh3(self, _cmd, a, b, c);
}

static void (*xe_orig_jh4)(id, SEL, id, id, id, id);
static void xe_jh4(id self, SEL _cmd, id a, id b, id c, id d) {
    if (XE_BlockSplash()) return;
    xe_orig_jh4(self, _cmd, a, b, c, d);
}

static void (*xe_orig_ubixLoad)(id, SEL);
static void xe_ubixLoad(id self, SEL _cmd) {
    if (XE_BlockSplash()) { XELog(@"block UBiX splash load"); return; }
    xe_orig_ubixLoad(self, _cmd);
}

static void (*xe_orig_ubixShow)(id, SEL, id, id);
static void xe_ubixShow(id self, SEL _cmd, id window, id bottom) {
    if (XE_BlockSplash()) return;
    xe_orig_ubixShow(self, _cmd, window, bottom);
}

static void (*xe_orig_emShowSplash)(id, SEL, id, id, id, id, id);
static void xe_emShowSplash(id self, SEL _cmd, id window, id bottom, id skip, id logo, id loading) {
    if (XE_BlockSplash()) { XELog(@"block EM splash"); return; }
    xe_orig_emShowSplash(self, _cmd, window, bottom, skip, logo, loading);
}

#pragma mark - 信息流广告卡片
// 不改 cell 高度（改 frame 易触发 collectionView 布局异常），只让广告内容不挂载。

static void (*xe_orig_mountAdView)(id, SEL, id);
static void xe_mountAdView(id self, SEL _cmd, id adView) {
    if (XE_HideAdCell() || XE_BlockFeedAd()) {
        XELog(@"block mount ad view in feed cell");
        return;
    }
    xe_orig_mountAdView(self, _cmd, adView);
}

#pragma mark - App 内设置面板
//
// 注入环境里没有 PreferenceLoader（deb 的 layout 不会被安装），系统「设置」
// 里不会有入口。所以入口改放到迅雷自己的「设置」页：在这个列表末尾追加一行
// 「迅雷增强」，点进去是插件自己的开关面板。不需要任何隐藏手势。

static NSInteger gXEHookOK = 0;
static NSInteger gXEHookTotal = 0;

static char kXESwitchKey;   // 关联对象 key

// 下面这几个由「入口」段实现，面板里要用，先声明
static NSString *XEDiagValue(NSString *kind);
static NSString *XEDiagReport(void);
static BOOL XEFloatVisible(void);
static void XEInstallFloatingEntry(void);
static void XEInstallSettingsEntry(void);
static void XERefreshMineClean(void);
static void XECrashGuardReset(void);

@interface XESettingsController : UITableViewController
- (void)xe_toast:(NSString *)text;
@end

static NSArray *XEPanelSpec(void) {
    static NSArray *spec = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        spec = @[
            @{ @"title": @"通用",
               @"footer": @"关掉总开关等于停用整个插件，各开关的设置会保留。",
               @"items": @[ @{ @"key": @"enabled", @"title": @"启用迅雷增强" } ] },

            @{ @"title": @"广告拦截",
               @"footer": @"开屏、信息流、预加载、卡片挂载四个入口一起拦截。",
               @"items": @[
                   @{ @"key": @"blockSplash", @"title": @"去除开屏广告" },
                   @{ @"key": @"instantSplash", @"title": @"开屏秒进（不等待）" },
                   @{ @"key": @"blockFeedAd", @"title": @"去除信息流广告" },
                   @{ @"key": @"blockAdLoad", @"title": @"拦截广告预加载" },
                   @{ @"key": @"hideAdCell", @"title": @"隐藏广告卡片" },
               ] },

            @{ @"title": @"「我的」页 · 推广板块",
               @"footer": @"命中后整块从布局里塌掉，不留空白。改完重进「我的」页生效。",
               @"items": @[
                   @{ @"key": @"hideMineVip", @"title": @"隐藏会员 / 充值推广" },
                   @{ @"key": @"hideMineGame", @"title": @"隐藏游戏中心" },
                   @{ @"key": @"hideMineActivity", @"title": @"隐藏活动 / 运营卡" },
                   @{ @"key": @"hideMineFeed", @"title": @"隐藏推荐位 / banner" },
               ] },

            @{ @"title": @"「我的」页 · 功能板块",
               @"footer": @"这些是功能入口，默认保留。想更干净可以关，代价是少一个入口。",
               @"items": @[
                   @{ @"key": @"hideMineCloud", @"title": @"隐藏云盘空间卡" },
                   @{ @"key": @"hideMineGrid", @"title": @"隐藏常用功能九宫格" },
                   @{ @"key": @"hideMineUser", @"title": @"隐藏用户信息 / 资产区" },
               ] },

            @{ @"title": @"「我的」页 · 极简模式",
               @"footer": @"兜底开关：内置类名没覆盖到的板块也一并清掉，只保留云盘、九宫格、用户信息、设置这些功能入口。嫌「我的」页太乱就开它。",
               @"items": @[ @{ @"key": @"hideMineAll", @"title": @"隐藏所有非功能板块" } ] },

            @{ @"title": @"「我的」页 · 自定义",
               @"footer": @"内置清单漏掉的板块，在这里填类名片段（逗号分隔）就能一起隐藏。诊断里的「我的页板块」可以看到每个板块的类名。",
               @"items": @[
                   @{ @"key": @"hideMineCustomOn", @"title": @"启用自定义隐藏" },
                   @{ @"action": @"customkeys", @"title": @"编辑自定义类名" },
               ] },

            @{ @"title": @"深度屏蔽（激进）",
               @"footer": @"直接清空广告位配置，最彻底；个别页面可能因为没有广告内容而留白。默认关闭。",
               @"items": @[ @{ @"key": @"blockAllSlots", @"title": @"屏蔽全部广告位" } ] },

            @{ @"title": @"体验优化",
               @"footer": @"关闭个性化推荐、关掉摇一摇/扭一扭跳转，并限制广告自动唤起。",
               @"items": @[
                   @{ @"key": @"disablePersonalize", @"title": @"关闭个性化广告推荐" },
                   @{ @"key": @"disableShake", @"title": @"关闭摇一摇 / 扭一扭" },
                   @{ @"key": @"limitAutoJump", @"title": @"限制广告自动跳转" },
               ] },

            @{ @"title": @"入口",
               @"footer": @"悬浮齿轮挂在 App 窗口上，不依赖任何页面结构，版本更新也不会失效；关掉后仍可从 我的 → 设置 → 列表最后一行进入。",
               @"items": @[
                   @{ @"key": @"floatingEntry", @"title": @"显示悬浮入口" },
                   @{ @"key": @"showBeacon", @"title": @"升级后提示已生效" },
               ] },

            @{ @"title": @"调试",
               @"footer": @"把 [XunleiEnhance] 日志打到控制台（Console / idevicesyslog）。",
               @"items": @[ @{ @"key": @"debugLog", @"title": @"输出调试日志" } ] },

            @{ @"title": @"诊断",
               @"footer": @"入口不出现时，把这段信息发出来就能定位是哪一环断了。",
               @"items": @[
                   @{ @"info": @"version", @"title": @"版本" },
                   @{ @"info": @"hooks", @"title": @"Hook 安装" },
                   @{ @"info": @"float", @"title": @"悬浮入口" },
                   @{ @"info": @"classes", @"title": @"设置页入口" },
                   @{ @"info": @"hits", @"title": @"设置页注入次数" },
                   @{ @"info": @"mine", @"title": @"我的页拦截" },
                   @{ @"info": @"minepage", @"title": @"我的页识别" },
                   @{ @"info": @"minetree", @"title": @"我的页结构" },
                   @{ @"info": @"mineblocks", @"title": @"我的页板块" },
                   @{ @"info": @"fuse", @"title": @"净化保护" },
                   @{ @"action": @"copydiag", @"title": @"复制诊断信息" },
                   @{ @"action": @"resetfuse", @"title": @"重置保护状态" },
               ] },

            @{ @"title": @"",
               @"footer": @"",
               @"items": @[ @{ @"action": @"reset", @"title": @"恢复默认设置" } ] },
        ];
    });
    return spec;
}

@implementation XESettingsController

- (instancetype)init {
    if (@available(iOS 13.0, *)) {
        return [super initWithStyle:UITableViewStyleInsetGrouped];
    }
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"迅雷增强";
    if (self.navigationController.presentingViewController &&
        self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                          target:self
                                                          action:@selector(xe_close)];
    }
}

- (void)xe_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray *)xe_spec { return XEPanelSpec(); }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSArray *spec = [self xe_spec];
    return (NSInteger)spec.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *spec = [self xe_spec];
    return (NSInteger)[spec[section][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray *spec = [self xe_spec];
    NSString *t = spec[section][@"title"];
    return t.length ? t : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSArray *spec = [self xe_spec];
    if (section == (NSInteger)spec.count - 1) {
        return [NSString stringWithFormat:@"迅雷增强 v%@ · hook %ld/%ld\n改动即时生效，无需重启",
                XE_VERSION, (long)gXEHookOK, (long)gXEHookTotal];
    }
    NSString *f = spec[section][@"footer"];
    return f.length ? f : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *spec = [self xe_spec];
    NSDictionary *item = spec[indexPath.section][@"items"][indexPath.row];

    if (item[@"info"]) {
        static NSString *rid = @"XEInfoCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                         reuseIdentifier:rid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:14];
            cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13
                                                                        weight:UIFontWeightRegular];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
        cell.textLabel.text = item[@"title"];
        cell.detailTextLabel.text = XEDiagValue(item[@"info"]);
        return cell;
    }

    if (item[@"action"]) {
        static NSString *rid = @"XEActionCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:rid];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
        }
        cell.textLabel.text = item[@"title"];
        cell.textLabel.textColor = [item[@"action"] isEqualToString:@"reset"]
            ? [UIColor systemRedColor] : [UIColor linkColor];
        return cell;
    }

    static NSString *rid = @"XESwitchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:rid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self
               action:@selector(xe_switchChanged:)
     forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    NSString *key = item[@"key"];
    cell.textLabel.text = item[@"title"];
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    objc_setAssociatedObject(sw, &kXESwitchKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // 总开关关闭时，其余开关降级显示但保持可改
    sw.on = [gXEPrefs[key] boolValue];
    sw.enabled = [key isEqualToString:@"enabled"] || XEEnabled();
    return cell;
}

- (void)xe_switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, &kXESwitchKey);
    if (key) XESavePref(key, @(sw.isOn));
    if ([key isEqualToString:@"floatingEntry"]) {
        XEInstallFloatingEntry();
    }
    if ([key isEqualToString:@"showBeacon"]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"xeBeaconVersion"];
    }
    if ([key hasPrefix:@"hideMine"]) {
        XERefreshMineClean();
    }
    if ([key isEqualToString:@"enabled"]) {
        [self.tableView reloadData];
        XERefreshMineClean();
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *spec = [self xe_spec];
    NSDictionary *item = spec[indexPath.section][@"items"][indexPath.row];
    NSString *action = item[@"action"];
    if (!action) return;

    if ([action isEqualToString:@"copydiag"]) {
        [[UIPasteboard generalPasteboard] setString:XEDiagReport()];
        [self xe_toast:@"诊断信息已复制"];
        return;
    }

    if ([action isEqualToString:@"resetfuse"]) {
        XECrashGuardReset();
        XERefreshMineClean();
        [tableView reloadData];
        [self xe_toast:@"已重置，重进「我的」页试试"];
        return;
    }

    if ([action isEqualToString:@"customkeys"]) {
        NSString *cur = gXEPrefs[@"hideMineCustom"] ?: @"";
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"自定义隐藏类名"
                                                message:@"填类名片段，逗号分隔。诊断里的「我的页板块」能看到每个板块的类名。"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.placeholder = @"UserInfoSlider, CardBaseView";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
        __weak typeof(self) ws = self;
        __weak UIAlertController *wac = ac;
        [ac addAction:[UIAlertAction actionWithTitle:@"保存"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            NSString *t = wac.textFields.firstObject.text ?: @"";
            t = [t stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            XESavePref(@"hideMineCustom", t);
            if (t.length > 0) XESavePref(@"hideMineCustomOn", @YES);
            XERefreshMineClean();
            [ws.tableView reloadData];
            [ws xe_toast:t.length ? @"已保存，重进「我的」页查看" : @"已清空"];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    XEResetPrefs();
    [tableView reloadData];
    XEInstallFloatingEntry();
    XERefreshMineClean();
    [self xe_toast:@"已恢复默认设置"];
}

- (void)xe_toast:(NSString *)text {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:text
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end

static void XEShowSettingsFrom(UIViewController *from) {
    if (!from) return;
    XESettingsController *vc = [[XESettingsController alloc] init];
    UINavigationController *nav = from.navigationController;
    if (nav && nav.view.window && !nav.isBeingDismissed) {
        [nav pushViewController:vc animated:YES];
        return;
    }
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:vc];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    [from presentViewController:wrapper animated:YES completion:nil];
}

#pragma mark - 启动熔断
// 净化只改属性（hidden / 约束 / frame），不动视图树，正常情况下不会把 App 弄崩。
// 但万一某版迅雷结构特殊导致启动阶段闪退，用户会卡在「一进就崩、又没机会关开关」
// 的死循环里，所以留一道保险：上次启动没活过 6 秒 → 这次先把净化停掉。
//
// v2.2.1 的写法有死循环：只要 20 秒内退出（用户装完立刻测完就退，很常见）
// 就打不上存活标记，下次启动继续判「崩过」，于是永远熔断、永远不隐藏
// —— 这正是「板块并没隐藏」的直接原因。
// v2.3 修法：熔断最多触发一次（xeFuseCount 计数），第二次启动一定恢复；
// 阈值也降到 6 秒，并且净化真正执行成功过就不再触发。

static BOOL gXEMineDisabledByCrash = NO;   // 上次启动阶段崩过 → 本次自动停用净化

static void XECrashGuardBegin(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL lastAlive = [ud boolForKey:@"xeLaunchAlive"];
    NSTimeInterval lastAt = [ud doubleForKey:@"xeLaunchAt"];
    NSInteger fuseCount = [ud integerForKey:@"xeFuseCount"];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (lastAlive) {
        [ud setInteger:0 forKey:@"xeFuseCount"];   // 上次活得好好的，计数归零
    } else if (lastAt > 0 && fuseCount == 0) {
        gXEMineDisabledByCrash = YES;
        [ud setInteger:1 forKey:@"xeFuseCount"];
        XELog(@"last launch died early -> mine clean off for this run only");
    } else if (lastAt > 0) {
        XELog(@"fuse already used once -> mine clean stays on");
    }

    [ud setBool:NO forKey:@"xeLaunchAlive"];
    [ud setDouble:now forKey:@"xeLaunchAt"];
    [ud synchronize];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setBool:YES forKey:@"xeLaunchAlive"];
        [d synchronize];
    });
}

// 面板里「重置保护状态」用：清掉熔断痕迹，下次启动恢复正常
static void XECrashGuardReset(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:0 forKey:@"xeFuseCount"];
    [ud setBool:YES forKey:@"xeLaunchAlive"];
    [ud synchronize];
    gXEMineDisabledByCrash = NO;
}

#pragma mark - 「我的」页净化
// 25.2.90 的「我的」页结构：
//   UITabBarController
//     └─ AccountContainerViewController      ← tab 上挂的容器，类名里没有 Mine
//          └─ PersonalCenterViewController    ← 真正的页面（Swift，运行时才注册）
//               ├─ 竖向堆叠的卡片（CardBaseView / ActivityCardView / VipInfoItemView …）
//               └─ 若干 UICollectionView（BannerServiceCollectionCell 等）
//
// 前几版一直没生效，除了作用域判定写错，还有一个致命问题：
//   启动熔断把净化整体停掉了 —— v2.2.0 崩溃过，所以 xeLaunchAlive 是 NO，
//   v2.2.1 一启动就判「上次崩过」→ 净化全关。用户 20 秒内退出又打不上存活标记，
//   于是永远熔断、永远不隐藏。v2.3 把熔断改成最多触发一次，且净化跑成功过就不再触发。
//
// 本版三个原则：
//   1. 类名命中就动手，不再叠一层「当前是不是我的页」的判定（v2.1 就是这层判定判死的）；
//   2. 只改属性（hidden / 约束 / frame），绝不改视图树（v2.2.0 摘视图 → Swift 断言崩溃）；
//   3. 每个板块一个独立开关，用户自己决定留哪个。

static long gXEMineHidden = 0;
static BOOL gXEMineActive = NO;         // 当前顶层页面像不像「我的」（仅诊断用）
static NSString *gXEMineDump = nil;     // 视图树快照
static NSString *gXEMinePageClass = nil;// 最近一次识别到的「我的」页类名
static NSString *gXEMineBlocks = nil;   // 最近一次抓到的板块清单（面板里要能看）
static BOOL gXEMineCollapseActive = NO; // 有板块被塌陷过 → 才需要 layoutSubviews 兜底
static BOOL gXEMineInMinePage = NO;     // 当前这轮扫描是否在「我的」页上（只约束极简模式）

typedef NS_ENUM(NSInteger, XECleanKind) {
    XECleanNone = 0,
    XECleanVip,        // 会员 / 充值推广
    XECleanGame,       // 游戏中心
    XECleanActivity,   // 活动 / 运营卡
    XECleanFeed,       // 推荐位 / banner
    XECleanCloud,      // 云盘空间卡（功能，默认关）
    XECleanGrid,       // 常用功能九宫格（功能，默认关）
    XECleanUser,       // 用户信息 / 资产区（功能，默认关）
};

// addSubview 是全 App 最高频的调用之一：这里不能碰 OC 对象，
// 直接拿 class_getName 的 const char * 做 strstr，结论按 Class 指针缓存。
static const char *kXEVipKeys[] = {
    "VipInfoItemView", "VipInfoPopView", "KuaiNiaoVipTryEntranceBar",
    "SuperVipEntry", "VipPrivilegeCardCollectionViewCell", "PersonalCenterSuperVip",
};
static const char *kXEGameKeys[] = {
    "GameEntryView", "GameCenterHeadView", "GameCenterEntry", "GameCenterCell",
    "GameRecommend",
};
static const char *kXEActivityKeys[] = {
    "ActivityCardView", "OperationCard", "PersonalCenterActivity", "ActivityCenter",
    "WelfareCard", "SignInCard", "TaskCard", "CouponCard",
};
static const char *kXEFeedKeys[] = {
    "RecommendItemView", "BannerServiceCollectionCell", "BannerServices",
    "PersonalCenterRecommend", "MineRecommend",
};
static const char *kXECloudKeys[] = {
    "CloudSpaceCardView", "AssetsCard", "MyAssetsCard",
};
static const char *kXEGridKeys[] = {
    "EntranceItemView", "EntranceTitleBar",
};
static const char *kXEUserKeys[] = {
    "UserInfoSlider",
};

static BOOL XENameContains(const char *name, const char **keys, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (strstr(name, keys[i])) return YES;
    }
    return NO;
}

typedef struct {
    Class cls;
    XECleanKind kind;
} XECleanCacheEntry;

static XECleanCacheEntry gXECleanCache[192];
static int gXECleanCacheCount = 0;

// 自定义关键词：偏好里是逗号分隔的类名片段，编译成 \0 分隔的多段 C 串，
// 用 strstr 逐段比。只在偏好变化时重建，热路径上是一次字符串比较。
static char gXECustomBuf[512];
static NSString *gXECustomRaw = nil;

static void XERefreshCustomKeys(void) {
    NSString *raw = XEBool(@"hideMineCustomOn", NO) ? (gXEPrefs[@"hideMineCustom"] ?: @"") : @"";
    if (![raw isKindOfClass:[NSString class]]) raw = @"";
    if (gXECustomRaw && [raw isEqualToString:gXECustomRaw]) return;

    gXECustomRaw = [raw copy];
    gXECustomBuf[0] = '\0';
    if (raw.length == 0) return;

    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@",，;； \t"]];
    size_t used = 0;
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length < 3) continue;
        const char *u = [t UTF8String];
        size_t n = strlen(u);
        if (used + n + 1 >= sizeof(gXECustomBuf)) break;
        memcpy(gXECustomBuf + used, u, n);
        used += n;
        gXECustomBuf[used++] = '\0';
    }
    if (used < sizeof(gXECustomBuf)) gXECustomBuf[used] = '\0';
}

static BOOL XECustomHit(const char *name) {
    if (!name || !name[0]) return NO;
    XERefreshCustomKeys();
    if (!gXECustomBuf[0]) return NO;
    const char *p = gXECustomBuf;
    while (*p && p < gXECustomBuf + sizeof(gXECustomBuf)) {
        if (strstr(name, p)) return YES;
        p += strlen(p) + 1;
    }
    return NO;
}

static XECleanKind XECleanKindForClass(Class cls) {
    if (!cls) return XECleanNone;
    for (int i = 0; i < gXECleanCacheCount; i++) {
        if (gXECleanCache[i].cls == cls) return gXECleanCache[i].kind;
    }

    const char *name = class_getName(cls);
    XECleanKind kind = XECleanNone;
    // 自己的类一律不碰（XE 前缀）
    if (name && name[0] && !(name[0] == 'X' && name[1] == 'E')) {
        if (XENameContains(name, kXEVipKeys, sizeof(kXEVipKeys) / sizeof(char *))) {
            kind = XECleanVip;
        } else if (XENameContains(name, kXEGameKeys, sizeof(kXEGameKeys) / sizeof(char *))) {
            kind = XECleanGame;
        } else if (XENameContains(name, kXEActivityKeys, sizeof(kXEActivityKeys) / sizeof(char *))) {
            kind = XECleanActivity;
        } else if (XENameContains(name, kXEFeedKeys, sizeof(kXEFeedKeys) / sizeof(char *))) {
            kind = XECleanFeed;
        } else if (XENameContains(name, kXECloudKeys, sizeof(kXECloudKeys) / sizeof(char *))) {
            kind = XECleanCloud;
        } else if (XENameContains(name, kXEGridKeys, sizeof(kXEGridKeys) / sizeof(char *))) {
            kind = XECleanGrid;
        } else if (XENameContains(name, kXEUserKeys, sizeof(kXEUserKeys) / sizeof(char *))) {
            kind = XECleanUser;
        }
    }

    if (gXECleanCacheCount < 192) {
        gXECleanCache[gXECleanCacheCount].cls = cls;
        gXECleanCache[gXECleanCacheCount].kind = kind;
        gXECleanCacheCount++;
    }
    return kind;
}

static BOOL XECleanKindEnabled(XECleanKind kind) {
    switch (kind) {
        case XECleanVip:      return XE_HideMineVip();
        case XECleanGame:     return XE_HideMineGame();
        case XECleanActivity: return XE_HideMineActivity();
        case XECleanFeed:     return XE_HideMineFeed();
        case XECleanCloud:    return XE_HideMineCloud();
        case XECleanGrid:     return XE_HideMineGrid();
        case XECleanUser:     return XE_HideMineUser();
        case XECleanNone:     break;
    }
    return NO;
}

// 所有开关全关时直接短路，addSubview 上几乎没有额外开销
static BOOL XEMineCleanWanted(void) {
    if (gXEMineDisabledByCrash) return NO;
    return XE_HideMineVip() || XE_HideMineGame() || XE_HideMineActivity() ||
           XE_HideMineFeed() || XE_HideMineCloud() || XE_HideMineGrid() ||
           XE_HideMineUser() || XE_HideMineCustom() || XE_HideMineAll();
}

static BOOL XEIsCellView(UIView *v);

// 极简模式的判定：只要长得像「一块板块」（够宽、高度像卡片）就隐藏，
// 功能入口与滚动容器白名单保留。这是兜底手段：内置类名没覆盖到的板块也能清掉。
static BOOL XELooksLikeMineBlock(UIView *v) {
    if (!v || !v.superview) return NO;
    if ([v isKindOfClass:[UIScrollView class]]) return NO;      // 含 table/collection
    if ([v isKindOfClass:[UINavigationBar class]]) return NO;
    if ([v isKindOfClass:[UITabBar class]]) return NO;
    if ([v isKindOfClass:[UIWindow class]]) return NO;
    if (XEIsCellView(v)) return NO;                             // cell 走单独逻辑

    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    if (w < 250 || h < 60 || h > 560) return NO;

    const char *name = class_getName(object_getClass(v));
    if (!name) return NO;
    static const char *keep[] = {
        "CloudSpace", "Entrance", "UserInfo", "AssetsCard", "Setting",
        "Navigation", "TabBar", "TextField", "Keyboard",
    };
    if (XENameContains(name, keep, sizeof(keep) / sizeof(char *))) return NO;
    return YES;
}

static BOOL XEIsCellView(UIView *v) {
    static Class ccCell = Nil, tvCell = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ccCell = NSClassFromString(@"UICollectionViewCell");
        tvCell = NSClassFromString(@"UITableViewCell");
    });
    if (ccCell && [v isKindOfClass:ccCell]) return YES;
    if (tvCell && [v isKindOfClass:tvCell]) return YES;
    return NO;
}

// 命中一个板块视图后，往上找「这一块」的容器：
// BannerServiceCollectionCell 只是 banner 卡里的一条，隐藏一条会留空，
// 隐藏它所在的那张卡才是想要的效果。到页面级容器就停手。
static UIView *XEContainerOf(UIView *v) {
    UIView *p = v.superview;
    for (int i = 0; i < 3 && p; i++) {
        if (p.bounds.size.height > 500) break;          // 页面级容器，不要整页干掉
        if ([p isKindOfClass:[UICollectionView class]] ||
            [p isKindOfClass:[UITableView class]] ||
            [p isKindOfClass:[UIScrollView class]] ||
            XEIsCellView(p)) {
            p = p.superview;
            continue;
        }
        return p;
    }
    return v;
}

static char kXECollapsedKey;
static char kXECollapsedZeroKey;

// 把一块板从布局里「塌掉」，但不改视图树。
// 顺序很重要：先压约束（Auto Layout 说了算），再压 frame（frame 布局说了算）。
static void XECollapse(UIView *v) {
    if (!v) return;

    // stack 自己会把 hidden 的 arrangedSubview 塌成 0，压约束反而和它打架
    if ([v.superview isKindOfClass:[UIStackView class]]) {
        [(UIStackView *)v.superview setNeedsLayout];
        return;
    }

    // 1) 自身高度约束压 0（卡片普遍用固定高度约束）
    for (NSLayoutConstraint *c in v.constraints) {
        if (c.firstItem != v && c.secondItem != v) continue;
        if (c.firstAttribute != NSLayoutAttributeHeight) continue;
        if (c.relation != NSLayoutRelationEqual) continue;
        c.constant = 0;
    }

    // 2) 补一条 0 高度兜底约束，优先级略低于必需，避免和 App 的约束冲突报错
    if (!v.translatesAutoresizingMaskIntoConstraints) {
        if (!objc_getAssociatedObject(v, &kXECollapsedZeroKey)) {
            objc_setAssociatedObject(v, &kXECollapsedZeroKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSLayoutConstraint *zero =
                [NSLayoutConstraint constraintWithItem:v
                                            attribute:NSLayoutAttributeHeight
                                            relatedBy:NSLayoutRelationEqual
                                               toItem:nil
                                            attribute:NSLayoutAttributeNotAnAttribute
                                           multiplier:1
                                             constant:0];
            zero.priority = 990;
            [v addConstraint:zero];
        }
    } else {
        // 3) frame 布局：直接把高度压 0，并打标，后续 layoutSubviews 里持续维持
        //    （App 每次重新布局都会把 frame 写回来，只压一次等于没压）
        CGRect f = v.frame;
        if (f.size.height > 0.5) {
            f.size.height = 0;
            v.frame = f;
        }
    }

    [v.superview setNeedsLayout];
    gXEMineCollapseActive = YES;
}

static void XEHideMineBlock(UIView *v) {
    if (!v) return;

    if (XEIsCellView(v)) {
        UIView *box = XEContainerOf(v);
        if (box && box != v && !box.hidden) {
            v = box;   // cell 只隐藏会留白，整卡拿下
        } else {
            // 找不到整卡就只能隐藏 cell 本身。cell 不打标：它会被复用池拉去
            // 显示别的板块，打标会导致下一次复用时仍然是隐藏状态。
            if (!v.hidden) {
                v.hidden = YES;
                v.alpha = 0;
                v.userInteractionEnabled = NO;
                gXEMineHidden++;
            }
            return;
        }
    }

    NSNumber *old = objc_getAssociatedObject(v, &kXECollapsedKey);
    if (v.hidden && old) return;   // 已经处理过

    v.hidden = YES;
    v.alpha = 0;
    v.userInteractionEnabled = NO;

    if (!old) {
        objc_setAssociatedObject(v, &kXECollapsedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gXEMineHidden++;
        XELog(@"hidden mine block: %@", NSStringFromClass([v class]));
    }

    // cell 不动尺寸：改 frame 会被 layout 覆盖，也会牵连其它位置
    if (!XEIsCellView(v)) XECollapse(v);
}

// 类名命中且开关打开就返回 YES。
// 这里刻意不再检查「当前是不是我的页」：v2.1 就是因为多加了那层判定
// （顶层是 AccountContainerViewController，名字里既没 Mine 也没 PersonalCenter）
// 而把所有隐藏全关掉了。上面这些类名本身就是个人中心独有的，够特异。
static BOOL XEShouldHideView(UIView *v) {
    if (!v) return NO;
    if (!XEMineCleanWanted()) return NO;

    Class cls = object_getClass(v);
    XECleanKind kind = XECleanKindForClass(cls);
    if (kind != XECleanNone && XECleanKindEnabled(kind)) return YES;

    if (XE_HideMineCustom() && XECustomHit(class_getName(cls))) return YES;
    // 极简模式必须限定在「我的」页：它只按尺寸认板块，不限页面会把
    // 首页、下载页的卡片一起清掉。类名判定不需要这层限制（类名本身够特异）。
    if (gXEMineInMinePage && XE_HideMineAll() && XELooksLikeMineBlock(v)) return YES;
    return NO;
}

static void XESweepMineRecursive(UIView *v, int depth, int *budget) {
    if (!v || depth > 14 || *budget <= 0) return;
    (*budget)--;

    if (XEShouldHideView(v)) XEHideMineBlock(v);

    NSArray<UIView *> *subs = [v.subviews copy];
    for (UIView *s in subs) XESweepMineRecursive(s, depth + 1, budget);
}

static void XESweepMineView(UIView *v, int depth) {
    int budget = 1200;
    XESweepMineRecursive(v, depth, &budget);
}

static BOOL XEVCLooksLikeMine(UIViewController *vc, int depth);
static void XECaptureMineDump(UIViewController *top);
static NSString *XEMineBlocksFrom(UIView *root);

static BOOL gXESweepQueued = NO;
static NSTimeInterval gXELastSweep = 0;

// 真正的扫描：只在主队列、且不在 UIKit 的布局调用栈里跑。
// v2.2.0 是直接在 addSubview / layoutSubviews 的栈里改视图，闪退就是这么来的。
static void XERunSweep(void) {
    gXESweepQueued = NO;
    if (!XEMineCleanWanted()) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gXELastSweep < 0.20) return;   // 限频，别跟着布局循环狂扫
    gXELastSweep = now;

    UIViewController *top = XETopViewController();
    if (!top || ![top isViewLoaded]) return;
    if ([NSStringFromClass([top class]) hasPrefix:@"XE"]) return;   // 自己的面板

    // 不再要求 top 一定是「我的」页：整棵窗口视图树都扫，
    // 命中的类名本来就只在个人中心出现，页面层级变了也不会漏。
    BOOL isMine = XEVCLooksLikeMine(top, 0);
    gXEMineInMinePage = isMine;
    if (isMine) {
        gXEMineActive = YES;
        gXEMinePageClass = NSStringFromClass([top class]);
    }

    XESweepMineView(top.view, 0);
    if (isMine) {
        XECaptureMineDump(top);
        NSString *blocks = XEMineBlocksFrom(top.view);
        if (blocks) gXEMineBlocks = blocks;
    }
}

// 排队：同一时刻只会有一个待执行的扫描
static void XEScheduleSweep(void) {
    if (gXESweepQueued) return;
    gXESweepQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        XERunSweep();
    });
}

// 面板里改了开关：清判定缓存并立刻重扫一遍当前页面，不用杀进程
static void XERefreshMineClean(void) {
    gXECleanCacheCount = 0;
    gXEMineDump = nil;
    gXEMineBlocks = nil;
    gXELastSweep = 0;
    gXEMineCollapseActive = NO;
    gXECustomRaw = nil;
    XEScheduleSweep();
}

static void (*xe_orig_addSubview)(id, SEL, UIView *);
static void xe_addSubview(id self, SEL _cmd, UIView *v) {
    xe_orig_addSubview(self, _cmd, v);
    if (!XEMineCleanWanted()) return;
    // 只排队，绝不在这一步改视图：addSubview 还在 UIKit 的调用栈里，
    // 这时候隐藏/收缩视图会把 App 自己的布局循环搞乱（v2.2.0 的崩溃点）。
    if (XEShouldHideView(v)) XEScheduleSweep();
}

static void (*xe_orig_insertSubview)(id, SEL, UIView *, NSInteger);
static void xe_insertSubview(id self, SEL _cmd, UIView *v, NSInteger index) {
    xe_orig_insertSubview(self, _cmd, v, index);
    if (!XEMineCleanWanted()) return;
    if (XEShouldHideView(v)) XEScheduleSweep();
}

// collection view 里的 cell 是 layout 摆出来的，addSubview 拦不到，布局完补一遍
static void (*xe_orig_cvLayoutSubviews)(id, SEL);
static void xe_cvLayoutSubviews(id self, SEL _cmd) {
    xe_orig_cvLayoutSubviews(self, _cmd);
    if (!XEMineCleanWanted()) return;
    for (UICollectionViewCell *c in [(UICollectionView *)self visibleCells]) {
        if (XEShouldHideView(c)) { XEScheduleSweep(); break; }
    }
}

// frame 布局的卡片被压成 0 之后，App 下一次 layout 又会把 frame 写回来，
// 所以对自己被标记过的视图，每次布局完再压一次。
static void (*xe_orig_layoutSubviews)(id, SEL);
static void xe_layoutSubviews(id self, SEL _cmd) {
    xe_orig_layoutSubviews(self, _cmd);
    if (!gXEMineCollapseActive) return;
    UIView *v = (UIView *)self;
    if (!objc_getAssociatedObject(v, &kXECollapsedKey)) return;
    if (!v.translatesAutoresizingMaskIntoConstraints) return;
    if (v.frame.size.height < 0.5) return;
    CGRect f = v.frame;
    f.size.height = 0;
    v.frame = f;
}

static void XEInstallMineCleaner(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    XEInstallOn([UIView class], "addSubview:", (IMP)xe_addSubview, (IMP *)&xe_orig_addSubview);
    XEInstallOn([UIView class], "insertSubview:atIndex:", (IMP)xe_insertSubview,
                (IMP *)&xe_orig_insertSubview);
    XEInstallOn([UIView class], "layoutSubviews",
                (IMP)xe_layoutSubviews, (IMP *)&xe_orig_layoutSubviews);
    XEInstallOn([UICollectionView class], "layoutSubviews",
                (IMP)xe_cvLayoutSubviews, (IMP *)&xe_orig_cvLayoutSubviews);
}

#pragma mark 「我的」页识别与诊断

// 顶层是 AccountContainerViewController，真正的个人中心是它的 child，
// 所以两层都要看，且不能「第一个不匹配就放弃」。
static BOOL XEVCLooksLikeMine(UIViewController *vc, int depth) {
    if (!vc || depth > 3) return NO;

    const char *name = class_getName([vc class]);
    if (name && (strstr(name, "PersonalCenter") || strstr(name, "AccountContainer") ||
                 strstr(name, "Mine"))) {
        return YES;
    }
    if ([vc.title isEqualToString:@"我的"] || [vc.title isEqualToString:@"個人中心"] ||
        [vc.title isEqualToString:@"个人中心"]) {
        return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (XEVCLooksLikeMine(child, depth + 1)) return YES;
    }
    return NO;
}

static void XEDumpTree(UIView *v, int depth, NSMutableString *out, int *count) {
    if (!v || depth > 11 || *count >= 90) return;
    NSString *name = NSStringFromClass([v class]);
    if (name.length > 76) name = [name substringFromIndex:name.length - 76];
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"· "];
    [out appendFormat:@"%@%@ %.0fx%.0f%@\n", pad, name,
                      v.bounds.size.width, v.bounds.size.height,
                      v.hidden ? @" (hidden)" : @""];
    (*count)++;
    for (UIView *s in v.subviews) XEDumpTree(s, depth + 1, out, count);
}

// 只挑「板块级」的视图：够宽、有一定高度。这是排查没命中的关键数据 ——
// 用户把这段发过来，漏掉的板块类名一眼就能看到。
static void XECollectBlocks(UIView *v, int depth, NSMutableArray<NSString *> *out) {
    if (!v || depth > 14 || out.count >= 40) return;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    if (w > 200 && h >= 44 && h < 620) {
        NSString *name = NSStringFromClass([v class]);
        if (name.length > 64) name = [name substringFromIndex:name.length - 64];
        [out addObject:[NSString stringWithFormat:@"%.0fx%.0f %@%@", w, h, name,
                        v.hidden ? @" (已隐藏)" : @""]];
    }
    for (UIView *s in v.subviews) XECollectBlocks(s, depth + 1, out);
}

static void XECaptureMineDump(UIViewController *top) {
    if (!top || !top.isViewLoaded) return;
    if (gXEMineDump.length > 160) return;   // 太少说明页面还没铺完，下次重抓

    NSMutableString *out = [NSMutableString string];
    int count = 0;
    XEDumpTree(top.view, 0, out, &count);
    gXEMineDump = out.length ? out : @"(空)";
    XELog(@"mine tree captured: %d nodes", count);
}

// 诊断用：「我的」页上的板块清单（类名 + 尺寸）
static NSString *XEMineBlocksFrom(UIView *root) {
    if (!root) return nil;
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    XECollectBlocks(root, 0, list);
    if (list.count == 0) return nil;
    return [list componentsJoinedByString:@"\n"];
}

// 面板里只能读缓存：用户打开面板时顶层已经不是「我的」页，
// 现场抓只会抓到面板自己，没有意义。
static NSString *XEMineBlocksSummary(void) {
    if (gXEMineBlocks.length) return gXEMineBlocks;
    return @"还没进过「我的」页（进去一次再回面板看）";
}

#pragma mark - 入口一：设置页最后一行（视图注入，不碰数据源）
// v2.0 是往设置列表的「最后一段」追加一行，必须命中 UITableView 的 dataSource
// 才能收到回调；迅雷设置页是 Swift 写的，这条路一旦不成立入口就彻底消失
// （悬浮齿轮还在，说明注入本身没问题）。
//
// v2.1 改成视图级注入：找到设置页的 tableView，直接把 tableFooterView 换成
// 自己的一条 —— 位置天然就是列表最后一行，不依赖 dataSource、不依赖段数，
// App 换实现也不会失效。页面里没有 tableView 就退化成贴底的一条。

#define XE_ENTRY_TITLE @"迅雷增强"
#define XE_ENTRY_SUBTITLE @"去广告 · 开屏秒进 · 我的页净化"
#define XE_ENTRY_HEIGHT 68.0

static long gXESettingsHits = 0;      // 成功注入设置页的次数
static NSString *gXEEntryPage = nil;  // 最近一次注入的 VC 类名（诊断用）
static char kXEEntryAttachedKey;

@interface XEEntryBar : UIControl
@property (nonatomic, weak) UIViewController *host;
- (void)xe_open;
@end

@implementation XEEntryBar {
    UIView *_card;
    UILabel *_title;
    UILabel *_sub;
    UIImageView *_arrow;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];

    _card = [[UIView alloc] init];
    _card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _card.layer.cornerRadius = 10;
    _card.layer.masksToBounds = YES;
    _card.userInteractionEnabled = NO;
    [self addSubview:_card];

    _title = [[UILabel alloc] init];
    _title.text = XE_ENTRY_TITLE;
    _title.font = [UIFont systemFontOfSize:17];
    _title.textColor = [UIColor labelColor];

    _sub = [[UILabel alloc] init];
    _sub.text = XE_ENTRY_SUBTITLE;
    _sub.font = [UIFont systemFontOfSize:12];
    _sub.textColor = [UIColor secondaryLabelColor];

    _arrow = [[UIImageView alloc] init];
    _arrow.image = [UIImage systemImageNamed:@"chevron.right"];
    _arrow.tintColor = [UIColor tertiaryLabelColor];
    _arrow.contentMode = UIViewContentModeScaleAspectFit;

    [_card addSubview:_title];
    [_card addSubview:_sub];
    [_card addSubview:_arrow];

    [self addTarget:self action:@selector(xe_open)
   forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _card.frame = CGRectMake(16, 6, MAX(w - 32, 100), h - 12);
    CGFloat cw = _card.bounds.size.width, ch = _card.bounds.size.height;
    _title.frame = CGRectMake(14, ch / 2 - 20, cw - 52, 21);
    _sub.frame = CGRectMake(14, ch / 2 + 2, cw - 52, 15);
    _arrow.frame = CGRectMake(cw - 26, ch / 2 - 7, 12, 14);
}

- (void)xe_open {
    XELog(@"open enhance panel from settings footer");
    XEShowSettingsFrom(self.host);
}

@end

static UITableView *XEFindTableView(UIView *root, int depth) {
    if (!root || depth > 8) return nil;
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *sub in root.subviews) {
        UITableView *tv = XEFindTableView(sub, depth + 1);
        if (tv) return tv;
    }
    return nil;
}

static void XEAttachEntryTo(UIViewController *vc) {
    if (!vc || ![vc isViewLoaded]) return;
    NSString *cls = NSStringFromClass([vc class]);
    if ([cls hasPrefix:@"XE"]) return;                          // 自己的面板
    if (objc_getAssociatedObject(vc, &kXEEntryAttachedKey)) return;

    CGFloat width = vc.view.bounds.size.width;
    if (width < 100) width = [UIScreen mainScreen].bounds.size.width;

    XEEntryBar *bar = [[XEEntryBar alloc] initWithFrame:CGRectMake(0, 0, width, XE_ENTRY_HEIGHT)];
    bar.host = vc;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UITableView *tv = XEFindTableView(vc.view, 0);
    if (tv) {
        UIView *old = tv.tableFooterView;
        if (old && old.bounds.size.height > 1) {
            CGFloat oh = old.bounds.size.height;
            UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, XE_ENTRY_HEIGHT + oh)];
            wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            old.frame = CGRectMake(0, XE_ENTRY_HEIGHT, width, oh);
            old.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [wrap addSubview:bar];
            [wrap addSubview:old];
            tv.tableFooterView = wrap;
        } else {
            tv.tableFooterView = bar;
        }
        [tv setNeedsLayout];
    } else {
        // 不是 tableView（RN / 自定义滚动视图）：贴底一条，照样点得到
        bar.frame = CGRectMake(0, vc.view.bounds.size.height - XE_ENTRY_HEIGHT,
                               width, XE_ENTRY_HEIGHT);
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [vc.view addSubview:bar];
    }

    // 导航栏再挂一个，双保险：设置页右上角「增强」
    if (vc.navigationController && !vc.navigationItem.rightBarButtonItem) {
        vc.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"增强"
                                             style:UIBarButtonItemStylePlain
                                            target:bar
                                            action:@selector(xe_open)];
    }

    objc_setAssociatedObject(vc, &kXEEntryAttachedKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gXESettingsHits++;
    gXEEntryPage = cls;
    XELog(@"settings entry injected into %@ (tableView=%@)", cls, tv ? @"Y" : @"N");
}

#pragma mark 探测

static long gXEMineIdleTicks = 0;

static void XEProbeTick(void) {
    UIViewController *top = XETopViewController();
    if (!top) return;

    NSString *cls = NSStringFromClass([top class]);
    if (!cls || [cls hasPrefix:@"XE"]) return;

    // 设置页：类名命中最稳，标题兜底（换语言 / 换实现也能进）
    BOOL isSettings = [cls rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!isSettings) {
        NSString *t = top.title;
        isSettings = [t isEqualToString:@"设置"] || [t isEqualToString:@"設定"] ||
                     [t isEqualToString:@"Settings"];
    }
    if (isSettings) XEAttachEntryTo(top);

    // 「我的」页：顶层挂的是 AccountContainerViewController，真正的个人中心在 child 里，
    // 所以判定交给 XEVCLooksLikeMine（会往下钻，且不会因为第一个 VC 不匹配就放弃）。
    BOOL isMine = XEVCLooksLikeMine(top, 0);
    gXEMineActive = isMine;
    if (isMine) gXEMinePageClass = cls;

    if (XEMineCleanWanted()) {
        if (isMine) {
            XEScheduleSweep();
        } else if ((++gXEMineIdleTicks % 6) == 0) {
            // 判定没命中时的兜底：约 1.8 秒扫一次，避免因为页面层级变化而漏掉
            XEScheduleSweep();
        }
    }
}

static void XEInstallSettingsEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *timer = [NSTimer timerWithTimeInterval:0.3
                                                    repeats:YES
                                                      block:^(NSTimer *t) { XEProbeTick(); }];
            timer.tolerance = 0.2;
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
            XEProbeTick();
        });
    });
}

#pragma mark - 入口二：悬浮球
// 不依赖 App 任何页面结构：挂在 keyWindow 上，App 跑起来就一定在。

static UIButton *gXEFloatBtn = nil;

// 不用 UIApplication.keyWindow（iOS 13 起废弃，-Werror 会直接编译失败），
// 改为遍历 connectedScenes：优先 isKeyWindow，退而取第一个可见窗口。
static UIWindow *XEKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *fallback = nil;
        for (UIScene *scene in [app connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in [((UIWindowScene *)scene) windows]) {
                if ([w isKeyWindow]) return w;
                if (!fallback && ![w isHidden]) fallback = w;
            }
        }
        return fallback;
    }
    return nil;
}

static UIViewController *XETopViewController(void) {
    UIWindow *win = XEKeyWindow();
    UIViewController *vc = [win rootViewController];
    for (int i = 0; i < 32 && vc; i++) {
        UIViewController *next = vc.presentedViewController;
        if (!next && [vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).topViewController;
        }
        if (!next && [vc isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)vc).selectedViewController;
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

@interface XEFloatEntry : NSObject
+ (instancetype)shared;
- (void)install;
- (BOOL)isVisible;
@end

@implementation XEFloatEntry

+ (instancetype)shared {
    static XEFloatEntry *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[XEFloatEntry alloc] init]; });
    return s;
}

- (BOOL)isVisible {
    return gXEFloatBtn != nil && gXEFloatBtn.superview != nil;
}

- (void)install {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    if (!XEBool(@"floatingEntry", YES)) {
        [gXEFloatBtn removeFromSuperview];
        return;
    }
    UIWindow *win = XEKeyWindow();
    if (!win) return;
    if (gXEFloatBtn && gXEFloatBtn.superview == win) {
        [win bringSubviewToFront:gXEFloatBtn];
        return;
    }

    if (!gXEFloatBtn) {
        CGFloat s = 46;
        gXEFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gXEFloatBtn.bounds = CGRectMake(0, 0, s, s);
        gXEFloatBtn.layer.cornerRadius = s / 2;
        gXEFloatBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        gXEFloatBtn.layer.shadowColor = [[UIColor blackColor] CGColor];
        gXEFloatBtn.layer.shadowOpacity = 0.28;
        gXEFloatBtn.layer.shadowRadius = 4;
        gXEFloatBtn.layer.shadowOffset = CGSizeMake(0, 2);
        if (@available(iOS 13.0, *)) {
            [gXEFloatBtn setImage:[UIImage systemImageNamed:@"gearshape.fill"]
                         forState:UIControlStateNormal];
            gXEFloatBtn.tintColor = [UIColor whiteColor];
        } else {
            [gXEFloatBtn setTitle:@"增强" forState:UIControlStateNormal];
            gXEFloatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
            [gXEFloatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }
        [gXEFloatBtn addTarget:self
                        action:@selector(handleTap)
              forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [gXEFloatBtn addGestureRecognizer:pan];
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGPoint c = CGPointMake(win.bounds.size.width - 46, win.bounds.size.height * 0.60);
    if ([ud objectForKey:@"xeFloatX"] && [ud objectForKey:@"xeFloatY"]) {
        c = CGPointMake([ud doubleForKey:@"xeFloatX"], [ud doubleForKey:@"xeFloatY"]);
    }
    c.x = MIN(MAX(c.x, 30), MAX(win.bounds.size.width - 30, 30));
    c.y = MIN(MAX(c.y, 80), MAX(win.bounds.size.height - 60, 80));
    gXEFloatBtn.center = c;
    [win addSubview:gXEFloatBtn];
    [win bringSubviewToFront:gXEFloatBtn];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!gXEFloatBtn || !gXEFloatBtn.superview) return;
    UIView *host = gXEFloatBtn.superview;
    CGPoint t = [g translationInView:host];
    CGPoint c = CGPointMake(gXEFloatBtn.center.x + t.x, gXEFloatBtn.center.y + t.y);
    c.x = MIN(MAX(c.x, 30), MAX(host.bounds.size.width - 30, 30));
    c.y = MIN(MAX(c.y, 60), MAX(host.bounds.size.height - 60, 60));
    gXEFloatBtn.center = c;
    [g setTranslation:CGPointZero inView:host];
    if (g.state == UIGestureRecognizerStateEnded) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setDouble:c.x forKey:@"xeFloatX"];
        [ud setDouble:c.y forKey:@"xeFloatY"];
        [ud synchronize];
    }
}

- (void)handleTap {
    UIViewController *top = XETopViewController();
    if (!top) return;
    XELog(@"open enhance panel from float button");
    XEShowSettingsFrom(top);
}

@end

static BOOL XEFloatVisible(void) {
    return [[XEFloatEntry shared] isVisible];
}

static void XEInstallFloatingEntry(void) {
    [[XEFloatEntry shared] install];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            [[XEFloatEntry shared] install];
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            [[XEFloatEntry shared] install];
            XEInstallSettingsEntry();   // 类注册得晚时补一次
            XEPrefsChanged(NULL, NULL, NULL, NULL, NULL);
        }];
        if (@available(iOS 13.0, *)) {
            [nc addObserverForName:UISceneDidActivateNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                [[XEFloatEntry shared] install];
            }];
        }
    });
}

#pragma mark - 入口三：启动自证
// 装完第一次启动会弹一次「已注入」，用来证实 dylib 真的被加载了。
// 看不到这个弹窗 == 注入没成功，跟插件逻辑无关。

static int gXEBeaconTries = 0;

static void XEScheduleBeacon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!XEBool(@"showBeacon", YES)) return;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([[ud stringForKey:@"xeBeaconVersion"] isEqualToString:XE_VERSION]) return;

        UIViewController *top = XETopViewController();
        if (!top || top.presentedViewController || top.isBeingDismissed) {
            if (++gXEBeaconTries < 15) XEScheduleBeacon();
            return;
        }

        NSString *msg = [NSString stringWithFormat:
            @"dylib 已加载，hook %ld/%ld。\n\n"
             @"入口有三个，任选其一：\n"
             @"· 屏幕右侧悬浮齿轮\n"
             @"· 我的 → 设置 → 列表最下面一行「迅雷增强」\n"
             @"· 我的 → 设置 → 右上角「增强」",
            (long)gXEHookOK, (long)gXEHookTotal];
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:
                [NSString stringWithFormat:@"迅雷增强 v%@ 已生效", XE_VERSION]
                                             message:msg
                                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"打开增强设置"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
            // 等弹窗真正关掉再开面板，否则 presenter 还是这个 UIAlertController
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XEShowSettingsFrom(XETopViewController());
            });
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];

        [ud setObject:XE_VERSION forKey:@"xeBeaconVersion"];
        [ud synchronize];
    });
}

#pragma mark - 诊断

static NSString *XEDiagValue(NSString *kind) {
    if ([kind isEqualToString:@"version"]) return XE_VERSION;
    if ([kind isEqualToString:@"hooks"]) {
        return [NSString stringWithFormat:@"%ld / %ld", (long)gXEHookOK, (long)gXEHookTotal];
    }
    if ([kind isEqualToString:@"float"]) {
        return XEFloatVisible() ? @"已显示" : @"未显示";
    }
    if ([kind isEqualToString:@"classes"]) {
        return gXEEntryPage ? gXEEntryPage : @"还没进过设置页";
    }
    if ([kind isEqualToString:@"hits"]) {
        return [NSString stringWithFormat:@"%ld 次", gXESettingsHits];
    }
    if ([kind isEqualToString:@"mine"]) {
        if (gXEMineDisabledByCrash) return @"已自动停用";
        return [NSString stringWithFormat:@"%ld 块", gXEMineHidden];
    }
    if ([kind isEqualToString:@"minepage"]) {
        return gXEMinePageClass ?: @"还没进过「我的」页";
    }
    if ([kind isEqualToString:@"minetree"]) {
        if (gXEMineDump.length == 0) return @"还没抓取";
        NSUInteger lines = gXEMineDump.length ? [[gXEMineDump componentsSeparatedByString:@"\n"] count] - 1 : 0;
        return [NSString stringWithFormat:@"%lu 个节点", (unsigned long)lines];
    }
    if ([kind isEqualToString:@"mineblocks"]) {
        NSString *sum = XEMineBlocksSummary();
        if ([sum isEqualToString:@"未进入"] || [sum isEqualToString:@"未抓到"]) return sum;
        NSUInteger n = [[sum componentsSeparatedByString:@"\n"] count];
        return [NSString stringWithFormat:@"%lu 个（复制诊断看类名）", (unsigned long)n];
    }
    if ([kind isEqualToString:@"fuse"]) {
        return gXEMineDisabledByCrash ? @"本次已停用" : @"正常";
    }
    return @"-";
}

static NSString *XEDiagReport(void) {
    NSString *head = [NSString stringWithFormat:
        @"XunleiEnhance v%@\nbundle : %@\nhook : %ld/%ld\n"
         @"设置页 : %@（注入 %ld 次）\n"
         @"我的页 : %@ / 拦截 %ld 块 / 保护 %@\n"
         @"开关 : 会员%@ 游戏%@ 活动%@ 推荐%@ 云盘%@ 九宫格%@ 用户%@ 自定义%@ 极简%@\n"
         @"悬浮球 : %@\nprefs : %@",
        XE_VERSION,
        [[NSBundle mainBundle] bundleIdentifier],
        (long)gXEHookOK, (long)gXEHookTotal,
        gXEEntryPage ?: @"未命中",
        gXESettingsHits,
        gXEMinePageClass ?: @"未进入",
        gXEMineHidden,
        gXEMineDisabledByCrash ? @"已停用" : @"正常",
        XE_HideMineVip() ? @"开" : @"关",
        XE_HideMineGame() ? @"开" : @"关",
        XE_HideMineActivity() ? @"开" : @"关",
        XE_HideMineFeed() ? @"开" : @"关",
        XE_HideMineCloud() ? @"开" : @"关",
        XE_HideMineGrid() ? @"开" : @"关",
        XE_HideMineUser() ? @"开" : @"关",
        XE_HideMineCustom() ? @"开" : @"关",
        XE_HideMineAll() ? @"开" : @"关",
        XEFloatVisible() ? @"在屏" : @"未装",
        gXEPrefs];

    NSMutableString *out = [head mutableCopy];
    [out appendFormat:@"\n\n--- 我的页板块 ---\n%@", XEMineBlocksSummary()];
    if (gXEMineDump.length) {
        [out appendFormat:@"\n\n--- 我的页视图树 ---\n%@", gXEMineDump];
    }
    return out;
}

#pragma mark - 安装

__attribute__((constructor)) static void XEInitialize(void) {
    @autoreleasepool {
        XEReloadPrefs();
        XECrashGuardBegin();

        XEHookEntry hooks[] = {
            // 出价池
            XE_HOOK(XCAdCoreCacheManager,
                    popTopPriceAdFromCacheWithStrategy:slotTag:ext:bindContext:adStyle:throughModel:,
                    xe_popTopPrice, xe_orig_popTopPrice),
            XE_HOOK(XCAdCoreCacheManager, popAllAvailableNativeAdAndNoDestory:slotTag:adStyle:,
                    xe_popAll, xe_orig_popAll),
            XE_HOOK(XCAdCoreCacheManager, shouldPreloadNativeAdCount:adStyle:,
                    xe_preloadCount, xe_orig_preloadCount),
            XE_HOOK(XCAdCoreCacheManager, getCacheCount:adStyle:,
                    xe_cacheCount, xe_orig_cacheCount),
            // 广告位闸门
            XE_HOOK(XCAdConfigManager, filterSlotTags:, xe_filterSlotTags, xe_orig_filterSlotTags),
            XE_HOOK(XCAdConfigManager, startFetchRealtimeConfig, xe_fetchRealtime, xe_orig_fetchRealtime),
            XE_HOOK(XCAdConfigManager, effectiveDisablePersonalRecommend,
                    xe_effDisablePersonalize, xe_orig_effDisablePersonalize),
            XE_HOOK(XCAdConfigManager, disablePersonalRecommend,
                    xe_disablePersonalize, xe_orig_disablePersonalize),
            XE_HOOK(XCAdConfigManager, autoClickJumpLimit,
                    xe_autoClickJumpLimit, xe_orig_autoClickJumpLimit),
            XE_HOOK(XCAdCoreSlotRequestFrequencyControlManager,
                    isAllowRequestAdWithSlot:slotTag:traceId:, xe_allowRequest, xe_orig_allowRequest),
            // 摇一摇
            XE_HOOK(XCAdConfigModel, disableShake, xe_disableShake, xe_orig_disableShake),
            XE_HOOK(XCAdConfigModel, splash_sdk_shake_state, xe_shakeState, xe_orig_shakeState),
            // 开屏（自渲染）
            XE_HOOK(ZYMixSplashViewController, viewWillAppear:,
                    xe_mixSplashWillAppear, xe_orig_mixSplashWillAppear),
            XE_HOOK(ZYCustomizeSplashViewController, viewWillAppear:,
                    xe_customSplashWillAppear, xe_orig_customSplashWillAppear),
            // 开屏秒进：启动链路 + 展示入口
            XE_HOOK(XCSplashService,
                    applicationDidFinishLaunchingWithSplashSlotTag:ext:,
                    xe_splashLaunch, xe_orig_splashLaunch),
            XE_HOOK(XCSplashView, showSplashAd:strategy:, xe_splashShow, xe_orig_splashShow),
            XE_HOOK(XCSplashContainerViewController, viewWillAppear:,
                    xe_splashContainerAppear, xe_orig_splashContainerAppear),
            // 开屏（第三方 / 聚合）
            XE_HOOK(GMSplashAd, showSplashViewInRootViewController:, xe_gmShowSplash, xe_orig_gmShowSplash),
            XE_HOOK(GMSplashAd, showCardViewInRootViewController:, xe_gmShowCard, xe_orig_gmShowCard),
            XE_HOOK(JHSplashAd, loadAdAndShowInWindow:, xe_jh1, xe_orig_jh1),
            XE_HOOK(JHSplashAd, loadAdAndShowInWindow:withBottomView:, xe_jh2, xe_orig_jh2),
            XE_HOOK(JHSplashAd, loadAdAndShowInWindow:withBottomView:skipView:, xe_jh3, xe_orig_jh3),
            XE_HOOK(JHSplashAd, loadAdAndShowInWindow:withBottomView:skipView:configModel:, xe_jh4, xe_orig_jh4),
            XE_HOOK(UBiXSplashAd, loadAd, xe_ubixLoad, xe_orig_ubixLoad),
            XE_HOOK(UBiXSplashAd, showAdToWindow:bottomView:, xe_ubixShow, xe_orig_ubixShow),
            XE_HOOK(EMNativeAdViewController,
                    showSplashAdInWindow:bottomView:skipView:logoView:loadingView:,
                    xe_emShowSplash, xe_orig_emShowSplash),
            // 信息流卡片
            XE_HOOK(DJXAdCollectionViewCell, mountAdView:, xe_mountAdView, xe_orig_mountAdView),
        };

        int total = (int)(sizeof(hooks) / sizeof(hooks[0]));
        int ok = 0;
        for (int i = 0; i < total; i++) {
            if (XEInstall(hooks[i])) ok++;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, XEPrefsChanged,
                                        CFSTR(XE_NOTIFY_STR), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        gXEHookOK = ok;
        gXEHookTotal = total;

        // 三个入口各自独立：哪个环境不适用都不影响另外两个
        XEInstallMineCleaner();       // 「我的」页板块拦截（视图挂载时判定）
        XEInstallSettingsEntry();     // ① 设置页最后一行（视图注入）+ 页面探测
        XEInstallFloatingEntry();     // ② 悬浮齿轮（不依赖页面结构）
        XEScheduleBeacon();           // ③ 升级后首次启动自证一次

        XELog(@"installed %d/%d hooks, prefs=%@", ok, total, gXEPrefs);
        if (!gXEPrefs[@"debugLog"]) {
            NSLog(@"[XunleiEnhance] ready (%d/%d hooks)", ok, total);
        }
    }
}
