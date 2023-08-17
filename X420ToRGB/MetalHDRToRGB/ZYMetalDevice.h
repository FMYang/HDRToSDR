//
//  ZYMetalDevice.h
//  FMMetalFilterChain
//
//  Created by yfm on 2022/7/14.
//

#import <Foundation/Foundation.h>
#include <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

static float normalVertices[] = { -1.0, 1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0 };
static float rotateCounterclockwiseCoordinates[] = { 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0 };

static const GLfloat rotate0[] = { 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0 };

static const GLfloat rotate90[] = { 1.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0 };


@interface ZYMetalDevice : NSObject

+ (ZYMetalDevice *)shared;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) CVMetalTextureCacheRef textureCache;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, readonly) id<MTLLibrary> library;

@end

NS_ASSUME_NONNULL_END
