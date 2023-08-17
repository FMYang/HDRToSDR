//
//  ViewController.m
//  X420ToRGB
//
//  Created by yfm on 2023/8/10.
//

#import "ViewController.h"
#import "CameraVC.h"
#import <AVFoundation/AVFoundation.h>
#import "ZYProCameraMovieRecorder.h"
#import <AssetsLibrary/AssetsLibrary.h>

@interface ViewController () <ZYProCameraMovieRecorderDelegate>
@property (nonatomic) dispatch_queue_t recordCallbackQueue;
@property (nonatomic) ZYProCameraMovieRecorder *movieRecorder;
@property (nonatomic) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property (nonatomic) dispatch_semaphore_t frameRenderingSemaphore;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _frameRenderingSemaphore = dispatch_semaphore_create(1);
    _recordCallbackQueue = dispatch_queue_create("fm.recordCallbackQueue", DISPATCH_QUEUE_SERIAL);

    UIButton *btn = [[UIButton alloc] initWithFrame:CGRectMake(100, 100, 100, 100)];
    btn.backgroundColor = UIColor.redColor;
    [btn setTitle:@"Expore" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(btnAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CameraVC *vc = [[CameraVC alloc] init];
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    });
}

- (void)btnAction {
    [self exportVideo];
}

- (void)createMovieRecord:(CVPixelBufferRef)pixelBuffer {
    if (_movieRecorder) return;
    CMFormatDescriptionRef pixelFormatDescriptionRef = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &pixelFormatDescriptionRef);

    NSURL *recordUrl = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), @"Movie.MOV"]]];

    _movieRecorder = [[ZYProCameraMovieRecorder alloc] initWithUrl:recordUrl delegate:self callBackQueue:self.recordCallbackQueue];
    [_movieRecorder addVideoTrackWithSourceFormatDescription:pixelFormatDescriptionRef transform:[self transformFromVideoBufferOrientationToOrientation:AVCaptureVideoOrientationLandscapeLeft withAutoMirroring:NO] settings:nil];
    [_movieRecorder prepareToRecord];
}

- (void)exportVideo {
    NSString *videoPath = [[NSBundle mainBundle] pathForResource:@"original.mov" ofType:nil];
    NSURL *videoUrl = [NSURL fileURLWithPath:videoPath];
    
    AVAsset *asset = [AVAsset assetWithURL:videoUrl];
    NSError *error;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) { NSLog(@"Failed to create AVAssetReader: %@", error); return; }
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    NSDictionary *outputSetting = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)};
    AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSetting];
    [reader addOutput:trackOutput];
    [reader startReading];
    
    CMSampleBufferRef firstBuffer = [trackOutput copyNextSampleBuffer];
    CVPixelBufferRef firstPixelBuffer = CMSampleBufferGetImageBuffer(firstBuffer);
    CVPixelBufferRef firstRgbBuffer = [self convertToRGBPixelBuffer:firstPixelBuffer];
    [self createMovieRecord:firstRgbBuffer];
    CFRelease(firstRgbBuffer);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            CMSampleBufferRef sampleBuffer;
            while ((sampleBuffer = [trackOutput copyNextSampleBuffer])) {
                if(dispatch_semaphore_wait(self.frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
                    return;
                }
                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                CVPixelBufferRef rgbBuffer = [self convertToRGBPixelBuffer:pixelBuffer];
                CFRetain(rgbBuffer);
                dispatch_async(self.movieRecorder.writtingQueue, ^{
                    // 写视频帧
                    [self.movieRecorder appendVideoPixelBuffer:rgbBuffer
                                          withPresentationTime:presentationTimeStamp];
                    CFRelease(rgbBuffer);
                });
                CFRelease(rgbBuffer);
                CFRelease(sampleBuffer);
                dispatch_semaphore_signal(self.frameRenderingSemaphore);
            }
            [self.movieRecorder finishRecording];
            [reader cancelReading];
        });
    });
}

- (CVPixelBufferRef)convertToRGBPixelBuffer:(CVPixelBufferRef)pixel {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixel];
    CIContext *context = [CIContext context];
    NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };

    CVPixelBufferRef pixelBuffer;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                           ciImage.extent.size.width,
                                           ciImage.extent.size.height,
                                           kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)pixelBufferAttributes,
                                           &pixelBuffer);
    if (status != kCVReturnSuccess) {
        return nil;
    }

    [context render:ciImage toCVPixelBuffer:pixelBuffer];
    return pixelBuffer;
}


#pragma mark -
- (void)movieRecorderDidStartRecording:(ZYProCameraMovieRecorder *)recorder {
    NSLog(@"movieRecorderDidStartRecording");
    dispatch_async(dispatch_get_main_queue(), ^{
    });
}

- (void)movieRecorder:(ZYProCameraMovieRecorder *)recorder didFailWithError:(NSError *)error {
    NSLog(@"movieRecorder didFailWithError");

    dispatch_async(dispatch_get_main_queue(), ^{
        self.movieRecorder = nil;
    });
}

- (void)movieRecorderWillStopRecording:(ZYProCameraMovieRecorder *)recorder {
    NSLog(@"movieRecorderWillStopRecording");
}

- (void)movieRecorderDidStopRecording:(ZYProCameraMovieRecorder *)recorder url:(NSURL *)url {
    NSLog(@"movieRecorderDidStopRecording");
    
    [[[ALAssetsLibrary alloc] init] writeVideoAtPathToSavedPhotosAlbum:url completionBlock:^(NSURL *assetURL, NSError *error) {
        if(error) {
            NSLog(@"error %@", error);
        } else {
            NSLog(@"保存成功");
        }
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.movieRecorder = nil;
    });
}

#pragma mark - 方向
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror {
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation);
    CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientationPortrait);
    
    CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
    transform = CGAffineTransformMakeRotation( angleOffset );
        
    return transform;
}

static CGFloat angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientation orientation) {
    CGFloat angle = 0.0;
    
    switch ( orientation ) {
        case AVCaptureVideoOrientationPortrait:
            angle = 0.0;
            break;
        case AVCaptureVideoOrientationPortraitUpsideDown:
            angle = M_PI;
            break;
        case AVCaptureVideoOrientationLandscapeRight:
            angle = -M_PI_2;
            break;
        case AVCaptureVideoOrientationLandscapeLeft:
            angle = M_PI_2;
            break;
        default:
            break;
    }
    
    return angle;
}

@end
