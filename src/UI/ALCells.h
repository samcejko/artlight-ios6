#import <UIKit/UIKit.h>
#import "ALHost.h"

// An app of the PC in the grid: box art with the title under it, a badge when it is running
@interface ALAppCell : UICollectionViewCell
@property (nonatomic, strong, readonly) UIImageView *coverView;
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *badgeLabel;
- (void)showApp:(ALApp *)app host:(ALHost *)host running:(BOOL)running;
+ (CGSize)cellSizeForWidth:(CGFloat)width;
@end
