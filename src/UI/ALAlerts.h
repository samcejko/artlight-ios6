#import <UIKit/UIKit.h>

// UIAlertView / UIActionSheet with blocks (the iOS 6 way of asking, kept alive until answered)

typedef void (^ALAlertHandler)(UIAlertView *alert, NSInteger buttonIndex);   // cancel = alert.cancelButtonIndex
typedef void (^ALSheetHandler)(NSInteger buttonIndex);                     // -1 when cancelled / dismissed

@interface ALAlerts : NSObject

+ (UIAlertView *)alertWithTitle:(NSString *)title message:(NSString *)message cancel:(NSString *)cancel
                        buttons:(NSArray *)buttons style:(UIAlertViewStyle)style handler:(ALAlertHandler)handler;

// One sheet with a title; buttons in order; destructive: index into buttons or -1. From a view controller's view
// (on the iPad from the given rect, else from the bottom).
+ (UIActionSheet *)sheetWithTitle:(NSString *)title buttons:(NSArray *)buttons destructive:(NSInteger)destructive
                             from:(UIViewController *)controller rect:(CGRect)rect handler:(ALSheetHandler)handler;

@end
