//
//  ViewController.m
//  X420ToRGB
//
//  Created by yfm on 2023/8/10.
//

#import "ViewController.h"
#import "CameraVC.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CameraVC *vc = [[CameraVC alloc] init];
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    });
}

@end
