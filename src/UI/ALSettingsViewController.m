#import "ALSettingsViewController.h"
#import "ALChoiceViewController.h"
#import "ALExternalOpen.h"
#import "ALAlerts.h"
#import "ALGameStream.h"
#import "ALCrypto.h"
#import "ALNvHTTP.h"
#import "ALSettings.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALCommon.h"

enum { SecStream, SecApollo, SecControls, SecAppearance, SecDevice, SecAbout, SecCount };
enum { RowResolution, RowFps, RowBitrate, RowSops, RowHostAudio, RowStats, StreamRowCount };
enum { RowGamepad, RowOpacity, RowTouchMode, RowSensitivity, ControlsRowCount };
enum { RowVersion, RowSource, RowLicenses, RowSupport, AboutRowCount };

@implementation ALSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[ALTheme shared] applyToTableView:self.tableView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged) name:ALThemeDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)themeChanged
{
    [[ALTheme shared] applyToTableView:self.tableView];
    [self.tableView reloadData];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - Options

- (NSArray *)resolutionOptions
{
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    int nw = (int)(MAX(b.size.width, b.size.height) * scale), nh = (int)(MIN(b.size.width, b.size.height) * scale);
    if (nw > 1920) { nw = (int)(nw / scale); nh = (int)(nh / scale); }
    return @[ @{ @"key": @"1024x768", @"title": [NSString stringWithFormat:@"1024x768 (%@)", L(@"recommended")] },
              @{ @"key": @"native", @"title": [NSString stringWithFormat:L(@"Screen (%dx%d)"), nw / 2 * 2, nh / 2 * 2] },
              @{ @"key": @"854x480", @"title": @"854x480" },
              @{ @"key": @"960x540", @"title": @"960x540" },
              @{ @"key": @"1280x720", @"title": @"1280x720" },
              @{ @"key": @"1280x800", @"title": @"1280x800" },
              @{ @"key": @"1366x768", @"title": @"1366x768" },
              @{ @"key": @"1600x900", @"title": [NSString stringWithFormat:@"1600x900 (%@)", L(@"heavy")] },
              @{ @"key": @"1920x1080", @"title": [NSString stringWithFormat:@"1920x1080 (%@)", L(@"heavy")] } ];
}

- (NSArray *)touchModeTitles
{
    return @[ L(@"Trackpad"), L(@"Direct pointer"), L(@"Touchscreen") ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SecCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case SecStream: return StreamRowCount;
        case SecApollo: return 1;
        case SecControls: return ControlsRowCount;
        case SecAppearance: return 1;
        case SecDevice: return 2;
        case SecAbout: return AboutRowCount;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case SecStream: return L(@"Stream");
        case SecApollo: return L(@"Apollo");
        case SecControls: return L(@"Controls");
        case SecAppearance: return L(@"Appearance");
        case SecDevice: return L(@"This device");
        case SecAbout: return L(@"About");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case SecStream: return L(@"1024x768 at 30 fps is what the iPad 2 decodes smoothly. 60 fps and bigger pictures need more decoding power than older devices have; a lower bitrate helps a weak Wi-Fi.");
        case SecApollo: return L(@"Apollo can make a virtual monitor with exactly this device's resolution for the stream (Windows PCs with Apollo's display driver).");
        case SecControls: return L(@"During a stream, tap the gear at the top for the keyboard, the touch mode and the menu.");
        case SecDevice: return L(@"A new certificate makes every PC forget this device: you will have to pair again.");
        case SecAbout: return L(@"Artlight is free software (GPLv3) built on moonlight-common-c. It is not affiliated with Moonlight, Artemis, Sunshine, Apollo or NVIDIA.");
    }
    return nil;
}

- (UISlider *)sliderWithMin:(float)min max:(float)max value:(float)value tag:(NSInteger)tag
{
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, ALIsPad() ? 240 : 140, 30)];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = value;
    s.tag = tag;
    s.continuous = NO;
    [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UISwitch *)switchOn:(BOOL)on tag:(NSInteger)tag
{
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectZero];
    s.on = on;
    s.tag = tag;
    [s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    [[ALTheme shared] styleCell:cell];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == SecStream) {
        switch (r) {
            case RowResolution: {
                cell.textLabel.text = L(@"Resolution");
                NSString *key = [ALSettings streamResolution];
                NSString *title = key;
                for (NSDictionary *o in [self resolutionOptions]) if ([o[@"key"] isEqualToString:key]) title = o[@"title"];
                cell.detailTextLabel.text = title;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            case RowFps:
                cell.textLabel.text = L(@"Frame rate");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld fps", (long)[ALSettings streamFps]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowBitrate: {
                double mbps = [ALSettings bitrateKbps] / 1000.0;
                cell.textLabel.text = [NSString stringWithFormat:@"%@ %.1f Mb/s", L(@"Bitrate"), mbps];
                cell.accessoryView = [self sliderWithMin:1 max:30 value:(float)mbps tag:100 + RowBitrate];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            }
            case RowSops:
                cell.textLabel.text = L(@"Adjust game settings");
                cell.accessoryView = [self switchOn:[ALSettings optimizeGameSettings] tag:100 + RowSops];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowHostAudio:
                cell.textLabel.text = L(@"Play sound on the PC too");
                cell.accessoryView = [self switchOn:[ALSettings playAudioOnHost] tag:100 + RowHostAudio];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowStats:
                cell.textLabel.text = L(@"Statistics overlay");
                cell.accessoryView = [self switchOn:[ALSettings showStats] tag:100 + RowStats];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
        }
    } else if (s == SecApollo) {
        cell.textLabel.text = L(@"Virtual display");
        cell.accessoryView = [self switchOn:[ALSettings virtualDisplay] tag:150];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (s == SecControls) {
        switch (r) {
            case RowGamepad:
                cell.textLabel.text = L(@"On-screen gamepad");
                cell.accessoryView = [self switchOn:[ALSettings touchGamepad] tag:200 + RowGamepad];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowOpacity:
                cell.textLabel.text = L(@"Gamepad opacity");
                cell.accessoryView = [self sliderWithMin:0.2 max:0.9 value:[ALSettings gamepadOpacity] tag:200 + RowOpacity];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowTouchMode:
                cell.textLabel.text = L(@"Touch on the picture");
                cell.detailTextLabel.text = [self touchModeTitles][[ALSettings touchMode]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowSensitivity:
                cell.textLabel.text = L(@"Pointer speed");
                cell.accessoryView = [self sliderWithMin:0.5 max:3 value:[ALSettings mouseSensitivity] tag:200 + RowSensitivity];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
        }
    } else if (s == SecAppearance) {
        cell.textLabel.text = L(@"Dark theme");
        cell.accessoryView = [self switchOn:[ALTheme shared].isDark tag:300];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (s == SecDevice) {
        if (r == 0) {
            cell.textLabel.text = L(@"Name on the PC");
            cell.detailTextLabel.text = [ALGameStream deviceName];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = L(@"Make a new certificate");
            cell.textLabel.textColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        }
    } else if (s == SecAbout) {
        switch (r) {
            case RowVersion:
                cell.textLabel.text = L(@"Version");
                cell.detailTextLabel.text = [ALUtils appVersion];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowSource:
                cell.textLabel.text = L(@"Source code");
                cell.detailTextLabel.text = @"github.com/samcejko";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowLicenses:
                cell.textLabel.text = L(@"Open-source licenses");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowSupport:
                cell.textLabel.text = L(@"Support the development");
                cell.detailTextLabel.text = @"ko-fi.com/samcejko";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
        }
    }
    return cell;
}

- (void)sliderChanged:(UISlider *)slider
{
    if (slider.tag == 100 + RowBitrate) [ALSettings setBitrateKbps:(NSInteger)lround(slider.value * 2) * 500];
    else if (slider.tag == 200 + RowOpacity) [ALSettings setGamepadOpacity:slider.value];
    else if (slider.tag == 200 + RowSensitivity) [ALSettings setMouseSensitivity:slider.value];
    [ALSettings save];
    [self.tableView reloadData];
}

- (void)switchChanged:(UISwitch *)sw
{
    switch (sw.tag) {
        case 100 + RowSops: [ALSettings setOptimizeGameSettings:sw.on]; break;
        case 100 + RowHostAudio: [ALSettings setPlayAudioOnHost:sw.on]; break;
        case 100 + RowStats: [ALSettings setShowStats:sw.on]; break;
        case 150: [ALSettings setVirtualDisplay:sw.on]; break;
        case 200 + RowGamepad: [ALSettings setTouchGamepad:sw.on]; break;
        case 300: [[ALTheme shared] setDark:sw.on]; break;
    }
    [ALSettings save];
}

- (void)pushChoice:(NSArray *)titles subtitles:(NSArray *)subtitles selected:(NSInteger)selected title:(NSString *)title completion:(void (^)(NSInteger))completion
{
    ALChoiceViewController *c = [[ALChoiceViewController alloc] initWithStyle:UITableViewStyleGrouped];
    c.title = title;
    c.titles = titles;
    c.subtitles = subtitles;
    c.selectedIndex = selected;
    c.completion = completion;
    [self.navigationController pushViewController:c animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == SecStream && r == RowResolution) {
        NSArray *options = [self resolutionOptions];
        NSMutableArray *titles = [NSMutableArray array];
        NSInteger selected = 0;
        for (NSUInteger i = 0; i < options.count; i++) {
            [titles addObject:options[i][@"title"]];
            if ([options[i][@"key"] isEqualToString:[ALSettings streamResolution]]) selected = (NSInteger)i;
        }
        [self pushChoice:titles subtitles:nil selected:selected title:L(@"Resolution") completion:^(NSInteger index) {
            [ALSettings setStreamResolution:options[(NSUInteger)index][@"key"]];
            [ALSettings save];
        }];
    } else if (s == SecStream && r == RowFps) {
        [self pushChoice:@[ @"30 fps", @"60 fps" ] subtitles:@[ L(@"Smooth on the iPad 2 and on Wi-Fi"), L(@"Smoother motion; needs a newer device") ]
                selected:[ALSettings streamFps] == 60 ? 1 : 0 title:L(@"Frame rate") completion:^(NSInteger index) {
            [ALSettings setStreamFps:index == 1 ? 60 : 30];
            [ALSettings save];
        }];
    } else if (s == SecControls && r == RowTouchMode) {
        [self pushChoice:[self touchModeTitles]
               subtitles:@[ L(@"Drag to move the pointer, tap to click, two fingers for the right button and the wheel"),
                            L(@"The pointer jumps to your finger; tap to click there"),
                            L(@"Real touches on a Windows PC (Sunshine and Apollo)") ]
                selected:[ALSettings touchMode] title:L(@"Touch on the picture") completion:^(NSInteger index) {
            [ALSettings setTouchMode:(ALTouchMode)index];
            [ALSettings save];
        }];
    } else if (s == SecDevice && r == 1) {
        [ALAlerts alertWithTitle:L(@"Make a new certificate") message:L(@"Every PC will forget this device and you will have to pair again. Continue?")
                          cancel:L(@"Cancel") buttons:@[ L(@"Make new") ] style:UIAlertViewStyleDefault handler:^(UIAlertView *a, NSInteger index) {
            if (index == a.cancelButtonIndex) return;
            [[ALIdentity shared] reset];
            ALNvResetTLSIdentity();
            for (ALHost *h in [ALHostStore shared].hosts) { h.paired = NO; h.serverCertificate = nil; [[ALHostStore shared] hostChanged:h]; }
            [[ALIdentity shared] prepareWithCompletion:^(NSError *error) {
                [ALUtils alertWithTitle:L(@"Make a new certificate") message:error ? error.localizedDescription : L(@"Done. Pair your PCs again.")];
            }];
        }];
    } else if (s == SecAbout && r == RowSource) {
        [ALExternalOpen presentOpenInForURL:[NSURL URLWithString:@"https://github.com/samcejko/artlight-ios6"] from:self anchor:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (s == SecAbout && r == RowSupport) {
        [ALExternalOpen presentOpenInForURL:[NSURL URLWithString:@"https://ko-fi.com/samcejko"] from:self anchor:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (s == SecAbout && r == RowLicenses) {
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = L(@"Licenses");
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont systemFontOfSize:12];
        NSMutableString *text = [NSMutableString string];
        NSString *dir = [[NSBundle mainBundle] pathForResource:@"licenses" ofType:nil];
        for (NSString *name in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *content = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
            if (content) [text appendFormat:@"==== %@ ====\n\n%@\n\n", name, content];
        }
        tv.text = text.length ? text : L(@"The license texts are added by the build.");
        [vc.view addSubview:tv];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

@end
