//
//  HDR.metal
//  MetalHDRToRGB
//
//  Created by yfm on 2023/8/16.
//

#include <metal_stdlib>
using namespace metal;

// HDR to rgb
// 定义BT2020到709的矩阵转换
constant float3x3 bt2020To709Matrix = float3x3 {
    { 1.6605, -0.5876, -0.0728},
    {-0.1246, 1.1329, -0.0083},
    {-0.0182, -0.1006, 1.1187}
};

constant float3x3 yuvHdr2rgb = {
    // bt2020
    {1.1632,    1.1632,    1.1632},
    {0.0002,    -0.1870,   2.1421},
    {1.6794,    -0.6497,   0.0008}
};

constant float3x3 hdr_to_rgb_matrix = float3x3{
    // bt2020
    {1.0, 1.0, 1.0},
    {0.0, -0.39465, 2.03211},
    {1.13983, -0.58060, 0.0}
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
    float2 uv = float2(texture1.sample(textureSampler, in.textureCoordinate).rg) - float2(0.5);
    float3 yuv = float3(y, uv);
    
    float3 rgb = yuvHdr2rgb * yuv;
    float3 outputColor = rgb;

    return float4(outputColor, 1.0);
}
