#import "ALAppsViewController.h"
#import "ALStreamViewController.h"
#import "ALCells.h"
#import "ALAlerts.h"
#import "ALGameStream.h"
#import "ALDiscovery.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALModern.h"
#import "ALCommon.h"

@interface ALAppsViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) ALHost *host;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL streaming;
@end

@implementation ALAppsViewController

- (instancetype)initWithHost:(ALHost *)host
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _host = host;
        _apps = host.apps ?: @[];
        self.title = host.name;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    ALTheme *theme = [ALTheme shared];
    self.view.backgroundColor = [theme backgroundColor];
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(10, 10, 10, 10);
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 10;
    self.grid = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.grid.backgroundColor = [UIColor clearColor];
    self.grid.alwaysBounceVertical = YES;
    self.grid.dataSource = self;
    self.grid.delegate = self;
    [self.grid registerClass:[ALAppCell class] forCellWithReuseIdentifier:@"app"];
    [self.view addSubview:self.grid];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(gridHeld:)];
    [self.grid addGestureRecognizer:hold];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.textColor = [theme secondaryTextColor];
    self.messageLabel.font = [theme bodyFont];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hostChanged:) name:ALHostsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged) name:ALThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[ALDiscovery shared] start];
    if (!self.apps.count || !self.loading) [self reload];
    [self updateQuitButton];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = ALSafeAreaInsets(self.view);
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.grid.collectionViewLayout;
    UIEdgeInsets inset = UIEdgeInsetsMake(10, 10 + safe.left, 10, 10 + safe.right);
    if (!UIEdgeInsetsEqualToEdgeInsets(layout.sectionInset, inset)) { layout.sectionInset = inset; [layout invalidateLayout]; }
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height / 2 - 30);
    self.messageLabel.frame = CGRectMake(30, b.size.height / 2 - 80, b.size.width - 60, 140);
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    [self.grid.collectionViewLayout invalidateLayout];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)themeChanged
{
    ALTheme *theme = [ALTheme shared];
    self.view.backgroundColor = [theme backgroundColor];
    self.messageLabel.textColor = [theme secondaryTextColor];
    [self.grid reloadData];
}

- (void)hostChanged:(NSNotification *)note
{
    if (note.object && note.object != self.host) return;
    if (![[ALHostStore shared].hosts containsObject:self.host]) { [self.navigationController popToRootViewControllerAnimated:YES]; return; }
    self.title = self.host.name;
    [self updateQuitButton];
    [self.grid reloadData];
}

- (void)updateQuitButton
{
    if (self.host.isBusy && self.host.state == ALHostStateOnline) {
        UIBarButtonItem *quit = [[UIBarButtonItem alloc] initWithTitle:L(@"Quit game") style:UIBarButtonItemStyleBordered target:self action:@selector(quitTapped:)];
        self.navigationItem.rightBarButtonItems = @[ [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)], quit ];
    } else {
        self.navigationItem.rightBarButtonItems = @[ [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)] ];
    }
}

#pragma mark - Loading

- (void)showMessage:(NSString *)message
{
    self.messageLabel.text = message;
    self.messageLabel.hidden = message == nil;
}

- (void)reload
{
    if (self.loading) return;
    self.loading = YES;
    if (!self.apps.count) [self.spinner startAnimating];
    [self showMessage:nil];
    __weak ALAppsViewController *weakSelf = self;
    [ALGameStream refreshHost:self.host completion:^(NSError *refreshError) {
        ALAppsViewController *s = weakSelf;
        if (!s) return;
        if (refreshError || !s.host.paired) {
            s.loading = NO;
            [s.spinner stopAnimating];
            [s showMessage:!s.host.paired ? L(@"The PC no longer knows this device. Go back and pair again.") :
                           [NSString stringWithFormat:L(@"The PC does not answer.\n%@"), refreshError.localizedDescription ?: @""]];
            return;
        }
        [ALGameStream fetchAppsForHost:s.host completion:^(NSArray *apps, NSError *error) {
            ALAppsViewController *s2 = weakSelf;
            if (!s2) return;
            s2.loading = NO;
            [s2.spinner stopAnimating];
            if (apps) {
                s2.apps = apps;
                [s2.grid reloadData];
                [s2 updateQuitButton];
                if (!apps.count) [s2 showMessage:L(@"The PC offers no apps. Add some in Sunshine's or Apollo's web page.")];
            } else if (!s2.apps.count) {
                [s2 showMessage:error.localizedDescription];
            }
        }];
    }];
}

#pragma mark - Grid

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)self.apps.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ALAppCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"app" forIndexPath:indexPath];
    ALApp *app = self.apps[(NSUInteger)indexPath.item];
    [cell showApp:app host:self.host running:self.host.isBusy && [self.host.currentGameId isEqualToString:app.appId]];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UIEdgeInsets safe = ALSafeAreaInsets(collectionView);
    return [ALAppCell cellSizeForWidth:collectionView.bounds.size.width - safe.left - safe.right];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    [self launchApp:self.apps[(NSUInteger)indexPath.item]];
}

- (void)gridHeld:(UILongPressGestureRecognizer *)hold
{
    if (hold.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [self.grid indexPathForItemAtPoint:[hold locationInView:self.grid]];
    if (!ip) return;
    ALApp *app = self.apps[(NSUInteger)ip.item];
    BOOL running = self.host.isBusy && [self.host.currentGameId isEqualToString:app.appId];
    UICollectionViewCell *cell = [self.grid cellForItemAtIndexPath:ip];
    CGRect rect = [self.grid convertRect:cell.frame toView:self.view];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:running ? L(@"Resume") : L(@"Start")];
    if (running) [titles addObject:L(@"Quit game")];
    [ALAlerts sheetWithTitle:app.title buttons:titles destructive:running ? 1 : -1 from:self rect:rect handler:^(NSInteger index) {
        if (index == 0) [self launchApp:app];
        else if (index == 1) [self quitRunningApp];
    }];
}

#pragma mark - Launch / quit

- (void)launchApp:(ALApp *)app
{
    if (self.streaming || !app) return;
    if ([app.appId isEqualToString:@"114514"] && [app.title isEqualToString:@"Permission Denied"]) {
        [ALUtils alertWithTitle:app.title message:L(@"Apollo does not let this device list or start apps yet. Allow it on the Clients page of Apollo's web interface on the PC.")];
        return;
    }
    if (![self.host hasPermission:ALPermLaunch] && !(self.host.isBusy && [self.host hasPermission:ALPermView])) {
        [ALUtils alertWithTitle:app.title message:L(@"Apollo does not let this device start apps. Allow \"Launch\" on the Clients page of Apollo's web interface.")];
        return;
    }
    if (self.host.isBusy && ![self.host.currentGameId isEqualToString:app.appId]) {
        ALApp *running = [self.host appWithId:self.host.currentGameId];
        NSString *message = [NSString stringWithFormat:L(@"%@ is running on the PC. Quit it and start %@?"), running.title ?: L(@"Another app"), app.title];
        [ALAlerts alertWithTitle:app.title message:message cancel:L(@"Cancel") buttons:@[ L(@"Quit and start") ] style:UIAlertViewStyleDefault handler:^(UIAlertView *a, NSInteger index) {
            if (index == a.cancelButtonIndex) return;
            [self quitThen:^{ [self startStreamWithApp:app]; }];
        }];
        return;
    }
    [self startStreamWithApp:app];
}

- (void)startStreamWithApp:(ALApp *)app
{
    if (self.streaming) return;
    self.streaming = YES;
    [[ALDiscovery shared] stop];
    ALStreamViewController *stream = [[ALStreamViewController alloc] initWithHost:self.host app:app];
    __weak ALAppsViewController *weakSelf = self;
    stream.onFinished = ^(NSString *message) {
        ALAppsViewController *s = weakSelf;
        [s dismissViewControllerAnimated:YES completion:^{
            s.streaming = NO;
            if (message.length) [ALUtils alertWithTitle:app.title message:message];
            [s reload];
            [[ALDiscovery shared] start];
        }];
    };
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:stream animated:YES completion:nil];
}

- (void)quitTapped:(UIBarButtonItem *)item
{
    ALApp *running = [self.host appWithId:self.host.currentGameId];
    NSString *message = [NSString stringWithFormat:L(@"Quit %@ on the PC? Anything not saved in the game is lost."), running.title ?: L(@"the running app")];
    [ALAlerts alertWithTitle:L(@"Quit game") message:message cancel:L(@"Cancel") buttons:@[ L(@"Quit") ] style:UIAlertViewStyleDefault handler:^(UIAlertView *a, NSInteger index) {
        if (index != a.cancelButtonIndex) [self quitRunningApp];
    }];
}

- (void)quitRunningApp
{
    [self quitThen:nil];
}

- (void)quitThen:(dispatch_block_t)next
{
    UIAlertView *progress = [ALAlerts alertWithTitle:L(@"Quit game") message:L(@"Quitting the game on the PC…") cancel:nil buttons:nil style:UIAlertViewStyleDefault handler:nil];
    [ALGameStream quitAppOnHost:self.host completion:^(NSError *error) {
        [progress dismissWithClickedButtonIndex:0 animated:YES];
        [self updateQuitButton];
        [self.grid reloadData];
        if (error) { [ALUtils alertWithTitle:L(@"Quit game") message:error.localizedDescription]; return; }
        if (next) next();
    }];
}

@end
