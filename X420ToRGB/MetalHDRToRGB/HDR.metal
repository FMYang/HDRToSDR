//
//  HDR.metal
//  MetalHDRToRGB
//
//  Created by yfm on 2023/8/16.
//

#include <metal_stdlib>
using namespace metal;

// BT.601 full range (ref: http://www.equasys.de/colorconversion.html)
constant float3x3 ZYColorConversion601FullRangeDefault = {
    {1.0,    1.0,    1.0},
    {0.0,    -0.343, 1.765},
    {1.4,    -0.711, 0.0}
};

// BT.601, which is the standard for SDTV.
constant float3x3 ZYColorConversion601Default = {
    {1.164,  1.164,  1.164},
    {0.0,    -0.392, 2.017},
    {1.596,  -0.813, 0.0}
};

// BT.709, which is the standard for HDTV.
constant float3x3 ZYColorConversion709Default = {
    {1.164,  1.164,  1.164},
    {0.0,    -0.213, 2.112},
    {1.793,  -0.533, 0.0}
};

constant float3x3 ZYColorConversion2020 = {
    {1.1632,    1.1632,    1.1632},
    {0.0002,    -0.1870,   2.1421},
    {1.6794,    -0.6497,   0.0008}
};

// HDR to rgb
constant float3x3 yuvHdr2rgb = {
    // bt2020 to rgb
    {1.1632,    1.1632,    1.1632},
    {0.0002,    -0.1870,   2.1421},
    {1.6794,    -0.6497,   0.0008}
};

// from chatgpt
constant float3x3 hdr_to_rgb_matrix = float3x3{
    // bt2020 to rgb
    {1.0,     1.0,      1.0},
    {0.0,     -0.39465, 2.03211},
    {1.13983, -0.58060, 0.0}
};

// from tencent
// https://github.com/Tencent/libpag/blob/e549301ad08a779569bc27d99d440052a2784f82/tgfx/src/opengl/GLYUVTextureEffect.cpp#L133
constant float3x3 ColorConversion2020LimitRange = {
    { 1.164384f, 1.164384f,  1.164384f},
    { 0.0f,      -0.187326f, 2.141772f},
    {1.678674f,  -0.650424f, 0.0f}
};

constant float3x3 ColorConversion2020FullRange = {
    { 1.0f,   1.0f,       1.0f},
    { 0.0f,   -0.164553f, 1.8814f },
    {1.4746f, -0.571353f, 0.0f}
};


struct VextexOut {
    float4 position [[ position ]];
    float2 textureCoordinate;
};

vertex VextexOut hdrVertex(uint vertexID [[ vertex_id ]],
                           constant float2 *position [[ buffer(0) ]],
                           constant float2 *texCoordinate [[ buffer(1) ]]) {
    VextexOut out;
    out.position = float4(position[vertexID].xy, 0.0, 1.0);
    out.textureCoordinate = texCoordinate[vertexID];
    return out;
}

fragment float4 hdrFrag(VextexOut in [[ stage_in ]],
                        texture2d<float> texture0 [[texture(0)]],
                        texture2d<float> texture1 [[texture(1)]],
                        texture2d<float, access::write> outputTexture [[ texture(2)]]) {
    constexpr sampler textureSampler (mag_filter::linear, min_filter::linear);
    float y = texture0.sample(textureSampler, in.textureCoordinate).r;
    float2 uv = texture1.sample(textureSampler, in.textureCoordinate).rg - float2(0.5);
    float3 yuv = float3(y, uv);
    float3 rgb = ColorConversion2020FullRange * yuv;
    float3 outputColor = rgb;

    return float4(outputColor, 1.0);
}
