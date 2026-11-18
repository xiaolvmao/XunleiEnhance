#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

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

static NSDictionary *gXEPrefs = nil;

#pragma mark - 日志

static inline void XELog(NSString *fmt, ...) {
    if (![gXEPrefs[@"debugLog"] boolValue]) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[XunleiEnhance] %@", msg);
}

#pragma mark - 偏好读取

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
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    NSArray<NSString *> *keys = @[
        @"enabled", @"blockSplash", @"blockFeedAd", @"blockAdLoad", @"hideAdCell",
        @"blockAllSlots", @"disablePersonalize", @"disableShake", @"limitAutoJump",
        @"debugLog"
    ];

    // 1) CFPreferences（越狱环境最可靠）
    for (NSString *k in keys) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k,
                                                       CFSTR(XE_PREF_DOMAIN_STR));
        if (v) dict[k] = (__bridge_transfer id)v;
    }

    // 2) 兜底：直接读 plist（沙盒内 CFPreferences 被重定向时使用）
    if (dict.count == 0) {
        NSString *path = XEPrefFilePath();
        if (path) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (d) [dict addEntriesFromDictionary:d];
        }
    }

    gXEPrefs = [dict copy];
}

static BOOL XEBool(NSString *key, BOOL fallback) {
    if (!gXEPrefs) XEReloadPrefs();
    id v = gXEPrefs[key];
    return v ? [v boolValue] : fallback;
}

static inline BOOL XEEnabled(void)          { return XEBool(@"enabled", YES); }
static inline BOOL XE_BlockSplash(void)     { return XEEnabled() && XEBool(@"blockSplash", YES); }
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
static BOOL XEInstall(XEHookEntry e) {
    Class cls = objc_getClass(e.cls);
    if (!cls) {
        XELog(@"skip %s (class not found)", e.cls);
        return NO;
    }
    Method m = class_getInstanceMethod(cls, sel_registerName(e.sel));
    if (!m) {
        XELog(@"skip %s %s (method not found)", e.cls, e.sel);
        return NO;
    }
    *e.orig = method_setImplementation(m, e.imp);
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

static void xe_closeSplash(id vc) {
    SEL sel = NSSelectorFromString(@"closeAd");
    if (![vc respondsToSelector:sel]) {
        XELog(@"%@ has no closeAd", NSStringFromClass([vc class]));
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [vc performSelector:sel];
#pragma clang diagnostic pop
    XELog(@"closed self-rendered splash: %@", NSStringFromClass([vc class]));
}

static void (*xe_orig_mixSplashWillAppear)(id, SEL, BOOL);
static void xe_mixSplashWillAppear(id self, SEL _cmd, BOOL animated) {
    xe_orig_mixSplashWillAppear(self, _cmd, animated);
    if (!XE_BlockSplash()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        xe_closeSplash(self);
    });
}

static void (*xe_orig_customSplashWillAppear)(id, SEL, BOOL);
static void xe_customSplashWillAppear(id self, SEL _cmd, BOOL animated) {
    xe_orig_customSplashWillAppear(self, _cmd, animated);
    if (!XE_BlockSplash()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
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

#pragma mark - 安装

__attribute__((constructor)) static void XEInitialize(void) {
    @autoreleasepool {
        XEReloadPrefs();

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

        XELog(@"installed %d/%d hooks, prefs=%@", ok, total, gXEPrefs);
        if (!gXEPrefs[@"debugLog"]) {
            NSLog(@"[XunleiEnhance] ready (%d/%d hooks)", ok, total);
        }
    }
}
