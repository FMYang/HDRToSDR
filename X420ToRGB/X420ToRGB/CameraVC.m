//
//  CameraVC.m
//  X420ToRGB
//
//  Created by yfm on 2023/8/10.
//

#import "CameraVC.h"
#import <AVFoundation/AVFoundation.h>
#import "FMMetalCameraView.h"
#import "ZYMetalDevice.h"
#import "ZYProCameraMovieRecorder.h"
#import <AssetsLibrary/AssetsLibrary.h>

@interface CameraVC () <AVCaptureVideoDataOutputSampleBufferDelegate, ZYProCameraMovieRecorderDelegate>
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDevice *videoDevice;
@property (nonatomic) AVCaptureInput *videoDeviceInput;
@property (nonatomic) dispatch_queue_t dataOutputQueue;
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t renderQueue;
@property (nonatomic) dispatch_queue_t recordCallbackQueue;
@property (nonatomic) AVCaptureConnection *dataOutputConnection;
@property (nonatomic) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic) dispatch_semaphore_t frameRenderingSemaphore;
@property (nonatomic) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;

@property (nonatomic) FMMetalCameraView *metalView;

// MARK: - 录像
@property (nonatomic) ZYProCameraMovieRecorder *movieRecorder;
@property (nonatomic) BOOL isRecording;
@property (nonatomic) UIButton *recordButton;


@end

@implementation CameraVC

- (instancetype)init {
    if(self = [super init]) {
        _sessionQueue = dispatch_queue_create("fm.sessionQueue", DISPATCH_QUEUE_SERIAL);
        _dataOutputQueue = dispatch_queue_create("fm.dataOutputQueue", DISPATCH_QUEUE_SERIAL);
        _renderQueue = dispatch_queue_create("fm.renderQueue", DISPATCH_QUEUE_SERIAL);
        _recordCallbackQueue = dispatch_queue_create("fm.recordCallbackQueue", DISPATCH_QUEUE_SERIAL);
        _videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    
    _metalView = [[FMMetalCameraView alloc] init];
    _metalView.backgroundColor = UIColor.blackColor;
    CGFloat h = UIScreen.mainScreen.bounds.size.width * 16.0 / 9;
    _metalView.frame = CGRectMake(0, 0.5 * (UIScreen.mainScreen.bounds.size.height - h), UIScreen.mainScreen.bounds.size.width, h);
    [self.view addSubview:_metalView];
    
    _recordButton = [[UIButton alloc] init];
    _recordButton.backgroundColor = UIColor.whiteColor;
    _recordButton.frame = CGRectMake(0, 0, 60, 60);
    _recordButton.center = CGPointMake(UIScreen.mainScreen.bounds.size.width * 0.5, UIScreen.mainScreen.bounds.size.height - 100);
    _recordButton.layer.cornerRadius = 30;
    _recordButton.layer.masksToBounds = YES;
    [_recordButton addTarget:self action:@selector(recordAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_recordButton];
    
    UISwipeGestureRecognizer *swipeGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(closeAction)];
    swipeGesture.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipeGesture];
    
    self.session = [[AVCaptureSession alloc] init];

    dispatch_async(self.sessionQueue, ^{
        [self configSession];
    });
}

- (void)closeAction {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    dispatch_async(self.sessionQueue, ^{
        [self.session startRunning];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    dispatch_async(self.sessionQueue, ^{
        [self.session stopRunning];
    });
}

- (void)configSession {
    self.videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    
    NSError *error = nil;
    AVCaptureInput *videoDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:self.videoDevice error:&error];
    
    [self.session beginConfiguration];
    
    self.session.sessionPreset = AVCaptureSessionPreset1280x720;
    
    if([self.session canAddInput:videoDeviceInput]) {
        [self.session addInput:videoDeviceInput];
        self.videoDeviceInput = videoDeviceInput;
    } else {
        [self.session commitConfiguration];
        return;
    }
    
    if([self.session canAddOutput:self.videoDataOutput]) {
        [self.session addOutput:self.videoDataOutput];
        AVCaptureDeviceFormat *bestFormat;
        for (AVCaptureDeviceFormat *format in self.videoDevice.formats) {
            CMFormatDescriptionRef formatDescriptionRef = format.formatDescription;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescriptionRef);
            NSInteger mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescriptionRef);
            if(dimensions.width == 3840 &&
               dimensions.height == 2160 &&
               mediaSubType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                bestFormat = format;
                break;
            }
        }
        if([self.videoDevice lockForConfiguration:nil]) {
            self.videoDevice.activeFormat = bestFormat;
            [self.videoDevice unlockForConfiguration];
        }
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.dataOutputQueue];
        
        self.dataOutputConnection = [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    } else {
        [self.session commitConfiguration];
        return;
    }
    
    [self.session commitConfiguration];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if(dispatch_semaphore_wait(self.frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CVPixelBufferRef originalPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    // HDR to RGB
    CVPixelBufferRef rgbPixelBuffer = [self convertHDRToRGBPixelBuffer:originalPixelBuffer];
    
    CMFormatDescriptionRef pixelFormatDescriptionRef = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, rgbPixelBuffer, &pixelFormatDescriptionRef);
    self.outputVideoFormatDescription = pixelFormatDescriptionRef;
    
    CFRetain(rgbPixelBuffer);
    dispatch_async(self.renderQueue, ^{
        CVPixelBufferLockBaseAddress(rgbPixelBuffer, kCVPixelBufferLock_ReadOnly);
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:CVPixelBufferGetWidth(rgbPixelBuffer) height:CVPixelBufferGetHeight(rgbPixelBuffer) mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [ZYMetalDevice.shared.device newTextureWithDescriptor:textureDescriptor];
        MTLRegion region = MTLRegionMake2D(0, 0, CVPixelBufferGetWidth(rgbPixelBuffer), CVPixelBufferGetHeight(rgbPixelBuffer));
        [texture replaceRegion:region mipmapLevel:0 withBytes:CVPixelBufferGetBaseAddress(rgbPixelBuffer) bytesPerRow:CVPixelBufferGetBytesPerRow(rgbPixelBuffer)];
        
        [self.metalView renderPixelBuffer:texture];
        
        if(self.isRecording) {
            CFRetain(rgbPixelBuffer);
            dispatch_async(self.movieRecorder.writtingQueue, ^{
                // 写视频帧
                [self.movieRecorder appendVideoPixelBuffer:rgbPixelBuffer
                                      withPresentationTime:presentationTimeStamp];
                CFRelease(rgbPixelBuffer);
            });
        }
        
        CFRelease(rgbPixelBuffer);
        dispatch_semaphore_signal(self.frameRenderingSemaphore);
    });
    CFRelease(rgbPixelBuffer);
}

#pragma mark - 方向
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror {
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation);
    CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(self.dataOutputConnection.videoOrientation);
    
    CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
    transform = CGAffineTransformMakeRotation( angleOffset );
    
    if (self.videoDevice.position == AVCaptureDevicePositionFront ) {
        if ( mirror ) {
            if ( UIInterfaceOrientationIsPortrait( (UIInterfaceOrientation)orientation ) ) {
                transform = CGAffineTransformScale( transform, 1, -1 );
                
            }else{
                transform = CGAffineTransformScale( transform, -1, 1 );
                
            }
        } else {
            if ( UIInterfaceOrientationIsPortrait( (UIInterfaceOrientation)orientation ) ) {
                transform = CGAffineTransformRotate( transform, M_PI );
            }
        }
    }
    
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


#pragma mark - X420 to RGB

- (CVPixelBufferRef)convertHDRToRGBPixelBuffer:(CVPixelBufferRef)pixel {
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

#pragma mark - record
- (void)recordAction {
    [self startRecord];
}

- (void)startRecord {
    if(!self.isRecording) {
        NSURL *recordUrl = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), @"Movie.MOV"]]];
//        NSDictionary *videoSetting = [self.videoDataOutput recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie];
        _movieRecorder = [[ZYProCameraMovieRecorder alloc] initWithUrl:recordUrl delegate:self callBackQueue:self.recordCallbackQueue];
        [_movieRecorder addVideoTrackWithSourceFormatDescription:self.outputVideoFormatDescription transform:[self transformFromVideoBufferOrientationToOrientation:AVCaptureVideoOrientationPortrait withAutoMirroring:NO] settings:nil];
        [_movieRecorder prepareToRecord];
    } else {
        [self.movieRecorder finishRecording];
    }
}

- (void)movieRecorderDidStartRecording:(ZYProCameraMovieRecorder *)recorder {
    NSLog(@"movieRecorderDidStartRecording");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isRecording = YES;
    });
}

- (void)movieRecorder:(ZYProCameraMovieRecorder *)recorder didFailWithError:(NSError *)error {
    NSLog(@"movieRecorder didFailWithError");

    dispatch_async(dispatch_get_main_queue(), ^{
        self.isRecording = NO;
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
        self.isRecording = NO;
    });
}

- (void)setIsRecording:(BOOL)isRecording {
    _isRecording = isRecording;
    self.recordButton.backgroundColor = isRecording ? UIColor.redColor : UIColor.whiteColor;
}

@end
