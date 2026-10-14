#import "ALAlerts.h"
#import "ALCommon.h"
#import <objc/runtime.h>

static char kALDelegateKey;

@interface ALAlertDelegate : NSObject <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, copy) ALAlertHandler alertHandler;
@property (nonatomic, copy) ALSheetHandler sheetHandler;
@property (nonatomic) NSInteger firstOtherIndex;
@property (nonatomic) BOOL done;
@end

@implementation ALAlertDelegate

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (self.done) return;
    self.done = YES;
    ALAlertHandler h = self.alertHandler;
    objc_setAssociatedObject(alertView, &kALDelegateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (h) h(alertView, buttonIndex);
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (self.done) return;
    self.done = YES;
    ALSheetHandler h = self.sheetHandler;
    objc_setAssociatedObject(sheet, &kALDelegateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSInteger index = (buttonIndex < 0 || buttonIndex == sheet.cancelButtonIndex) ? -1 : buttonIndex - self.firstOtherIndex;
    if (h) h(index);
}

@end

@implementation ALAlerts

+ (UIAlertView *)alertWithTitle:(NSString *)title message:(NSString *)message cancel:(NSString *)cancel
                        buttons:(NSArray *)buttons style:(UIAlertViewStyle)style handler:(ALAlertHandler)handler
{
    ALAlertDelegate *d = [[ALAlertDelegate alloc] init];
    d.alertHandler = handler;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:d cancelButtonTitle:cancel otherButtonTitles:nil];
    for (NSString *b in buttons) [alert addButtonWithTitle:b];
    alert.alertViewStyle = style;
    objc_setAssociatedObject(alert, &kALDelegateKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [alert show];
    return alert;
}

+ (UIActionSheet *)sheetWithTitle:(NSString *)title buttons:(NSArray *)buttons destructive:(NSInteger)destructive
                             from:(UIViewController *)controller rect:(CGRect)rect handler:(ALSheetHandler)handler
{
    ALAlertDelegate *d = [[ALAlertDelegate alloc] init];
    d.sheetHandler = handler;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:d cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    d.firstOtherIndex = 0;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        NSInteger idx = [sheet addButtonWithTitle:buttons[i]];
        if ((NSInteger)i == destructive) sheet.destructiveButtonIndex = idx;
    }
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    objc_setAssociatedObject(sheet, &kALDelegateKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *view = controller.view;
    if (ALIsPad() && !CGRectIsEmpty(rect)) [sheet showFromRect:rect inView:view animated:YES];
    else if (controller.tabBarController) [sheet showFromTabBar:controller.tabBarController.tabBar];
    else [sheet showInView:view];
    return sheet;
}

@end
