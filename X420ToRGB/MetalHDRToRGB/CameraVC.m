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
#import <AssetsLibrary/AssetsLibrary.h>

@interface CameraVC () <AVCaptureVideoDataOutputSampleBufferDelegate>
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

@property (nonatomic) FMMetalCameraView *metalView;

@property (nonatomic) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic) CVPixelBufferRef outputPixelBuffer;
@property (nonatomic) CVMetalTextureRef outputTextureRef;

@end

@implementation CameraVC

- (void)dealloc {
    if(_outputPixelBuffer) {
        CFRelease(_outputPixelBuffer);
    }
    if(_outputTextureRef) {
        CFRelease(_outputTextureRef);
    }
}

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

    [self setupPipelineState];

    self.session = [[AVCaptureSession alloc] init];
    
    dispatch_async(self.sessionQueue, ^{
        [self configSession];
    });
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

- (void)setupPipelineState {
    id<MTLFunction> vextexFunction = [ZYMetalDevice.shared.library newFunctionWithName:@"hdrVertex"];
    id<MTLFunction> fragmentFunction = [ZYMetalDevice.shared.library newFunctionWithName:@"hdrFrag"];
    
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vextexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *error;
    _pipelineState = [ZYMetalDevice.shared.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
}

- (void)configSession {
    self.videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    
    NSError *error = nil;
    AVCaptureInput *videoDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:self.videoDevice error:&error];
    
    [self.session beginConfiguration];
        
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

    CVPixelBufferRef originalPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    CFRetain(originalPixelBuffer);
    dispatch_async(self.renderQueue, ^{
        // hdr to rgb
        id<MTLTexture> rgbTexture = [self metalHDRToRGB:originalPixelBuffer];
        // 显示转换后的rgb纹理
        [self.metalView renderPixelBuffer:rgbTexture];
        
        CFRelease(originalPixelBuffer);
        dispatch_semaphore_signal(self.frameRenderingSemaphore);
    });
}

#pragma mark - metal HDR to RGB
- (id<MTLTexture>)metalHDRToRGB:(CVPixelBufferRef)pixelBuffer {
    size_t pixelWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t pixelHeight = CVPixelBufferGetHeight(pixelBuffer);
            
    // 创建hdr10位的y和uv纹理
    CVMetalTextureRef yTextureRef;
    CVMetalTextureRef uvTextureRef;
    
    int y_width = (int)CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    int y_height = (int)CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, ZYMetalDevice.shared.textureCache, pixelBuffer, nil, MTLPixelFormatR16Unorm, y_width, y_height, 0, &yTextureRef);
    
    // UV分量
    int uv_width = (int)CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
    int uv_height = (int)CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, ZYMetalDevice.shared.textureCache, pixelBuffer, nil, MTLPixelFormatRG16Unorm, uv_width, uv_height, 1, &uvTextureRef);
    
    // 创建输出纹理
    if(!_outputTextureRef) {
        // 只创建一次
        NSDictionary *pixelBufferAttributes = @{
            (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        };
        CVPixelBufferCreate(NULL, pixelWidth, pixelHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &_outputPixelBuffer);
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, ZYMetalDevice.shared.textureCache, _outputPixelBuffer, nil, MTLPixelFormatBGRA8Unorm, pixelWidth, pixelHeight, 0, &_outputTextureRef);
    }
    id<MTLTexture> output = CVMetalTextureGetTexture(_outputTextureRef);
    
    // 渲染
    id<MTLCommandBuffer> commandBuffer = [ZYMetalDevice.shared.commandQueue commandBuffer];
    
    MTLRenderPassDescriptor *renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];
    renderPassDescriptor.colorAttachments[0].texture = output;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    
    id<MTLRenderCommandEncoder> commandEncoder =
    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    id<MTLBuffer> positionBuffer = [ZYMetalDevice.shared.device newBufferWithBytes:normalVertices length:sizeof(normalVertices) options:MTLResourceStorageModeShared];
    id<MTLBuffer> texCoordinateBuffer = [ZYMetalDevice.shared.device newBufferWithBytes:rotate0 length:sizeof(rotate0) options:MTLResourceStorageModeShared];
    
    [commandEncoder setVertexBuffer:positionBuffer offset:0 atIndex:0];
    [commandEncoder setVertexBuffer:texCoordinateBuffer offset:0 atIndex:1];
    
    [commandEncoder setRenderPipelineState:_pipelineState];
    [commandEncoder setFragmentTexture:CVMetalTextureGetTexture(yTextureRef) atIndex:0];
    [commandEncoder setFragmentTexture:CVMetalTextureGetTexture(uvTextureRef) atIndex:1];
    [commandEncoder setFragmentTexture:output atIndex:2];
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        
    [commandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFRelease(yTextureRef);
    CFRelease(uvTextureRef);
    
    return output;
}

@end
