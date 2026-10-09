/**
 * DYGlassDock — 抖音「下载与胶囊」核心能力复刻
 *
 * 设计原则（来自技能库教训）：
 *  - 不 hook 任何抖音私有类（类名随版本变，hook 不存在会被 Logos 静默丢弃）
 *    → 只 hook 系统公共类：AVPlayerItem / AVURLAsset / NSURLSession
 *  - 自建浮层绝不 makeKeyAndVisible（§48：抢 key window 会瘫痪整机）
 *  - 浮层挂在 app 的 keyWindow 上，靠 keepalive 定时器保证存活
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <AudioToolbox/AudioToolbox.h>

// ============================================================
// MARK: - 设置键
// ============================================================
#define DY_K_ENABLED      @"dy_dock_enabled"
#define DY_K_ACTIONS      @"dy_dock_actions"
#define DY_K_POS_Y        @"dy_dock_pos_y"
#define DY_K_SNAP         @"dy_dock_snap"
#define DY_K_AUTOCOLLAPSE @"dy_dock_autocollapse"
#define DY_K_LOCK         @"dy_dock_lock"
#define DY_K_TOAST_SOUND  @"dy_toast_sound"
#define DY_K_SCALE        @"dy_dock_scale"

static NSString *DYStr(NSString *k, NSString *d) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:k];
    return v ?: d;
}
static BOOL DYBool(NSString *k, BOOL d) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:k];
    return v == nil ? d : [v boolValue];
}
static CGFloat DYFloat(NSString *k, CGFloat d) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:k];
    return v == nil ? d : [v floatValue];
}
static UIWindow *DYKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow) return w;
    return [UIApplication sharedApplication].windows.firstObject;
}

// ============================================================
// MARK: - 动作枚举
// ============================================================
typedef NS_ENUM(NSInteger, DYAction) {
    DYActionDownload = 0,
    DYActionCopy     = 1,
    DYActionShare    = 2,
    DYActionPanel    = 3,
    DYActionLock     = 4,
    DYActionHide     = 5,
};

// ============================================================
// MARK: - 前向声明（避免声明顺序问题）
// ============================================================
@interface DYDShared : NSObject
+ (instancetype)sh;
@property (nonatomic, strong) NSMutableArray<NSURL *> *urlHistory;
- (void)noteURL:(NSURL *)u;
- (NSURL *)bestURL;
- (NSString *)cleanURLString;
@end

@interface DYDockBridge : NSObject
+ (instancetype)bridge;
- (void)performAction:(DYAction)a;
- (void)doDownload;
@end

@interface DYPanelManager : NSObject
+ (instancetype)shared;
- (void)togglePanel;
@end

// ============================================================
// MARK: - URL 捕获与去水印（工具函数须先于使用者定义）
// ============================================================
static BOOL DYIsVideoURL(NSURL *u) {
    if (!u) return NO;
    NSString *s = [u absoluteString];
    if (s.length < 12) return NO;
    NSArray *keys = @[@"douyinvod", @"/aweme/v1/play", @"zjcdn", @"bytecdn",
                      @"toutiaovod", @"ixiguavod", @"bytedance", @"snssdk",
                      @".mp4", @"videoplaystat"];
    for (NSString *k in keys) if ([s containsString:k]) return YES;
    return NO;
}

static NSInteger DYURLScore(NSURL *u) {
    NSString *s = [u absoluteString] ?: @"";
    NSInteger sc = 0;
    if ([s containsString:@"douyinvod"]) sc += 10;
    if ([s containsString:@"/aweme/v1/play"]) sc += 8;
    if ([s containsString:@".mp4"]) sc += 4;
    if ([s containsString:@"ratio="]) sc += 1;
    return sc;
}

// 经典去水印：/playwm/ → /play/，并剔除 watermark 参数
static NSString *DYStripWatermark(NSString *raw) {
    if (!raw) return @"";
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"/playwm/" withString:@"/play/"];
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if ([c.queryItems count]) {
        NSMutableArray<NSURLQueryItem *> *keep = [NSMutableArray array];
        for (NSURLQueryItem *it in c.queryItems) {
            if (![it.name.lowercaseString containsString:@"watermark"]) [keep addObject:it];
        }
        c.queryItems = keep;
        NSString *out = c.URL.absoluteString;
        if (out) return out;
    }
    return s;
}

@implementation DYDShared
+ (instancetype)sh {
    static DYDShared *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DYDShared new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (self) self.urlHistory = [NSMutableArray array];
    return self;
}
- (void)noteURL:(NSURL *)u {
    if (!DYIsVideoURL(u)) return;
    NSString *abs = [u absoluteString];
    for (NSURL *old in self.urlHistory)
        if ([old.absoluteString isEqualToString:abs]) return;
    [self.urlHistory insertObject:u atIndex:0];
    if (self.urlHistory.count > 40) [self.urlHistory removeLastObject];
}
- (NSURL *)bestURL {
    NSURL *best = nil;
    NSInteger bestSc = -1;
    for (NSURL *u in self.urlHistory) {
        NSInteger sc = DYURLScore(u);
        if (sc > bestSc) { bestSc = sc; best = u; }
    }
    return best;
}
- (NSString *)cleanURLString {
    NSURL *u = [self bestURL];
    return u ? DYStripWatermark(u.absoluteString) : nil;
}
@end

// ============================================================
// MARK: - 顶部提示
// ============================================================
static void DYToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = DYKeyWindow();
        if (!key) return;

        UILabel *lb = [[UILabel alloc] init];
        lb.text = msg;
        lb.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        lb.textColor = [UIColor whiteColor];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.numberOfLines = 0;
        lb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        lb.layer.cornerRadius = 12;
        lb.layer.masksToBounds = YES;

        CGSize sz = [lb sizeThatFits:CGSizeMake(key.bounds.size.width - 80, CGFLOAT_MAX)];
        CGFloat w = MIN(MAX(sz.width + 36, 140), key.bounds.size.width - 60);
        CGFloat h = MAX(sz.height + 20, 40);
        lb.frame = CGRectMake((key.bounds.size.width - w) / 2,
                              key.safeAreaInsets.top + 14, w, h);
        lb.alpha = 0;
        [key addSubview:lb];

        if (DYBool(DY_K_TOAST_SOUND, YES)) AudioServicesPlaySystemSound(1104);

        [UIView animateWithDuration:0.22 animations:^{ lb.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ lb.alpha = 0; }
                             completion:^(BOOL done) { [lb removeFromSuperview]; }];
        });
    });
}

// ============================================================
// MARK: - 图标 / 标题
// ============================================================
static UIImage *DYIconForAction(DYAction a) {
    NSString *name = nil;
    switch (a) {
        case DYActionDownload: name = @"arrow.down.circle.fill";       break;
        case DYActionCopy:     name = @"doc.on.doc.fill";              break;
        case DYActionShare:    name = @"square.and.arrow.up.fill";     break;
        case DYActionPanel:    name = @"square.grid.2x2.fill";         break;
        case DYActionLock:     name = @"lock.fill";                    break;
        case DYActionHide:     name = @"chevron.right";                break;
    }
    return [UIImage systemImageNamed:name];
}

static NSString *DYTitleForAction(DYAction a) {
    switch (a) {
        case DYActionDownload: return @"保存无水印";
        case DYActionCopy:     return @"复制直链";
        case DYActionShare:    return @"系统分享";
        case DYActionPanel:    return @"功能面板";
        case DYActionLock:     return @"锁定位置";
        case DYActionHide:     return @"隐藏胶囊";
    }
    return @"";
}

// ============================================================
// MARK: - 玻璃按钮
// ============================================================
@interface DYGlassButton : UIControl
@property (nonatomic, assign) DYAction action;
@end

@implementation DYGlassButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;

        UIImageView *iv = [[UIImageView alloc] initWithImage:DYIconForAction(self.action)];
        iv.tintColor = [UIColor whiteColor];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.tag = 7788;
        [self addSubview:iv];
    }
    return self;
}
- (void)setAction:(DYAction)a {
    _action = a;
    UIImageView *iv = [self viewWithTag:7788];
    iv.image = DYIconForAction(a);
}
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    self.backgroundColor = h ? [UIColor colorWithWhite:1 alpha:0.26]
                             : [UIColor colorWithWhite:1 alpha:0.10];
    self.transform = h ? CGAffineTransformMakeScale(0.92, 0.92)
                       : CGAffineTransformIdentity;
}
@end

// ============================================================
// MARK: - 玻璃胶囊容器
// ============================================================
@interface DYGlassDockView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) CAGradientLayer *highlight;
@property (nonatomic, strong) NSMutableArray<DYGlassButton *> *buttons;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
- (void)rebuildButtons;
- (void)resetIdle;
@end

@implementation DYGlassDockView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.masksToBounds = NO;
        self.clipsToBounds = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        UIBlurEffect *be = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blur = [[UIVisualEffectView alloc] initWithEffect:be];
        _blur.userInteractionEnabled = NO;
        _blur.frame = self.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];

        _tintView = [[UIView alloc] initWithFrame:self.bounds];
        _tintView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        _tintView.userInteractionEnabled = NO;
        _tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_tintView];

        _highlight = [CAGradientLayer layer];
        _highlight.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor,
                              (id)[UIColor colorWithWhite:1 alpha:0.02].CGColor,
                              (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
        _highlight.locations = @[@0.0, @0.35, @1.0];
        _highlight.startPoint = CGPointMake(0.5, 0);
        _highlight.endPoint   = CGPointMake(0.5, 1);
        [self.layer addSublayer:_highlight];

        _buttons = [NSMutableArray array];

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        _pan.delegate = self;
        [self addGestureRecognizer:_pan];

        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
        lp.minimumPressDuration = 0.5;
        [self addGestureRecognizer:lp];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = self.bounds.size.height / 2;
    self.layer.cornerRadius = r;
    _blur.layer.cornerRadius = r;
    _blur.frame = self.bounds;
    _tintView.layer.cornerRadius = r;
    _tintView.frame = self.bounds;
    _highlight.cornerRadius = r;
    _highlight.frame = self.bounds;
}

- (void)rebuildButtons {
    for (DYGlassButton *b in _buttons) [b removeFromSuperview];
    [_buttons removeAllObjects];

    NSString *spec = DYStr(DY_K_ACTIONS, @"download,copy,share,panel,lock");
    NSArray *parts = [spec componentsSeparatedByString:@","];
    CGFloat scale = DYFloat(DY_K_SCALE, 1.0);
    CGFloat side = 34 * scale, gap = 6 * scale, pad = 6 * scale;

    CGFloat y = pad;
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length == 0) continue;
        DYAction a = (DYAction)[t integerValue];
        if (a < DYActionDownload || a > DYActionHide) continue;
        DYGlassButton *b = [[DYGlassButton alloc] initWithFrame:CGRectMake(pad, y, side, side)];
        b.action = a;
        [b addTarget:self action:@selector(tapAction:)
           forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        [_buttons addObject:b];
        y += side + gap;
    }
    CGFloat h = y - gap + pad;
    CGFloat w = side + pad * 2;
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, w, h);
}

- (void)tapAction:(DYGlassButton *)sender {
    [self resetIdle];
    [[DYDockBridge bridge] performAction:sender.action];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (DYBool(DY_K_LOCK, NO)) return;
    CGPoint t = [g translationInView:self.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        [self.layer removeAllAnimations];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"dy_dock_ever_moved"];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = self.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        self.frame = f;
        [g setTranslation:CGPointZero inView:self.superview];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        self.dragging = NO;
        [self snapToEdge];
        [self resetIdle];
    }
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    BOOL now = !DYBool(DY_K_LOCK, NO);
    [[NSUserDefaults standardUserDefaults] setBool:now forKey:DY_K_LOCK];
    DYToast(now ? @"胶囊位置已锁定" : @"胶囊位置已解锁");
}

- (void)snapToEdge {
    if (!self.superview) return;
    CGFloat W = self.superview.bounds.size.width;
    CGFloat H = self.superview.bounds.size.height;
    CGFloat x = self.frame.origin.x;
    CGFloat target;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"dy_dock_ever_moved"] == nil) {
        target = W - self.bounds.size.width - 4;   // 默认贴右
    } else {
        target = (x + self.bounds.size.width / 2 < W / 2)
                 ? 4 : MAX(4, W - self.bounds.size.width - 4);
    }
    CGFloat y = MIN(MAX(self.frame.origin.y, 60), H - self.bounds.size.height - 40);
    [[NSUserDefaults standardUserDefaults] setFloat:y / H forKey:DY_K_POS_Y];
    [UIView animateWithDuration:0.28 delay:0
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{ self.frame = CGRectMake(target, y, self.bounds.size.width, self.bounds.size.height); }
        completion:nil];
}

- (void)armIdleTimer {
    [_idleTimer invalidate];
    _idleTimer = nil;
    if (!DYBool(DY_K_AUTOCOLLAPSE, YES)) return;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
        target:self selector:@selector(doCollapse) userInfo:nil repeats:NO];
}
- (void)resetIdle {
    if (_collapsed) [self expand];
    [self armIdleTimer];
}
- (void)doCollapse {
    if (_dragging || _collapsed || DYBool(DY_K_LOCK, NO)) return;
    [self collapseToBar];
}
- (void)collapseToBar {
    if (_collapsed) return;
    _collapsed = YES;
    [UIView animateWithDuration:0.3 animations:^{
        CGRect f = self.frame;
        f.size = CGSizeMake(10, 72);
        self.frame = f;
        for (DYGlassButton *b in self->_buttons) b.alpha = 0;
    }];
}
- (void)expand {
    if (!_collapsed) return;
    _collapsed = NO;
    [self rebuildButtons];
    for (DYGlassButton *b in _buttons) b.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{
        for (DYGlassButton *b in self->_buttons) b.alpha = 1;
    }];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
@end

// ============================================================
// MARK: - 动作桥
// ============================================================
@implementation DYDockBridge
+ (instancetype)bridge {
    static DYDockBridge *b = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [DYDockBridge new]; });
    return b;
}
- (void)performAction:(DYAction)a {
    NSString *clean = [DYDShared sh].cleanURLString;
    switch (a) {
        case DYActionDownload: [self doDownload]; break;
        case DYActionCopy:
            if (!clean) { DYToast(@"暂未识别到可下载资源"); break; }
            [UIPasteboard generalPasteboard].string = clean;
            DYToast(@"无水印直链已复制");
            break;
        case DYActionShare:
            if (!clean) { DYToast(@"暂未识别到可下载资源"); break; }
            [self shareText:clean];
            break;
        case DYActionPanel: [[DYPanelManager shared] togglePanel]; break;
        case DYActionLock: {
            BOOL now = !DYBool(DY_K_LOCK, NO);
            [[NSUserDefaults standardUserDefaults] setBool:now forKey:DY_K_LOCK];
            DYToast(now ? @"胶囊位置已锁定" : @"胶囊位置已解锁");
            break;
        }
        case DYActionHide: [self toggleDock]; break;
    }
}

- (void)doDownload {
    NSString *clean = [DYDShared sh].cleanURLString;
    if (!clean) { DYToast(@"暂未识别到可下载资源"); return; }
    DYToast(@"保存视频中...");
    NSURL *u = [NSURL URLWithString:clean];
    if (!u) { DYToast(@"视频地址无效"); return; }

    NSURLSessionDownloadTask *task =
        [[NSURLSession sharedSession] downloadTaskWithURL:u
            completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !loc) { DYToast(@"视频下载失败"); return; }
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray *docs = [fm URLsForDirectory:NSDocumentDirectory
                                       inDomains:NSUserDomainMask];
            if (![docs count]) { DYToast(@"下载文件落地失败"); return; }
            NSString *uid = [[[NSProcessInfo processInfo] globallyUniqueString]
                substringToIndex:MIN(12, [[[NSProcessInfo processInfo] globallyUniqueString] length])];
            NSURL *dst = [docs[0] URLByAppendingPathComponent:
                          [NSString stringWithFormat:@"dy_%@.mp4", uid]];
            [fm removeItemAtURL:dst error:nil];
            NSError *mvErr = nil;
            if (![fm moveItemAtURL:loc toURL:dst error:&mvErr]) {
                DYToast(@"下载文件落地失败"); return;
            }
            [self saveVideoToPhotos:dst];
        });
    }];
    [task resume];
}

- (void)saveVideoToPhotos:(NSURL *)fileURL {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
        handler:^(PHAuthorizationStatus st) {
        if (st != PHAuthorizationStatusAuthorized &&
            st != PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{ DYToast(@"缺少相册写入权限"); });
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        } completionHandler:^(BOOL ok, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DYToast(ok ? @"已保存无水印视频" : @"保存失败");
            });
        }];
    }];
}

- (void)shareText:(NSString *)text {
    UIViewController *vc = DYKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                         applicationActivities:nil];
    if (av.popoverPresentationController) {
        av.popoverPresentationController.sourceView = DYKeyWindow();
        av.popoverPresentationController.sourceRect =
            CGRectMake(DYKeyWindow().bounds.size.width / 2,
                       DYKeyWindow().bounds.size.height / 2, 1, 1);
    }
    [vc presentViewController:av animated:YES completion:nil];
}

- (void)toggleDock {
    UIWindow *key = DYKeyWindow();
    if (!key) return;
    for (UIView *v in key.subviews) {
        if ([v isKindOfClass:[DYGlassDockView class]]) {
            BOOL willHide = !v.hidden;
            [UIView animateWithDuration:0.22 animations:^{ v.alpha = willHide ? 0 : 1; }
                             completion:^(BOOL f) { v.hidden = willHide; }];
            DYToast(willHide ? @"胶囊已隐藏" : @"胶囊已显示");
            return;
        }
    }
}
@end

// ============================================================
// MARK: - 双击玻璃面板
// ============================================================
@interface DYPanelManager () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UIView *card;
@end

@implementation DYPanelManager
+ (instancetype)shared {
    static DYPanelManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [DYPanelManager new]; });
    return m;
}
- (void)togglePanel {
    if (_overlay) { [self dismiss]; return; }
    UIWindow *key = DYKeyWindow();
    if (!key) return;

    UIView *ov = [[UIView alloc] initWithFrame:key.bounds];
    ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    UITapGestureRecognizer *tg =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [ov addGestureRecognizer:tg];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 290, 250)];
    card.center = CGPointMake(key.bounds.size.width / 2, key.bounds.size.height / 2);
    card.layer.cornerRadius = 26;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    card.layer.shadowOpacity = 0.4;
    card.layer.shadowRadius = 18;

    UIVisualEffectView *bv = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    bv.frame = card.bounds;
    bv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bv.layer.cornerRadius = 26;
    bv.layer.masksToBounds = YES;
    [card addSubview:bv];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, 250, 24)];
    title.text = @"下载与胶囊";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [card addSubview:title];

    NSArray *acts = @[@(DYActionDownload), @(DYActionCopy),
                      @(DYActionShare), @(DYActionHide)];
    CGFloat side = 52, gap = 14;
    CGFloat startX = (290 - (side * acts.count + gap * (acts.count - 1))) / 2;
    for (NSInteger i = 0; i < (NSInteger)acts.count; i++) {
        DYGlassButton *b = [[DYGlassButton alloc]
            initWithFrame:CGRectMake(startX + i * (side + gap), 58, side, side)];
        b.action = (DYAction)[acts[i] integerValue];
        [b addTarget:self action:@selector(panelAction:)
           forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:b];

        UILabel *lb = [[UILabel alloc]
            initWithFrame:CGRectMake(b.frame.origin.x - 8, 58 + side + 4, side + 16, 16)];
        lb.text = DYTitleForAction(b.action);
        lb.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        lb.font = [UIFont systemFontOfSize:11];
        lb.textAlignment = NSTextAlignmentCenter;
        [card addSubview:lb];
    }

    NSArray *rows = @[ @[DY_K_SNAP, @"贴边吸附"],
                       @[DY_K_AUTOCOLLAPSE, @"自动收起透明条"],
                       @[DY_K_TOAST_SOUND, @"提示音"] ];
    CGFloat y = 132;
    for (NSArray *row in rows) {
        NSString *k = row[0];
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(22, y, 180, 20)];
        lb.text = row[1];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:14];
        [card addSubview:lb];
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(290 - 22 - 51, y - 2, 51, 31)];
        sw.on = DYBool(k, YES);
        sw.tag = (NSUInteger)[k hash];
        [sw addTarget:self action:@selector(switchChanged:)
           forControlEvents:UIControlEventValueChanged];
        [card addSubview:sw];
        y += 36;
    }

    [ov addSubview:card];
    [key addSubview:ov];
    _overlay = ov;
    _card = card;
    card.transform = CGAffineTransformMakeScale(0.9, 0.9);
    card.alpha = 0;
    [UIView animateWithDuration:0.22 animations:^{
        card.transform = CGAffineTransformIdentity;
        card.alpha = 1;
    }];
}
- (void)panelAction:(DYGlassButton *)b {
    [self dismiss];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DYDockBridge bridge] performAction:b.action];
    });
}
- (void)switchChanged:(UISwitch *)s {
    NSString *k = nil;
    if (s.tag == (NSUInteger)[DY_K_SNAP hash]) k = DY_K_SNAP;
    else if (s.tag == (NSUInteger)[DY_K_AUTOCOLLAPSE hash]) k = DY_K_AUTOCOLLAPSE;
    else if (s.tag == (NSUInteger)[DY_K_TOAST_SOUND hash]) k = DY_K_TOAST_SOUND;
    if (!k) return;
    [[NSUserDefaults standardUserDefaults] setBool:s.on forKey:k];
    DYToast(s.on ? @"已开启" : @"已关闭");
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"DYDockShouldRebuild" object:nil];
}
- (void)dismiss {
    if (!_overlay) return;
    UIView *ov = _overlay;
    _overlay = nil;
    _card = nil;
    [UIView animateWithDuration:0.18 animations:^{ ov.alpha = 0; }
                     completion:^(BOOL f) { [ov removeFromSuperview]; }];
}
@end

// ============================================================
// MARK: - 挂载 / 保活
// ============================================================
@interface DYDockManager : NSObject
@property (nonatomic, strong) NSTimer *keepalive;
- (void)start;
- (void)attach;
@end

@implementation DYDockManager
+ (instancetype)shared {
    static DYDockManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [DYDockManager new]; });
    return m;
}
- (void)start {
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(attach)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(attach)
               name:@"DYDockShouldRebuild" object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.keepalive = [NSTimer timerWithTimeInterval:2.0
            target:self selector:@selector(attach) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.keepalive
                                 forMode:NSRunLoopCommonModes];
    });
}
- (void)attach {
    if (!DYBool(DY_K_ENABLED, YES)) return;
    UIWindow *key = DYKeyWindow();
    if (!key) return;

    DYGlassDockView *dock = nil;
    for (UIView *v in key.subviews) {
        if ([v isKindOfClass:[DYGlassDockView class]]) {
            dock = (DYGlassDockView *)v;
            break;
        }
    }
    if (!dock) {
        CGFloat scale = DYFloat(DY_K_SCALE, 1.0);
        dock = [[DYGlassDockView alloc] initWithFrame:CGRectMake(0, 0, 46 * scale, 46 * scale)];
        [dock rebuildButtons];
        [key addSubview:dock];
    }
    CGFloat W = key.bounds.size.width, H = key.bounds.size.height;
    CGFloat y = DYFloat(DY_K_POS_Y, 0.45) * H;
    y = MIN(MAX(y, 60), H - dock.bounds.size.height - 40);
    CGFloat x = W - dock.bounds.size.width - 4;
    if (dock.frame.origin.x == 0 && dock.frame.origin.y == 0) {
        dock.frame = CGRectMake(x, y, dock.bounds.size.width, dock.bounds.size.height);
    } else {
        dock.frame = CGRectMake(
            MIN(MAX(dock.frame.origin.x, 0), MAX(0, W - dock.bounds.size.width)),
            MIN(MAX(dock.frame.origin.y, 60), MAX(60, H - dock.bounds.size.height - 40)),
            dock.bounds.size.width, dock.bounds.size.height);
    }
    [key bringSubviewToFront:dock];
}
@end

// ============================================================
// MARK: - Logos Hooks（只 hook 系统公共类）
// ============================================================
%hook AVPlayerItem
- (instancetype)initWithURL:(NSURL *)URL {
    [[DYDShared sh] noteURL:URL];
    return %orig;
}
%end

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    [[DYDShared sh] noteURL:URL];
    return %orig;
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (request.URL) [[DYDShared sh] noteURL:request.URL];
    return %orig;
}
%end

// ============================================================
// MARK: - 构造
// ============================================================
%ctor {
    @autoreleasepool {
        %init;
        [[DYDockManager shared] start];
    }
}
