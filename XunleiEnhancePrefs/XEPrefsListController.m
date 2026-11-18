#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

#define XE_NOTIFY_STR "com.xiaolvmao.xunleienhance/reload"

@interface XEPrefsListController : PSListController
@end

@implementation XEPrefsListController

// PSListController 会从 bundle 里的 Root.plist 自动加载控件
- (id)init {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    if (!bundle) {
        bundle = [NSBundle bundleWithPath:@"/Library/PreferenceBundles/XunleiEnhancePrefs.bundle"];
    }
    return [super initWithNibName:@"Root" bundle:bundle];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"迅雷增强";
}

// 任意开关变更后通知宿主进程热加载（开屏类只在下次启动时读取）
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(XE_NOTIFY_STR), NULL, NULL, YES);
}

@end
