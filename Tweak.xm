#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// ─────────────────────────────────────────────────────────────────────────────
//  迅雷增强 / XunleiEnhance
//  目标：com.xunlei.mvideo (迅雷 25.2.90)
//  所有 hook 点均来自对 TDMVideo 主二进制 __objc_classlist 的静态解析结果，
//  方法与类型编码已逐条核对（见 tools/verify_hooks.py）。
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
    static NSMutableArray<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = [NSMutableArray array];
        // 越狱(rootful) / 越狱(rootless/jbroot) / TrollStore 常见位置
        [paths addObject:@"/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist"];
        [paths addObject:@"/var/jb/var/mobile/Library/Preferences/com.xunlei.mvideo.xunleienhance.plist"];
    });
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static void XEReloadPrefs(void) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    // 1) CFPreferences（越狱下最可靠）
    NSArray<NSString *> *keys = @[
        @"enabled", @"blockSplash", @"blockFeedAd", @"blockAdLoad", @"hideAdCell",
        @"blockAllSlots", @"disablePersonalize", @"disableShake", @"limitAutoJump",
        @"debugLog"
    ];
    for (NSString *k in keys) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k,
                                                       CFSTR(XE_PREF_DOMAIN_STR));
        if (v) {
            dict[k] = (__bridge_transfer id)v;
        }
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

static inline BOOL XEEnabled(void) { return XEBool(@"enabled", YES); }

// 各功能开关（未写入配置时使用默认值）
static inline BOOL XE_BlockSplash(void)        { return XEEnabled() && XEBool(@"blockSplash", YES); }
static inline BOOL XE_BlockFeedAd(void)        { return XEEnabled() && XEBool(@"blockFeedAd", YES); }
static inline BOOL XE_BlockAdLoad(void)        { return XEEnabled() && XEBool(@"blockAdLoad", YES); }
static inline BOOL XE_HideAdCell(void)         { return XEEnabled() && XEBool(@"hideAdCell", YES); }
static inline BOOL XE_BlockAllSlots(void)      { return XEEnabled() && XEBool(@"blockAllSlots", NO); }
static inline BOOL XE_DisablePersonalize(void){ return XEEnabled() && XEBool(@"disablePersonalize", YES); }
static inline BOOL XE_DisableShake(void)       { return XEEnabled() && XEBool(@"disableShake", YES); }
static inline BOOL XE_LimitAutoJump(void)      { return XEEnabled() && XEBool(@"limitAutoJump", YES); }

#pragma mark - 通知

static void XEPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    XEReloadPrefs();
    XELog(@"prefs reloaded: %@", gXEPrefs);
}

#pragma mark - 广告核心：缓存出价池拦截
// XC SDK 所有广告（开屏/信息流/激励）最终都通过 CacheManager 从出价池里 pop 出来，
// 这里返回空即意味着"没有任何可用广告"，业务侧会走无广告分支（与拉取失败一致）。

%hook XCAdCoreCacheManager

- (id)popTopPriceAdFromCacheWithStrategy:(id)strategy
                                 slotTag:(id)slotTag
                                     ext:(id)ext
                            bindContext:(id)ctx
                                 adStyle:(NSUInteger)adStyle
                            throughModel:(id)model {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) {
        XELog(@"block popTopPrice ad slot=%@ style=%lu", slotTag, (unsigned long)adStyle);
        return nil;
    }
    return %orig;
}

- (id)popAllAvailableNativeAdAndNoDestory:(id)ctx
                                  slotTag:(id)slotTag
                                  adStyle:(NSUInteger)adStyle {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) {
        XELog(@"block popAll ad slot=%@", slotTag);
        return @[];
    }
    return %orig;
}

- (NSUInteger)shouldPreloadNativeAdCount:(id)strategy adStyle:(NSUInteger)adStyle {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) return 0;
    return %orig;
}

- (NSUInteger)getCacheCount:(id)slotTag adStyle:(NSUInteger)adStyle {
    if (XE_BlockAdLoad() || XE_BlockFeedAd()) return 0;
    return %orig;
}

%end

#pragma mark - 广告位与请求频率
// filterSlotTags: 返回"允许的广告位集合"，返回空数组等于一个广告位都不给。
// isAllowRequestAdWithSlot: 是请求前的频率/黑名单闸门。

%hook XCAdConfigManager

- (NSArray *)filterSlotTags:(NSArray *)tags {
    if (XE_BlockAllSlots()) {
        XELog(@"block all slot tags (%lu)", (unsigned long)[tags count]);
        return @[];
    }
    return %orig;
}

- (void)startFetchRealtimeConfig {
    if (XE_BlockAllSlots()) {
        XELog(@"skip realtime ad config fetch");
        return;
    }
    %orig;
}

// 个性化广告推荐（对应 App 内"广告设置 - 个性化推荐"开关）
- (BOOL)effectiveDisablePersonalRecommend {
    if (XE_DisablePersonalize()) return YES;
    return %orig;
}

- (BOOL)disablePersonalRecommend {
    if (XE_DisablePersonalize()) return YES;
    return %orig;
}

// 限制广告自动点击跳转
- (BOOL)autoClickJumpLimit {
    if (XE_LimitAutoJump()) return YES;
    return %orig;
}

%end

%hook XCAdCoreSlotRequestFrequencyControlManager

- (BOOL)isAllowRequestAdWithSlot:(id)slot slotTag:(id)slotTag traceId:(id)traceId {
    if (XE_BlockAllSlots()) {
        XELog(@"deny ad request slot=%@ tag=%@", slot, slotTag);
        return NO;
    }
    return %orig;
}

%end

#pragma mark - 广告配置模型：摇一摇 / 扭一扭
// 开屏摇一摇是误触重灾区，配置层直接关掉。

%hook XCAdConfigModel

- (BOOL)disableShake {
    if (XE_DisableShake()) return YES;
    return %orig;
}

- (int)splash_sdk_shake_state {
    if (XE_DisableShake()) return 0;
    return %orig;
}

%end

#pragma mark - 开屏广告（自渲染）
// XC 自渲染开屏（ZY 系 VC）：出现后立刻关闭。

static void XECloseSplashVC(UIViewController *vc) {
    if (!vc) return;
    @try {
        SEL sel = NSSelectorFromString(@"closeAd");
        if ([vc respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
#pragma clang diagnostic pop
            XELog(@"closed self-rendered splash: %@", NSStringFromClass([vc class]));
        }
    } @catch (NSException *e) {
        XELog(@"closeSplash exception: %@", e);
    }
}

%hook ZYMixSplashViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!XE_BlockSplash()) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XECloseSplashVC(weakSelf);
    });
}
%end

%hook ZYCustomizeSplashViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!XE_BlockSplash()) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XECloseSplashVC(weakSelf);
    });
}
%end

#pragma mark - 开屏广告（第三方 / 聚合 SDK 展示入口）

%hook GMSplashAd
- (void)showSplashViewInRootViewController:(UIViewController *)vc {
    if (XE_BlockSplash()) { XELog(@"block GM splash"); return; }
    %orig;
}
- (void)showCardViewInRootViewController:(UIViewController *)vc {
    if (XE_BlockSplash()) return;
    %orig;
}
%end

%hook JHSplashAd
- (void)loadAdAndShowInWindow:(id)window {
    if (XE_BlockSplash()) { XELog(@"block JH splash"); return; }
    %orig;
}
- (void)loadAdAndShowInWindow:(id)window withBottomView:(id)bottom {
    if (XE_BlockSplash()) return;
    %orig;
}
- (void)loadAdAndShowInWindow:(id)window withBottomView:(id)bottom skipView:(id)skip {
    if (XE_BlockSplash()) return;
    %orig;
}
- (void)loadAdAndShowInWindow:(id)window withBottomView:(id)bottom skipView:(id)skip configModel:(id)model {
    if (XE_BlockSplash()) return;
    %orig;
}
%end

%hook UBiXSplashAd
- (void)loadAd {
    if (XE_BlockSplash()) { XELog(@"block UBiX splash load"); return; }
    %orig;
}
- (void)showAdToWindow:(id)window bottomView:(id)bottom {
    if (XE_BlockSplash()) return;
    %orig;
}
%end

%hook EMNativeAdViewController
- (void)showSplashAdInWindow:(id)window
                  bottomView:(id)bottom
                    skipView:(id)skip
                    logoView:(id)logo
                 loadingView:(id)loading {
    if (XE_BlockSplash()) { XELog(@"block EM splash"); return; }
    %orig;
}
%end

#pragma mark - 信息流广告卡片
// 不改变 cell 高度（改 frame 易触发 collectionView 布局异常），只让广告内容不挂载。

%hook DJXAdCollectionViewCell
- (void)mountAdView:(id)adView {
    if (XE_HideAdCell() || XE_BlockFeedAd()) {
        XELog(@"block mount ad view in feed cell");
        return;
    }
    %orig;
}
%end

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        XEReloadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, XEPrefsChanged,
                                        CFSTR(XE_NOTIFY_STR), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        XELog(@"loaded, prefs=%@", gXEPrefs);
    }
}
