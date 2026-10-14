#import "ALHostsViewController.h"
#import "ALAppsViewController.h"
#import "ALAlerts.h"
#import "ALGameStream.h"
#import "ALDiscovery.h"
#import "ALCrypto.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALModern.h"
#import "ALCommon.h"

@interface ALHostsViewController ()
@property (nonatomic, strong) ALTask *pairTask;
@property (nonatomic, strong) UIAlertView *pairAlert;
@property (nonatomic, strong) UIView *identityBanner;
@end

@implementation ALHostsViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[ALTheme shared] applyToTableView:self.tableView];
    self.tableView.rowHeight = 64;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addTapped)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshTapped)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hostsChanged:) name:ALHostsDidChangeNotification object:nil];
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
    [[ALDiscovery shared] start];
    [self prepareIdentity];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)themeChanged
{
    [[ALTheme shared] applyToTableView:self.tableView];
    [self.tableView reloadData];
}

- (void)hostsChanged:(NSNotification *)note
{
    if (self.isViewLoaded) [self.tableView reloadData];
}

#pragma mark - Identity

- (void)prepareIdentity
{
    ALIdentity *identity = [ALIdentity shared];
    if (identity.isReady) return;
    [self.tableView reloadData];
    [identity prepareWithCompletion:^(NSError *error) {
        [self.tableView reloadData];
        if (error) [ALUtils alertWithTitle:L(@"Client certificate") message:error.localizedDescription];
    }];
}

#pragma mark - Table

- (NSArray *)hosts { return [ALHostStore shared].hosts; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return MAX(1, (NSInteger)[self hosts].count);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? L(@"Gaming PCs") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        if (![ALIdentity shared].isReady) return L(@"Preparing this device's certificate for pairing (only once; it can take up to a minute)…");
        return L(@"PCs running Sunshine or Apollo on this network appear here by themselves. Tap one to pair with it or to see its games.");
    }
    return L(@"Artlight streams games from your own PC. Install Sunshine or Apollo on the PC first.");
}

- (NSString *)statusTextForHost:(ALHost *)host
{
    NSMutableArray *parts = [NSMutableArray array];
    switch (host.state) {
        case ALHostStateOnline: [parts addObject:L(@"Online")]; break;
        case ALHostStateOffline: [parts addObject:L(@"Offline")]; break;
        case ALHostStateChecking: [parts addObject:L(@"Checking…")]; break;
        default: [parts addObject:L(@"Unknown")]; break;
    }
    if (host.state == ALHostStateOnline || host.serverCertificate) [parts addObject:host.paired ? L(@"paired") : L(@"not paired")];
    if (host.state == ALHostStateOnline && host.isBusy) {
        ALApp *running = [host appWithId:host.currentGameId];
        [parts addObject:running.title.length ? [NSString stringWithFormat:L(@"playing %@"), running.title] : L(@"a game is running")];
    }
    if (host.isApollo) [parts addObject:@"Apollo"];
    else if (host.isSunshine) [parts addObject:@"Sunshine"];
    NSString *address = [host displayAddress];
    if (address.length) [parts addObject:address];
    return [parts componentsJoinedByString:@" · "];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    ALTheme *theme = [ALTheme shared];
    [theme styleCell:cell];
    NSArray *hosts = [self hosts];
    if (indexPath.section == 0) {
        if (!hosts.count) {
            cell.textLabel.text = L(@"Looking for PCs…");
            cell.textLabel.textColor = [theme secondaryTextColor];
            cell.detailTextLabel.text = L(@"Tap + to add one by its address.");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
            [spinner startAnimating];
            cell.accessoryView = spinner;
            return cell;
        }
        ALHost *host = hosts[(NSUInteger)indexPath.row];
        cell.textLabel.text = host.name.length ? host.name : [host displayAddress];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
        cell.detailTextLabel.text = [self statusTextForHost:host];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.imageView.image = [theme computerIconOnline:host.state == ALHostStateOnline paired:host.paired];
        cell.accessoryType = host.paired && host.state == ALHostStateOnline ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        if (host.state == ALHostStateChecking && !host.lastSeen) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        }
    } else {
        cell.textLabel.text = L(@"Add a PC by its address…");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [theme linkColor];
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 && [self hosts].count > 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return L(@"Remove");
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (style != UITableViewCellEditingStyleDelete) return;
    ALHost *host = [self hosts][(NSUInteger)indexPath.row];
    [[ALHostStore shared] removeHost:host];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { [self addTapped]; return; }
    NSArray *hosts = [self hosts];
    if (!hosts.count) return;
    ALHost *host = hosts[(NSUInteger)indexPath.row];
    CGRect rect = [tableView convertRect:[tableView rectForRowAtIndexPath:indexPath] toView:self.view];
    if (host.paired && host.state == ALHostStateOnline) { [self openHost:host]; return; }
    [self showActionsForHost:host rect:rect];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath
{
    [self tableView:tableView didSelectRowAtIndexPath:indexPath];
}

#pragma mark - Actions

- (void)refreshTapped
{
    [[ALDiscovery shared] refreshNow];
}

- (void)showActionsForHost:(ALHost *)host rect:(CGRect)rect
{
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *actions = [NSMutableArray array];
    __weak ALHostsViewController *weakSelf = self;
    if (host.state == ALHostStateOnline && !host.paired) {
        [titles addObject:L(@"Pair with a PIN")];
        [actions addObject:^{ [weakSelf startPinPairing:host]; }];
        [titles addObject:L(@"Pair with a one-time PIN (Apollo)")];
        [actions addObject:^{ [weakSelf askOtpForHost:host]; }];
    }
    if (host.state == ALHostStateOnline && host.paired) {
        [titles addObject:L(@"Show games")];
        [actions addObject:^{ [weakSelf openHost:host]; }];
    }
    if (host.state != ALHostStateOnline) {
        [titles addObject:L(@"Check again")];
        [actions addObject:^{ [ALGameStream refreshHost:host completion:nil]; }];
        if (host.mac.length) {
            [titles addObject:L(@"Wake up the PC")];
            [actions addObject:^{
                BOOL sent = [ALGameStream wakeHost:host];
                [ALUtils alertWithTitle:L(@"Wake up the PC") message:sent ? L(@"The wake-up signal was sent. The PC should answer within a minute (Wake-on-LAN must be on in its BIOS and network card).") : L(@"The PC's network address is not known yet.")];
            }];
        }
    }
    [titles addObject:L(@"Details")];
    [actions addObject:^{ [weakSelf showDetailsForHost:host]; }];
    if (host.paired) {
        [titles addObject:L(@"Unpair")];
        [actions addObject:^{ [ALGameStream unpairHost:host completion:nil]; }];
    }
    [titles addObject:L(@"Remove from the list")];
    [actions addObject:^{ [[ALHostStore shared] removeHost:host]; }];
    NSInteger destructive = (NSInteger)titles.count - 1;
    [ALAlerts sheetWithTitle:host.name ?: [host displayAddress] buttons:titles destructive:destructive from:self rect:rect handler:^(NSInteger index) {
        if (index >= 0 && index < (NSInteger)actions.count) ((dispatch_block_t)actions[(NSUInteger)index])();
    }];
}

- (void)showDetailsForHost:(ALHost *)host
{
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:L(@"Address: %@\n"), [[host candidateAddresses] componentsJoinedByString:@", "]];
    if (host.appVersion) [text appendFormat:L(@"Host version: %@\n"), host.appVersion];
    if (host.mac.length) [text appendFormat:L(@"MAC address: %@\n"), host.mac];
    [text appendFormat:L(@"Paired: %@\n"), host.paired ? L(@"yes") : L(@"no")];
    if (host.permission >= 0) {
        NSMutableArray *perms = [NSMutableArray array];
        struct { long long bit; NSString *name; } list[] = {
            { ALPermList, L(@"list apps") }, { ALPermView, L(@"view") }, { ALPermLaunch, L(@"launch") },
            { ALPermInputController, L(@"gamepad") }, { ALPermInputTouch, L(@"touch") }, { ALPermInputMouse, L(@"mouse") },
            { ALPermInputKeyboard, L(@"keyboard") }, { ALPermClipboardSet, L(@"clipboard to PC") },
            { ALPermClipboardRead, L(@"clipboard from PC") }, { ALPermServerCommand, L(@"commands") } };
        for (size_t i = 0; i < sizeof(list) / sizeof(list[0]); i++) if (host.permission & list[i].bit) [perms addObject:list[i].name];
        [text appendFormat:L(@"Allowed (Apollo): %@\n"), perms.count ? [perms componentsJoinedByString:@", "] : L(@"nothing")];
    }
    if (host.serverCommands.count) [text appendFormat:L(@"PC commands: %@\n"), [host.serverCommands componentsJoinedByString:@", "]];
    if (host.virtualDisplayCapable) [text appendFormat:L(@"Virtual display: %@\n"), host.virtualDisplayReady ? L(@"ready") : L(@"driver not ready")];
    if (host.lastError.length && host.state != ALHostStateOnline) [text appendFormat:L(@"Last error: %@\n"), host.lastError];
    [ALUtils alertWithTitle:host.name ?: L(@"PC") message:text];
}

- (void)addTapped
{
    __weak ALHostsViewController *weakSelf = self;
    UIAlertView *alert = [ALAlerts alertWithTitle:L(@"Add a PC") message:L(@"The PC's IP address or name (as shown in Sunshine or Apollo), optionally with :port.")
                                           cancel:L(@"Cancel") buttons:@[ L(@"Add") ] style:UIAlertViewStylePlainTextInput handler:^(UIAlertView *a, NSInteger index) {
        if (index == a.cancelButtonIndex) return;
        NSString *text = [[a textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length) [weakSelf addHostWithAddress:text];
    }];
    UITextField *field = [alert textFieldAtIndex:0];
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.placeholder = @"192.168.1.10";
}

- (void)addHostWithAddress:(NSString *)address
{
    UIAlertView *progress = [ALAlerts alertWithTitle:L(@"Add a PC") message:[NSString stringWithFormat:L(@"Contacting %@…"), address] cancel:nil buttons:nil
                                               style:UIAlertViewStyleDefault handler:nil];
    [ALGameStream probeAddress:address manual:YES completion:^(ALHost *host, NSError *error) {
        [progress dismissWithClickedButtonIndex:0 animated:YES];
        if (!host) {
            [ALUtils alertWithTitle:L(@"Add a PC") message:[NSString stringWithFormat:L(@"%@\n\nIs Sunshine or Apollo running on the PC, and does its firewall allow it?"), error.localizedDescription ?: @""]];
            return;
        }
        [self.tableView reloadData];
        if (!host.paired) {
            CGRect rect = CGRectMake(self.view.bounds.size.width / 2 - 1, 80, 2, 2);
            [self showActionsForHost:host rect:rect];
        }
    }];
}

#pragma mark - Pairing

- (void)startPinPairing:(ALHost *)host
{
    if (![ALIdentity shared].isReady) {
        [ALUtils alertWithTitle:L(@"Pairing") message:L(@"This device's certificate is still being made. Try again in a moment.")];
        return;
    }
    NSString *pin = [ALGameStream randomPin];
    [self pairHost:host pin:pin otpPassphrase:nil];
}

- (void)askOtpForHost:(ALHost *)host
{
    __weak ALHostsViewController *weakSelf = self;
    UIAlertView *alert = [ALAlerts alertWithTitle:L(@"One-time PIN (Apollo)")
                                          message:L(@"In Apollo's web page on the PC, open \"PIN\", choose a passphrase and create a one-time PIN, then type both here.")
                                           cancel:L(@"Cancel") buttons:@[ L(@"Pair") ] style:UIAlertViewStyleLoginAndPasswordInput handler:^(UIAlertView *a, NSInteger index) {
        if (index == a.cancelButtonIndex) return;
        NSString *pin = [[a textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *pass = [a textFieldAtIndex:1].text ?: @"";
        if (pin.length != 4 || pass.length < 4) {
            [ALUtils alertWithTitle:L(@"One-time PIN (Apollo)") message:L(@"The PIN has 4 digits and the passphrase at least 4 characters.")];
            return;
        }
        [weakSelf pairHost:host pin:pin otpPassphrase:pass];
    }];
    UITextField *pinField = [alert textFieldAtIndex:0];
    pinField.placeholder = L(@"PIN (4 digits)");
    pinField.keyboardType = UIKeyboardTypeNumberPad;
    [alert textFieldAtIndex:1].placeholder = L(@"Passphrase");
}

- (void)pairHost:(ALHost *)host pin:(NSString *)pin otpPassphrase:(NSString *)passphrase
{
    [self.pairTask cancel];
    NSString *message;
    if (passphrase.length) {
        message = L(@"Pairing with the one-time PIN…");
    } else {
        NSString *address = host.activeAddress ?: [host displayAddress];
        message = [NSString stringWithFormat:L(@"On the PC, open the Sunshine or Apollo web page (https://%@:47990), go to \"PIN\" and type this PIN:\n\n%@"), address, pin];
    }
    ALLog(@"Pairing with %@ (%@)", host.name, passphrase.length ? @"one-time PIN" : [NSString stringWithFormat:@"PIN %@", pin]);
    __weak ALHostsViewController *weakSelf = self;
    self.pairAlert = [ALAlerts alertWithTitle:[NSString stringWithFormat:L(@"Pairing with %@"), host.name ?: L(@"the PC")] message:message
                                       cancel:L(@"Cancel") buttons:nil style:UIAlertViewStyleDefault handler:^(UIAlertView *a, NSInteger index) {
        ALHostsViewController *s = weakSelf;
        if (s.pairAlert == a) { s.pairAlert = nil; [s.pairTask cancel]; s.pairTask = nil; }
    }];
    self.pairTask = [ALGameStream pairHost:host pin:pin otpPassphrase:passphrase completion:^(NSError *error) {
        ALHostsViewController *s = weakSelf;
        UIAlertView *alert = s.pairAlert;
        s.pairAlert = nil;
        s.pairTask = nil;
        [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:YES];
        if (error) {
            if (error.code != ALErrorCancelled) [ALUtils alertWithTitle:L(@"Pairing failed") message:error.localizedDescription];
            return;
        }
        [s.tableView reloadData];
        [s openHost:host];
    }];
}

#pragma mark - Opening

- (void)openHost:(ALHost *)host
{
    if ([self.navigationController.topViewController isKindOfClass:[ALAppsViewController class]]) [self.navigationController popToRootViewControllerAnimated:NO];
    ALAppsViewController *apps = [[ALAppsViewController alloc] initWithHost:host];
    [self.navigationController pushViewController:apps animated:YES];
}

@end
