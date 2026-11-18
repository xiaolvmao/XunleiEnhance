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
#define XE_VERSION @"1.1.0"

static NSDictionary *gXEPrefs = nil;

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
            @"blockFeedAd": @YES,
            @"blockAdLoad": @YES,
            @"hideAdCell": @YES,
            @"blockAllSlots": @NO,
            @"disablePersonalize": @YES,
            @"disableShake": @YES,
            @"limitAutoJump": @YES,
            @"debugLog": @NO,
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

#pragma mark - App 内设置面板
//
// 注入环境里没有 PreferenceLoader（deb 的 layout 不会被安装），系统「设置」
// 里不会有入口。所以入口改放到迅雷自己的「设置」页：在这个列表末尾追加一行
// 「迅雷增强」，点进去是插件自己的开关面板。不需要任何隐藏手势。

static NSInteger gXEHookOK = 0;
static NSInteger gXEHookTotal = 0;

static char kXESwitchKey;   // 关联对象 key

@interface XESettingsController : UITableViewController
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
                   @{ @"key": @"blockFeedAd", @"title": @"去除信息流广告" },
                   @{ @"key": @"blockAdLoad", @"title": @"拦截广告预加载" },
                   @{ @"key": @"hideAdCell", @"title": @"隐藏广告卡片" },
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

            @{ @"title": @"调试",
               @"footer": @"把 [XunleiEnhance] 日志打到控制台（Console / idevicesyslog）。",
               @"items": @[ @{ @"key": @"debugLog", @"title": @"输出调试日志" } ] },

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

    if (item[@"action"]) {
        static NSString *rid = @"XEActionCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:rid];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor systemRedColor];
        }
        cell.textLabel.text = item[@"title"];
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
    if ([key isEqualToString:@"enabled"]) {
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *spec = [self xe_spec];
    NSDictionary *item = spec[indexPath.section][@"items"][indexPath.row];
    if (!item[@"action"]) return;

    XEResetPrefs();
    [tableView reloadData];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已恢复默认设置"
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

#pragma mark - 设置页入口：往迅雷设置列表末尾追加一行
// 只碰「多出来那一行」的 6 个索引路径方法，其余原样转发给原实现，
// 所以不会打乱迅雷自己的分组与行序。

static Class xe_entryClass = Nil;
static NSInteger (*xe_orig_rowCount)(id, SEL, UITableView *, NSInteger);
static UITableViewCell *(*xe_orig_cellForRow)(id, SEL, UITableView *, NSIndexPath *);
static void (*xe_orig_didSelectRow)(id, SEL, UITableView *, NSIndexPath *);
static double (*xe_orig_rowHeight)(id, SEL, UITableView *, NSIndexPath *);
static BOOL (*xe_orig_canEditRow)(id, SEL, UITableView *, NSIndexPath *);
static id (*xe_orig_swipeActions)(id, SEL, UITableView *, NSIndexPath *);

#define XE_ENTRY_TITLE @"迅雷增强"

// 追加到设置的「最后一段」末尾，视觉上就是列表最后一行
static NSInteger XEEntrySection(UITableView *tv) {
    NSInteger n = (NSInteger)[tv numberOfSections];
    return n > 0 ? n - 1 : 0;
}

static NSInteger XEAppRowCount(id self, UITableView *tv) {
    if (!xe_orig_rowCount) return 0;
    return xe_orig_rowCount(self, @selector(tableView:numberOfRowsInSection:),
                            tv, XEEntrySection(tv));
}

static BOOL XEIsEntryRow(id self, UITableView *tv, NSIndexPath *ip) {
    if (!ip || ip.section != XEEntrySection(tv)) return NO;
    return ip.row == XEAppRowCount(self, tv);
}

static NSInteger xe_rowCount(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger n = xe_orig_rowCount(self, _cmd, tv, section);
    return (section == XEEntrySection(tv)) ? n + 1 : n;
}

static UITableViewCell *xe_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (!XEIsEntryRow(self, tv, ip)) return xe_orig_cellForRow(self, _cmd, tv, ip);

    static NSString *rid = @"XunleiEnhanceEntry";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                     reuseIdentifier:rid];
        cell.textLabel.text = XE_ENTRY_TITLE;
        cell.detailTextLabel.text = @"去广告";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

static void xe_didSelectRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (!XEIsEntryRow(self, tv, ip)) {
        xe_orig_didSelectRow(self, _cmd, tv, ip);
        return;
    }
    [tv deselectRowAtIndexPath:ip animated:YES];
    XELog(@"open enhance settings panel");
    XEShowSettingsFrom(self);
}

static double xe_rowHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (!XEIsEntryRow(self, tv, ip)) return xe_orig_rowHeight(self, _cmd, tv, ip);
    NSInteger sec = XEEntrySection(tv);
    NSInteger rows = xe_orig_rowCount(self, @selector(tableView:numberOfRowsInSection:), tv, sec);
    if (rows <= 0) return 54;   // 空段别去问原实现，免得索引越界
    double h = xe_orig_rowHeight(self, _cmd, tv,
                                [NSIndexPath indexPathForRow:0 inSection:sec]);
    // -1 是 UITableViewAutomaticDimension，说明按约束自适应，给个固定值更稳
    if (!(h > 30) || h > 100) h = 54;
    return h;
}

static BOOL xe_canEditRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (XEIsEntryRow(self, tv, ip)) return NO;
    return xe_orig_canEditRow(self, _cmd, tv, ip);
}

static id xe_swipeActions(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (XEIsEntryRow(self, tv, ip)) return nil;
    return xe_orig_swipeActions(self, _cmd, tv, ip);
}

static int XEInstallEntryHooksOn(Class cls) {
    if (!cls) return 0;
    if (xe_orig_rowCount && cls != xe_entryClass) return 0;   // 只挂一个类，避免 orig 串台
    int n = 0;
    if (XEInstallOn(cls, "tableView:numberOfRowsInSection:",
                    (IMP)xe_rowCount, (IMP *)&xe_orig_rowCount)) n++;
    if (XEInstallOn(cls, "tableView:cellForRowAtIndexPath:",
                    (IMP)xe_cellForRow, (IMP *)&xe_orig_cellForRow)) n++;
    if (XEInstallOn(cls, "tableView:didSelectRowAtIndexPath:",
                    (IMP)xe_didSelectRow, (IMP *)&xe_orig_didSelectRow)) n++;
    if (XEInstallOn(cls, "tableView:heightForRowAtIndexPath:",
                    (IMP)xe_rowHeight, (IMP *)&xe_orig_rowHeight)) n++;
    if (XEInstallOn(cls, "tableView:canEditRowAtIndexPath:",
                    (IMP)xe_canEditRow, (IMP *)&xe_orig_canEditRow)) n++;
    if (XEInstallOn(cls, "tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:",
                    (IMP)xe_swipeActions, (IMP *)&xe_orig_swipeActions)) n++;
    if (n > 0) { xe_entryClass = cls; }
    return n;
}

static BOOL XEClassHasEntrySelectors(Class cls) {
    static const char *sels[] = {
        "tableView:numberOfRowsInSection:",
        "tableView:cellForRowAtIndexPath:",
        "tableView:didSelectRowAtIndexPath:",
        "tableView:heightForRowAtIndexPath:",
        "tableView:canEditRowAtIndexPath:",
        "tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:",
    };
    for (int i = 0; i < (int)(sizeof(sels) / sizeof(sels[0])); i++) {
        if (!class_getInstanceMethod(cls, sel_registerName(sels[i]))) return NO;
    }
    return YES;
}

static const char *kXESettingsClassNames[] = {
    "_TtC8TDMVideo28CommonSettingsViewController",   // 迅雷 25.2.90「设置」页
};

static void XEInstallSettingsEntry(void) {
    if (xe_orig_rowCount) return;   // 已经挂上

    for (size_t i = 0; i < sizeof(kXESettingsClassNames) / sizeof(char *); i++) {
        Class cls = objc_getClass(kXESettingsClassNames[i]);
        if (cls && XEInstallEntryHooksOn(cls) > 0) {
            XELog(@"entry hooks installed on %s", kXESettingsClassNames[i]);
            return;
        }
    }

    // 版本改名兜底：扫「类名以 SettingsViewController 结尾 + 六个方法全在」的类
    const char *suffix = "SettingsViewController";
    size_t suffixLen = strlen(suffix);
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(list[i]);
        if (!name) continue;
        size_t len = strlen(name);
        if (len < suffixLen || strcmp(name + len - suffixLen, suffix) != 0) continue;
        if (!XEClassHasEntrySelectors(list[i])) continue;
        if (XEInstallEntryHooksOn(list[i]) > 0) {
            XELog(@"entry hooks installed on %s (fallback)", name);
            break;
        }
    }
    free(list);
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

        gXEHookOK = ok;
        gXEHookTotal = total;

        // 设置入口：往迅雷「设置」列表插一行（不需要 PreferenceLoader）
        XEInstallSettingsEntry();

        XELog(@"installed %d/%d hooks, prefs=%@", ok, total, gXEPrefs);
        if (!gXEPrefs[@"debugLog"]) {
            NSLog(@"[XunleiEnhance] ready (%d/%d hooks)", ok, total);
        }
    }
}
