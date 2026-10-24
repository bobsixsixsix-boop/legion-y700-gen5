// Copyright (c) 2025, Qualcomm Innovation Center, Inc. All rights reserved.
// SPDX-FileCopyrightText: 2026 bobsixsixsix-boop
// SPDX-License-Identifier: BSD-3-Clause
//
// Snapdragon™ Game Super Resolution 1 (sgsr1_shader_mobile.frag, RGBA mode) as a third filter of
// kwin-effect-upscale, next to FSR 1. One pass: a 12-tap Lanczos-like enlargement on the green
// channel as luma proxy, applied only where an edge vote passes, with built-in adaptive sharpening.
// Conventions of this effect: the version/precision preamble is prepended by scaler.cpp; the capture
// texture is sampled nearest, so the bilinear base sample and the four-texel gathers are built from
// texelFetch (OpenGL ES 3.0 has no textureGather); gather components are ordered like textureGather:
// x=(0,1) y=(1,1) z=(1,0) w=(0,0) of the 2x2 block at floor(uv * size - 0.5).

uniform sampler2D sampler;
uniform vec2 inputSize;
uniform vec2 outputSize;
uniform bool intermediate;
in vec2 texcoord0;
out vec4 fragColor;

#include "upscale/workingcolor.glsl"

const float EdgeThreshold = 8.0 / 255.0;   // Qualcomm: 8/255 mobile, 4/255 VR
const float EdgeSharpness = 2.0;           // Qualcomm: 1.0 .. 2.0

vec3 sampleInput(ivec2 pixel)
{
    vec3 texel = texelFetch(sampler, clamp(pixel, ivec2(0), ivec2(inputSize) - 1), 0).rgb;
#ifdef UPSCALE_DIRECT
    return texel;
#else
    return toWorking(fromDestination(texel));
#endif
}

// What textureLod() returns from a linearly filtered texture at uv.
vec3 bilinear(vec2 uv)
{
    vec2 p = uv * inputSize - 0.5;
    vec2 i = floor(p);
    vec2 f = p - i;
    ivec2 b = ivec2(i);
    vec3 c00 = sampleInput(b);
    vec3 c10 = sampleInput(b + ivec2(1, 0));
    vec3 c01 = sampleInput(b + ivec2(0, 1));
    vec3 c11 = sampleInput(b + ivec2(1, 1));
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// textureGather(sampler, uv, 1) for the green channel.
vec4 gatherG(vec2 uv)
{
    ivec2 b = ivec2(floor(uv * inputSize - 0.5));
    return vec4(sampleInput(b + ivec2(0, 1)).g,
                sampleInput(b + ivec2(1, 1)).g,
                sampleInput(b + ivec2(1, 0)).g,
                sampleInput(b).g);
}

float fastLanczos2(float x)
{
    float wA = x - 4.0;
    float wB = x * wA - wA;
    wA *= wA;
    return wB * wA;
}

vec2 weightY(float dx, float dy, float c, float std)
{
    float x = ((dx * dx) + (dy * dy)) * 0.55 + clamp(abs(c) * std, 0.0, 1.0);
    float w = fastLanczos2(x);
    return vec2(w, w * c);
}

void main()
{
    vec2 uv = texcoord0;
    vec2 inv = 1.0 / inputSize;
    vec4 color = vec4(bilinear(uv), 1.0);

    vec2 imgCoord = uv * inputSize + vec2(-0.5, 0.5);
    vec2 imgCoordPixel = floor(imgCoord);
    vec2 coord = imgCoordPixel * inv;
    vec2 pl = imgCoord - imgCoordPixel;
    vec4 left = gatherG(coord);

    float edgeVote = abs(left.z - left.y) + abs(color.g - left.y) + abs(color.g - left.z);
    if (edgeVote > EdgeThreshold) {
        coord.x += inv.x;
        vec4 right = gatherG(coord + vec2(inv.x, 0.0));
        vec4 upDown;
        upDown.xy = gatherG(coord + vec2(0.0, -inv.y)).wz;
        upDown.zw = gatherG(coord + vec2(0.0, inv.y)).yx;

        float mean = (left.y + left.z + right.x + right.w) * 0.25;
        left = left - vec4(mean);
        right = right - vec4(mean);
        upDown = upDown - vec4(mean);
        color.w = color.g - mean;

        float sum = (((((abs(left.x) + abs(left.y)) + abs(left.z)) + abs(left.w))
                      + (((abs(right.x) + abs(right.y)) + abs(right.z)) + abs(right.w)))
                     + (((abs(upDown.x) + abs(upDown.y)) + abs(upDown.z)) + abs(upDown.w)));
        float std = 2.181818 / sum;

        vec2 aWY = weightY(pl.x, pl.y + 1.0, upDown.x, std);
        aWY += weightY(pl.x - 1.0, pl.y + 1.0, upDown.y, std);
        aWY += weightY(pl.x - 1.0, pl.y - 2.0, upDown.z, std);
        aWY += weightY(pl.x, pl.y - 2.0, upDown.w, std);
        aWY += weightY(pl.x + 1.0, pl.y - 1.0, left.x, std);
        aWY += weightY(pl.x, pl.y - 1.0, left.y, std);
        aWY += weightY(pl.x, pl.y, left.z, std);
        aWY += weightY(pl.x + 1.0, pl.y, left.w, std);
        aWY += weightY(pl.x - 1.0, pl.y - 1.0, right.x, std);
        aWY += weightY(pl.x - 2.0, pl.y - 1.0, right.y, std);
        aWY += weightY(pl.x - 2.0, pl.y, right.z, std);
        aWY += weightY(pl.x - 1.0, pl.y, right.w, std);

        float finalY = aWY.y / aWY.x;
        float maxY = max(max(left.y, left.z), max(right.x, right.w));
        float minY = min(min(left.y, left.z), min(right.x, right.w));
        finalY = clamp(EdgeSharpness * finalY, minY, maxY);

        float deltaY = finalY - color.w;
        deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);   // smooth high contrast input
        color.rgb = clamp(color.rgb + vec3(deltaY), 0.0, 1.0);
    }

#ifdef UPSCALE_DIRECT
    fragColor = vec4(color.rgb, 1.0);
#else
    fragColor = vec4(intermediate ? color.rgb : toDestination(fromWorking(color.rgb)), 1.0);
#endif
}
