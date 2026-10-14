#import "ALStreamViewController.h"
#import "ALStreamSession.h"
#import "ALGamepadOverlayView.h"
#import "ALVideoDecoder.h"
#import "ALVideoView.h"
#import "ALAudioPlayer.h"
#import "ALGameStream.h"
#import "ALAlerts.h"
#import "ALSettings.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALModern.h"
#import "ALCommon.h"
#include "Limelight.h"

// A view that takes keyboard input and forwards it
@interface ALKeyInputView : UIView <UIKeyInput>
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onBackspace)(void);
@property (nonatomic, strong) UIView *accessory;
@end

@implementation ALKeyInputView
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIView *)inputAccessoryView { return self.accessory; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceAlert; }
- (void)insertText:(NSString *)text { if (self.onText) self.onText(text); }
- (void)deleteBackward { if (self.onBackspace) self.onBackspace(); }
@end

// The surface over the picture that turns touches into mouse or touch input
@class ALStreamViewController;
@interface ALTouchSurface : UIView
@property (nonatomic, weak) ALStreamViewController *owner;
@end

@interface ALStreamViewController () <ALStreamSessionDelegate>
@property (nonatomic, strong) ALHost *host;
@property (nonatomic, strong) ALApp *app;
@property (nonatomic, strong) ALStreamSession *session;
@property (nonatomic, strong) ALVideoView *videoView;
@property (nonatomic, strong) ALTouchSurface *touchSurface;
@property (nonatomic, strong) ALGamepadOverlayView *gamepad;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) ALKeyInputView *keyInput;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL gotFirstFrame;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic) uint8_t stickyModifiers;     // from the keyboard bar's Ctrl/Alt/Win buttons, for the next key
// touch state
@property (nonatomic) ALTouchMode touchMode;
@property (nonatomic, strong) NSMutableDictionary *touchIds;   // UITouch pointer -> NSNumber pointer id (touchscreen mode)
@property (nonatomic) uint32_t nextTouchId;
@property (nonatomic) CGPoint lastPoint;
@property (nonatomic) CGPoint startPoint;
@property (nonatomic) NSTimeInterval touchStart;
@property (nonatomic) NSTimeInterval lastTapEnd;
@property (nonatomic) BOOL moved;
@property (nonatomic) BOOL dragging;               // trackpad: tap then hold = drag with the left button
@property (nonatomic) BOOL twoFinger;
@property (nonatomic) CGFloat remainderX, remainderY, scrollRemainder;
- (void)surfaceTouches:(NSSet *)touches event:(UIEvent *)event phase:(int)phase;   // 0 began, 1 moved, 2 ended, 3 cancelled
@end

@implementation ALTouchSurface
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self.owner surfaceTouches:touches event:event phase:0]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self.owner surfaceTouches:touches event:event phase:1]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self.owner surfaceTouches:touches event:event phase:2]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self.owner surfaceTouches:touches event:event phase:3]; }
@end

@implementation ALStreamViewController

- (instancetype)initWithHost:(ALHost *)host app:(ALApp *)app
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _host = host;
        _app = app;
        _touchIds = [NSMutableDictionary dictionary];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.wantsFullScreenLayout = YES;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_statsTimer invalidate];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;
    self.videoView = [[ALVideoView alloc] initWithFrame:self.view.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.videoView];

    self.touchSurface = [[ALTouchSurface alloc] initWithFrame:self.view.bounds];
    self.touchSurface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.touchSurface.backgroundColor = [UIColor clearColor];
    self.touchSurface.multipleTouchEnabled = YES;
    self.touchSurface.owner = self;
    [self.view addSubview:self.touchSurface];

    __weak ALStreamViewController *weakSelf = self;
    self.gamepad = [[ALGamepadOverlayView alloc] initWithFrame:self.view.bounds];
    self.gamepad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.gamepad.controlOpacity = [ALSettings gamepadOpacity];
    self.gamepad.hidden = ![ALSettings touchGamepad];
    self.gamepad.onChange = ^(ALGamepadState state) { [weakSelf.session sendGamepad:state]; };
    [self.view addSubview:self.gamepad];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont systemFontOfSize:ALIsPad() ? 16 : 13];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = L(@"Connecting…");
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statsLabel.font = [UIFont fontWithName:@"Courier-Bold" size:11];
    self.statsLabel.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.35 alpha:1];
    self.statsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.statsLabel.numberOfLines = 0;
    self.statsLabel.hidden = ![ALSettings showStats];
    [self.view addSubview:self.statsLabel];

    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toastLabel.font = [UIFont boldSystemFontOfSize:ALIsPad() ? 16 : 13];
    self.toastLabel.textColor = [UIColor whiteColor];
    self.toastLabel.backgroundColor = [UIColor colorWithRed:0.45 green:0.25 blue:0.05 alpha:0.85];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    self.toastLabel.hidden = YES;
    [self.view addSubview:self.toastLabel];

    self.menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.menuButton setImage:[[ALTheme shared] gearIconWhite] forState:UIControlStateNormal];
    self.menuButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.menuButton.layer.cornerRadius = 16;
    self.menuButton.alpha = 0.7;
    self.menuButton.accessibilityLabel = L(@"Stream menu");
    [self.menuButton addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.menuButton];

    self.keyInput = [[ALKeyInputView alloc] initWithFrame:CGRectZero];
    self.keyInput.onText = ^(NSString *text) { [weakSelf typeText:text]; };
    self.keyInput.onBackspace = ^{ [weakSelf pressKeyNamed:@"backspace"]; };
    self.keyInput.accessory = [self keyboardAccessory];
    [self.view addSubview:self.keyInput];

    self.touchMode = [ALSettings touchMode];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:ALSettingsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResign) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (UIView *)keyboardAccessory
{
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    bar.barStyle = UIBarStyleBlack;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    NSMutableArray *items = [NSMutableArray array];
    NSArray *keys = @[ @[ @"Esc", @"escape" ], @[ @"Tab", @"tab" ], @[ @"Ctrl", @"ctrl" ], @[ @"Alt", @"alt" ], @[ @"Win", @"win" ],
                       @[ @"↑", @"up" ], @[ @"↓", @"down" ], @[ @"←", @"left" ], @[ @"→", @"right" ] ];
    if (ALIsPad()) keys = [keys arrayByAddingObjectsFromArray:@[ @[ @"Del", @"delete" ], @[ @"F1", @"f1" ], @[ @"F5", @"f5" ], @[ @"F11", @"f11" ] ]];
    for (NSArray *k in keys) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:k[0] style:UIBarButtonItemStyleBordered target:self action:@selector(accessoryKey:)];
        item.accessibilityLabel = k[1];
        [items addObject:item];
    }
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(hideKeyboard)]];
    bar.items = items;
    return bar;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    UIEdgeInsets safe = ALSafeAreaInsets(self.view);   // the notch (iOS 11+), else zero
    self.gamepad.safeInsets = safe;
    self.spinner.center = CGPointMake(w / 2, h / 2);
    CGSize s = [self.statusLabel.text sizeWithFont:self.statusLabel.font constrainedToSize:CGSizeMake(w - 80, 160)];
    self.statusLabel.frame = CGRectMake((w - s.width - 24) / 2, h / 2 + 40, s.width + 24, s.height + 12);
    self.menuButton.frame = CGRectMake(w / 2 - 16, safe.top + 6, 32, 32);
    CGSize st = [self.statsLabel.text sizeWithFont:self.statsLabel.font constrainedToSize:CGSizeMake(w / 2 - safe.right - 40, 200)];
    self.statsLabel.frame = CGRectMake(w / 2 + 30, safe.top + 6, st.width + 10, st.height + 6);
    CGSize ts = [self.toastLabel.text sizeWithFont:self.toastLabel.font constrainedToSize:CGSizeMake(w - 80, 100)];
    self.toastLabel.frame = CGRectMake((w - ts.width - 30) / 2, safe.top + 50, ts.width + 30, ts.height + 14);
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
// iOS 11 and newer: a swipe from an edge is the game's first (a second one goes to the system), and the home
// indicator fades away over the picture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
#endif

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.startedAt) return;
    self.startedAt = [NSDate date];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self startSession];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)settingsChanged
{
    self.gamepad.controlOpacity = [ALSettings gamepadOpacity];
    self.gamepad.hidden = ![ALSettings touchGamepad];
    self.statsLabel.hidden = ![ALSettings showStats];
    self.touchMode = [ALSettings touchMode];
}

- (void)appWillResign
{
    // the PC keeps running; release every button so nothing stays pressed
    [self releaseAllInput];
}

- (void)appDidEnterBackground
{
    // iOS suspends the app soon: end the connection cleanly (the game keeps running; resume it later)
    [self endWithMessage:L(@"Disconnected because Artlight went to the background. The game is still running on the PC: tap it to resume.") quit:NO];
}

- (void)releaseAllInput
{
    ALGamepadState zero;
    memset(&zero, 0, sizeof(zero));
    [self.session sendGamepad:zero];
    if (self.dragging) { [self.session sendMouseButton:BUTTON_LEFT pressed:NO]; self.dragging = NO; }
    if (self.touchIds.count && self.session.hostSupportsTouch) [self.session sendTouch:LI_TOUCH_EVENT_CANCEL_ALL pointer:0 x:0 y:0];
    [self.touchIds removeAllObjects];
}

#pragma mark - Session

- (void)startSession
{
    self.session = [[ALStreamSession alloc] initWithHost:self.host app:self.app options:[ALStreamOptions fromSettings]];
    self.session.delegate = self;
    [self.session start];
    ALVideoDecoder *decoder = self.session.decoder;
    if (decoder) {
        self.videoView.frameSource = ^CVPixelBufferRef { return [decoder copyLatestFrame]; };
        [self.videoView startDisplayLink];
    }
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(statsTick) userInfo:nil repeats:YES];
}

- (void)streamSession:(ALStreamSession *)session status:(NSString *)status
{
    if (self.gotFirstFrame) return;
    self.statusLabel.text = status;
    [self.view setNeedsLayout];
}

- (void)streamSessionDidConnect:(ALStreamSession *)session
{
    self.statusLabel.text = L(@"Connected, waiting for the first picture…");
    [self.view setNeedsLayout];
    if (!self.gamepad.hidden) {
        LiSendControllerArrivalEvent(0, 0x1, LI_CTYPE_XBOX, 0xFFFF & ~(ALPadGuide), LI_CCAP_ANALOG_TRIGGERS);
    }
}

- (void)streamSession:(ALStreamSession *)session didEnd:(NSString *)message
{
    [self endWithMessage:message quit:NO];
}

- (void)streamSession:(ALStreamSession *)session connectionPoor:(BOOL)poor
{
    if (poor) [self showToast:L(@"The connection is weak: lower the bitrate if the picture breaks up.")];
}

- (void)statsTick
{
    if (!self.gotFirstFrame && self.session.decoder.decodedFrames > 0) {
        self.gotFirstFrame = YES;
        [self.spinner stopAnimating];
        self.statusLabel.hidden = YES;
        ALLog(@"First picture after %.1f s", -[self.startedAt timeIntervalSinceNow]);
        [self showToast:L(@"Tap the gear at the top for the keyboard and the menu.")];
    }
    if (!self.statsLabel.hidden) {
        self.statsLabel.text = [self.session statsText];
        [self.view setNeedsLayout];
    }
}

#pragma mark - Ending

- (void)endWithMessage:(NSString *)message quit:(BOOL)quit
{
    if (self.finished) return;
    self.finished = YES;
    ALLog(@"Stream over: %@", message ?: @"-");
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.keyInput resignFirstResponder];
    [self releaseAllInput];
    [self.videoView stopDisplayLink];
    [self.session stop];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    if (quit) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = L(@"Quitting the game on the PC…");
        [self.spinner startAnimating];
        [self.view setNeedsLayout];
        [ALGameStream quitAppOnHost:self.host completion:^(NSError *error) {
            if (self.onFinished) self.onFinished(error.localizedDescription);
        }];
        return;
    }
    if (self.onFinished) self.onFinished(message);
}

#pragma mark - Menu

- (void)showMenu
{
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *actions = [NSMutableArray array];
    __weak ALStreamViewController *weakSelf = self;
    [titles addObject:L(@"Keyboard")];
    [actions addObject:^{ [weakSelf.keyInput becomeFirstResponder]; }];
    [titles addObject:self.gamepad.hidden ? L(@"Show gamepad") : L(@"Hide gamepad")];
    [actions addObject:^{ [ALSettings setTouchGamepad:weakSelf.gamepad.hidden]; }];
    NSArray *modeNames = @[ L(@"Touch: trackpad"), L(@"Touch: direct pointer"), L(@"Touch: touchscreen") ];
    [titles addObject:modeNames[self.touchMode]];
    [actions addObject:^{
        ALTouchMode next = (ALTouchMode)((weakSelf.touchMode + 1) % 3);
        [ALSettings setTouchMode:next];
        [weakSelf showToast:@[ L(@"Trackpad: drag to move the pointer, tap to click, tap twice and hold to drag, two fingers for the right button and scrolling."),
                               L(@"Direct pointer: the pointer follows your finger; tap to click, two fingers for the right button."),
                               L(@"Touchscreen: the PC gets real touches (Windows touch).") ][next]];
    }];
    [titles addObject:self.statsLabel.hidden ? L(@"Show statistics") : L(@"Hide statistics")];
    [actions addObject:^{ [ALSettings setShowStats:weakSelf.statsLabel.hidden]; }];
    [titles addObject:L(@"Send Escape")];
    [actions addObject:^{ [weakSelf pressKeyNamed:@"escape"]; }];
    [titles addObject:L(@"Send the Windows key")];
    [actions addObject:^{ [weakSelf pressKeyNamed:@"win"]; }];
    [titles addObject:L(@"Send Alt+Tab")];
    [actions addObject:^{ ALKeyStroke k = [ALInput keyNamed:@"tab"]; k.modifiers = ALModAlt; [weakSelf.session tapKey:k]; }];
    if (self.host.serverCommands.count && [self.host hasPermission:ALPermServerCommand]) {
        [titles addObject:L(@"PC commands…")];
        [actions addObject:^{ [weakSelf showServerCommands]; }];
    }
    if (self.host.isApollo && [self.host hasPermission:ALPermClipboardSet]) {
        [titles addObject:L(@"Send the clipboard to the PC")];
        [actions addObject:^{ [weakSelf sendClipboard]; }];
    }
    if (self.host.isApollo && [self.host hasPermission:ALPermClipboardRead]) {
        [titles addObject:L(@"Get the PC's clipboard")];
        [actions addObject:^{ [weakSelf fetchClipboard]; }];
    }
    [titles addObject:L(@"Disconnect (the game keeps running)")];
    [actions addObject:^{ [weakSelf endWithMessage:nil quit:NO]; }];
    [titles addObject:L(@"Quit game")];
    [actions addObject:^{ [weakSelf endWithMessage:nil quit:YES]; }];
    [ALAlerts sheetWithTitle:self.app.title buttons:titles destructive:(NSInteger)titles.count - 1 from:self rect:self.menuButton.frame handler:^(NSInteger index) {
        if (index >= 0 && index < (NSInteger)actions.count) ((dispatch_block_t)actions[(NSUInteger)index])();
    }];
}

- (void)showServerCommands
{
    NSArray *commands = self.host.serverCommands;
    [ALAlerts sheetWithTitle:L(@"PC commands") buttons:commands destructive:-1 from:self rect:self.menuButton.frame handler:^(NSInteger index) {
        if (index < 0) return;
        BOOL sent = [self.session runServerCommand:index];
        [self showToast:sent ? [NSString stringWithFormat:L(@"Sent: %@"), commands[(NSUInteger)index]] : L(@"This PC does not take commands.")];
    }];
}

- (void)sendClipboard
{
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (!text.length) { [self showToast:L(@"The clipboard of this device is empty.")]; return; }
    [ALGameStream sendClipboard:text toHost:self.host completion:^(NSError *error) {
        [self showToast:error ? error.localizedDescription : L(@"The clipboard is on the PC now (paste it there).")];
    }];
}

- (void)fetchClipboard
{
    [ALGameStream fetchClipboardFromHost:self.host completion:^(NSString *text, NSError *error) {
        if (!text) { [self showToast:error.localizedDescription]; return; }
        [UIPasteboard generalPasteboard].string = text;
        [self showToast:text.length ? L(@"The PC's clipboard was copied to this device.") : L(@"The PC's clipboard is empty.")];
    }];
}

- (void)showToast:(NSString *)text
{
    if (!text.length) return;
    self.toastLabel.text = text;
    self.toastLabel.hidden = NO;
    [self.view setNeedsLayout];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:3.5];
}

- (void)hideToast
{
    self.toastLabel.hidden = YES;
}

#pragma mark - Keyboard

- (void)pressKeyNamed:(NSString *)name
{
    ALKeyStroke k = [ALInput keyNamed:name];
    k.modifiers |= self.stickyModifiers;
    self.stickyModifiers = 0;
    [self.session tapKey:k];
}

- (void)typeText:(NSString *)text
{
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        ALKeyStroke k;
        if ([ALInput keyStroke:&k forCharacter:c]) {
            k.modifiers |= self.stickyModifiers;
            self.stickyModifiers = 0;
            [self.session tapKey:k];
        } else {
            // a character no US key types (č, ř, emoji...): the PC gets it as text
            NSRange r = [text rangeOfComposedCharacterSequenceAtIndex:i];
            [self.session sendText:[text substringWithRange:r]];
            i = r.location + r.length - 1;
        }
    }
}

- (void)accessoryKey:(UIBarButtonItem *)item
{
    NSString *name = item.accessibilityLabel;
    if ([name isEqualToString:@"ctrl"] || [name isEqualToString:@"alt"] || [name isEqualToString:@"win"]) {
        uint8_t bit = [name isEqualToString:@"ctrl"] ? ALModCtrl : [name isEqualToString:@"alt"] ? ALModAlt : ALModMeta;
        if ([name isEqualToString:@"win"] && !(self.stickyModifiers & bit)) {
            // Win alone opens the Start menu; Win held with the next key is a shortcut. A second tap sends it alone.
            self.stickyModifiers |= bit;
            [self showToast:L(@"Win is held for the next key (tap Win again to send it alone).")];
            return;
        }
        if ([name isEqualToString:@"win"]) { self.stickyModifiers &= ~bit; [self pressKeyNamed:@"win"]; return; }
        self.stickyModifiers ^= bit;
        [self showToast:(self.stickyModifiers & bit) ? [NSString stringWithFormat:L(@"%@ is held for the next key."), item.title] : [NSString stringWithFormat:L(@"%@ released."), item.title]];
        return;
    }
    [self pressKeyNamed:name];
}

- (void)hideKeyboard
{
    [self.keyInput resignFirstResponder];
}

#pragma mark - Touch on the picture

// The picture's rectangle in the view (letterboxed to the stream's aspect)
- (CGRect)videoRect
{
    CGRect b = self.view.bounds;
    CGFloat sw = self.session.options.width > 0 ? self.session.options.width : 16, sh = self.session.options.height > 0 ? self.session.options.height : 9;
    CGFloat scale = MIN(b.size.width / sw, b.size.height / sh);
    CGFloat w = sw * scale, h = sh * scale;
    return CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
}

- (void)movePointerTo:(CGPoint)p
{
    CGRect r = [self videoRect];
    CGFloat x = MIN(MAX(p.x - r.origin.x, 0), r.size.width), y = MIN(MAX(p.y - r.origin.y, 0), r.size.height);
    [self.session sendMousePositionX:(short)x y:(short)y referenceWidth:(short)r.size.width height:(short)r.size.height];
}

- (void)surfaceTouches:(NSSet *)touches event:(UIEvent *)event phase:(int)phase
{
    if (!self.session.isConnected) return;
    if (self.keyInput.isFirstResponder && phase == 0) [self.keyInput resignFirstResponder];
    ALTouchMode mode = self.touchMode;
    if (mode == ALTouchModeTouchscreen && ![self.session hostSupportsTouch]) mode = ALTouchModeDirect;
    if (mode == ALTouchModeTouchscreen) { [self touchscreenTouches:touches phase:phase]; return; }
    NSSet *all = [event touchesForView:self.touchSurface];
    NSUInteger fingers = 0;
    for (UITouch *t in all) if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) fingers++;
    UITouch *touch = [touches anyObject];
    CGPoint p = [touch locationInView:self.touchSurface];
    NSTimeInterval now = touch.timestamp;
    if (phase == 0) {
        if (fingers >= 2) { self.twoFinger = YES; self.lastPoint = p; return; }
        self.twoFinger = NO;
        self.moved = NO;
        self.startPoint = p;
        self.lastPoint = p;
        self.touchStart = now;
        self.remainderX = self.remainderY = self.scrollRemainder = 0;
        if (mode == ALTouchModeDirect) {
            [self movePointerTo:p];
        } else if (now - self.lastTapEnd < 0.3) {
            // tap, then touch again and hold: drag with the left button down
            self.dragging = YES;
            [self.session sendMouseButton:BUTTON_LEFT pressed:YES];
        }
        return;
    }
    if (phase == 1) {
        CGFloat dx = p.x - self.lastPoint.x, dy = p.y - self.lastPoint.y;
        if (hypot(p.x - self.startPoint.x, p.y - self.startPoint.y) > 8) self.moved = YES;
        if (self.twoFinger) {
            // two fingers moving: the wheel
            self.scrollRemainder += -dy * 3;
            short amount = (short)self.scrollRemainder;
            if (abs(amount) >= 20) { [self.session sendScroll:amount]; self.scrollRemainder -= amount; }
            self.lastPoint = p;
            return;
        }
        if (mode == ALTouchModeDirect) {
            if (self.moved && !self.dragging) { self.dragging = YES; [self.session sendMouseButton:BUTTON_LEFT pressed:YES]; }
            [self movePointerTo:p];
        } else {
            CGFloat sens = [ALSettings mouseSensitivity] * [UIScreen mainScreen].scale;
            CGFloat fx = dx * sens + self.remainderX, fy = dy * sens + self.remainderY;
            short ix = (short)fx, iy = (short)fy;
            self.remainderX = fx - ix;
            self.remainderY = fy - iy;
            [self.session sendMouseMoveDX:ix dy:iy];
        }
        self.lastPoint = p;
        return;
    }
    // ended or cancelled
    if (fingers > 0) return;   // other fingers still down
    if (self.twoFinger) {
        if (!self.moved && phase == 2 && now - self.touchStart < 0.4) {
            [self.session sendMouseButton:BUTTON_RIGHT pressed:YES];
            [self.session sendMouseButton:BUTTON_RIGHT pressed:NO];
        }
        self.twoFinger = NO;
        return;
    }
    if (self.dragging) {
        [self.session sendMouseButton:BUTTON_LEFT pressed:NO];
        self.dragging = NO;
        return;
    }
    if (phase == 2 && !self.moved && now - self.touchStart < 0.35) {
        if (mode == ALTouchModeDirect) [self movePointerTo:p];
        [self.session sendMouseButton:BUTTON_LEFT pressed:YES];
        [self.session sendMouseButton:BUTTON_LEFT pressed:NO];
        self.lastTapEnd = now;
    }
}

- (void)touchscreenTouches:(NSSet *)touches phase:(int)phase
{
    CGRect r = [self videoRect];
    for (UITouch *t in touches) {
        NSNumber *key = @((uintptr_t)t);
        CGPoint p = [t locationInView:self.touchSurface];
        float x = (float)MIN(MAX((p.x - r.origin.x) / r.size.width, 0), 1), y = (float)MIN(MAX((p.y - r.origin.y) / r.size.height, 0), 1);
        if (phase == 0) {
            uint32_t pid = ++self.nextTouchId;
            self.touchIds[key] = @(pid);
            [self.session sendTouch:LI_TOUCH_EVENT_DOWN pointer:pid x:x y:y];
        } else {
            NSNumber *pid = self.touchIds[key];
            if (!pid) continue;
            if (phase == 1) [self.session sendTouch:LI_TOUCH_EVENT_MOVE pointer:[pid unsignedIntValue] x:x y:y];
            else {
                [self.session sendTouch:phase == 2 ? LI_TOUCH_EVENT_UP : LI_TOUCH_EVENT_CANCEL pointer:[pid unsignedIntValue] x:x y:y];
                [self.touchIds removeObjectForKey:key];
            }
        }
    }
}

#pragma mark - Debug

- (void)debugCommand:(NSString *)command params:(NSDictionary *)params
{
    if ([command isEqualToString:@"key"]) {
        [self pressKeyNamed:params[@"name"] ?: @"escape"];
    } else if ([command isEqualToString:@"type"]) {
        [self typeText:params[@"text"] ?: @""];
    } else if ([command isEqualToString:@"pad"]) {
        ALGamepadState s;
        memset(&s, 0, sizeof(s));
        s.buttons = (uint16_t)strtoul([params[@"buttons"] ?: @"0" UTF8String], NULL, 0);
        s.leftX = (int16_t)[params[@"lx"] intValue];
        s.leftY = (int16_t)[params[@"ly"] intValue];
        [self.session sendGamepad:s];
        double hold = [params[@"hold"] doubleValue] ?: 0.2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ALGamepadState zero;
            memset(&zero, 0, sizeof(zero));
            [self.session sendGamepad:zero];
        });
    } else if ([command isEqualToString:@"mouse"]) {
        [self.session sendMouseMoveDX:(short)[params[@"dx"] intValue] dy:(short)[params[@"dy"] intValue]];
        if ([params[@"click"] boolValue]) { [self.session sendMouseButton:BUTTON_LEFT pressed:YES]; [self.session sendMouseButton:BUTTON_LEFT pressed:NO]; }
    } else if ([command isEqualToString:@"keyframe"]) {
        [self.session requestKeyframe];
    } else if ([command isEqualToString:@"disconnect"]) {
        [self endWithMessage:nil quit:NO];
    } else if ([command isEqualToString:@"quit"]) {
        [self endWithMessage:nil quit:YES];
    }
}

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"%@ firstFrame=%d drawn=%llu touchMode=%d stats={%@}", [self.session debugDescription], self.gotFirstFrame,
            self.videoView.framesDrawn, (int)self.touchMode, [[self.session statsText] stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]];
}

@end
