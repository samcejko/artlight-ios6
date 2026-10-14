#import "ALCells.h"
#import "ALGameStream.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALCommon.h"

@interface ALAppCell ()
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UILabel *initialLabel;
@property (nonatomic, strong) UIImageView *cardView;
@property (nonatomic, copy) NSString *artKey;
@property (nonatomic, weak) ALApp *app;
@property (nonatomic, weak) ALHost *host;
@end

@implementation ALAppCell

+ (CGSize)cellSizeForWidth:(CGFloat)width
{
    // box art is 3:4 (Sunshine's own pictures are 600x800); columns by width
    NSInteger columns = width >= 1000 ? 6 : width >= 700 ? 5 : width >= 460 ? 4 : 3;
    CGFloat spacing = 10;
    CGFloat w = floor((width - spacing * (columns + 1)) / columns);
    return CGSizeMake(w, floor(w * 4 / 3) + 40);
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        ALTheme *theme = [ALTheme shared];
        _cardView = [[UIImageView alloc] initWithFrame:self.bounds];
        _cardView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardView.image = [theme cardBackgroundImage];
        [self.contentView addSubview:_cardView];
        _coverView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _coverView.contentMode = UIViewContentModeScaleAspectFill;
        _coverView.clipsToBounds = YES;
        _coverView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
        [self.contentView addSubview:_coverView];
        _initialLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _initialLabel.font = [UIFont boldSystemFontOfSize:ALIsPad() ? 44 : 32];
        _initialLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
        _initialLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.5];
        _initialLabel.shadowOffset = CGSizeMake(0, -1);
        _initialLabel.backgroundColor = [UIColor clearColor];
        _initialLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_initialLabel];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont boldSystemFontOfSize:ALIsPad() ? 13 : 12];
        _titleLabel.numberOfLines = 2;
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.textColor = [theme primaryTextColor];
        [self.contentView addSubview:_titleLabel];
        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.font = [theme tinyBoldFont];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.backgroundColor = [UIColor clearColor];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.hidden = YES;
        [self.contentView addSubview:_badgeLabel];
        self.selectedBackgroundView = [[UIImageView alloc] initWithImage:[theme cardBackgroundImageHighlighted]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artLoaded:) name:ALBoxArtDidLoadNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat coverH = b.size.height - 40;
    self.coverView.frame = CGRectMake(4, 4, b.size.width - 8, coverH - 8);
    self.initialLabel.frame = self.coverView.frame;
    self.titleLabel.frame = CGRectMake(6, coverH - 2, b.size.width - 12, 36);
    CGSize badge = [self.badgeLabel.text sizeWithFont:self.badgeLabel.font];
    self.badgeLabel.frame = CGRectMake(8, 8, badge.width + 12, 18);
}

- (void)showApp:(ALApp *)app host:(ALHost *)host running:(BOOL)running
{
    ALTheme *theme = [ALTheme shared];
    self.cardView.image = [theme cardBackgroundImage];
    self.titleLabel.textColor = [theme primaryTextColor];
    self.titleLabel.text = app.title;
    self.artKey = [NSString stringWithFormat:@"%@/%@", host.uuid ?: @"-", app.appId ?: @"0"];
    self.app = app;
    self.host = host;
    UIImage *art = [ALGameStream cachedBoxArtForHost:host app:app];
    self.coverView.image = art ?: [theme boxArtPlaceholder];
    self.initialLabel.text = art ? nil : [[app.title substringToIndex:MIN((NSUInteger)1, app.title.length)] uppercaseString];
    if (!art) [ALGameStream fetchBoxArtForHost:host app:app completion:nil];
    self.badgeLabel.text = running ? L(@"RUNNING") : nil;
    self.badgeLabel.hidden = !running;
    UIImage *pill = [theme pillImageWithColor:[theme accentColor]];
    self.badgeLabel.layer.contents = (id)pill.CGImage;
    self.badgeLabel.layer.contentsCenter = CGRectMake(0.45, 0.45, 0.1, 0.1);
    self.accessibilityLabel = app.title;
    [self setNeedsLayout];
}

- (void)artLoaded:(NSNotification *)note
{
    if (![note.userInfo[@"key"] isEqualToString:self.artKey] || !self.app || !self.host) return;
    UIImage *art = [ALGameStream cachedBoxArtForHost:self.host app:self.app];
    if (!art) return;
    self.coverView.image = art;
    self.initialLabel.text = nil;
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    self.coverView.image = nil;
    self.artKey = nil;
    self.badgeLabel.hidden = YES;
}

@end
