///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2016-2021, Intel Corporation
//
// SPDX-License-Identifier: MIT
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// XeGTAO is based on GTAO/GTSO "Jimenez et al. / Practical Real-Time Strategies for Accurate Indirect Occlusion",
// https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf
//
// Implementation:  Filip Strugar (filip.strugar@intel.com), Steve Mccalla <stephen.mccalla@intel.com>         (\_/)
// Version:         (see XeGTAO.h)                                                                            (='.'=)
// Details:         https://github.com/GameTechDev/XeGTAO                                                     (")_(")
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// with additional edits by FiveLimbedCat/ProfJack

#ifndef SSGI_COMMON
#define SSGI_COMMON

#ifndef USE_HALF_FLOAT_PRECISION
#	define USE_HALF_FLOAT_PRECISION 1
#endif

#if (USE_HALF_FLOAT_PRECISION != 0)
#	if 1  // old fp16 approach (<SM6.2)
typedef min16float lpfloat;
typedef min16float2 lpfloat2;
typedef min16float3 lpfloat3;
typedef min16float4 lpfloat4;
typedef min16float3x3 lpfloat3x3;
#	else  // new fp16 approach (requires SM6.2 and -enable-16bit-types) - WARNING: perf degradation noticed on some HW, while the old (min16float) path is mostly at least a minor perf gain so this is more useful for quality testing
typedef float16_t lpfloat;
typedef float16_t2 lpfloat2;
typedef float16_t3 lpfloat3;
typedef float16_t4 lpfloat4;
typedef float16_t3x3 lpfloat3x3;
#	endif
#else
typedef float lpfloat;
typedef float2 lpfloat2;
typedef float3 lpfloat3;
typedef float4 lpfloat4;
typedef float3x3 lpfloat3x3;
#endif

///////////////////////////////////////////////////////////////////////////////

#include "../Common/DeferredShared.hlsli"

cbuffer SSGICB : register(b1)
{
	float4x4 PrevInvViewMat[2];
	float4 NDCToViewMul;
	float4 NDCToViewAdd;
	float4 NDCToViewMul_x_PixelSize;

	float2 FrameDim;
	float2 RcpFrameDim;
	uint FrameIndex;

	uint NumSlices;
	uint NumSteps;
	float DepthMIPSamplingOffset;

	float EffectRadius;
	float EffectFalloffRange;
	float ThinOccluderCompensation;
	float Thickness;
	float2 DepthFadeRange;
	float DepthFadeScaleConst;

	float BackfaceStrength;
	float GIBounceFade;
	float GIDistanceCompensation;
	float GICompensationMaxDist;

	float AOPower;
	float GIStrength;

	float DepthDisocclusion;
	uint MaxAccumFrames;

	float pad;
};

SamplerState samplerPointClamp : register(s0);
SamplerState samplerLinearClamp : register(s1);

///////////////////////////////////////////////////////////////////////////////

#ifdef HALF_RES
const static float res_scale = .5;
#	define READ_DEPTH(tex, px) tex.Load(int3(px, 1))
#	define FULLRES_LOAD(tex, px, uv, samp) tex.SampleLevel(samp, uv, 0)
#else
const static float res_scale = 1.;
#	define READ_DEPTH(tex, px) tex[px]
#	define FULLRES_LOAD(tex, px, uv, samp) tex[px]
#endif

#ifdef VR
#	define GET_EYE_IDX(uv) (uv.x > 0.5)
#else
#	define GET_EYE_IDX(uv) (0)
#endif

///////////////////////////////////////////////////////////////////////////////

#define ISNAN(x) (!(x < 0.f || x > 0.f || x == 0.f))

// http://h14s.p5r.org/2012/09/0x5f3759df.html, [Drobot2014a] Low Level Optimizations for GCN, https://blog.selfshadow.com/publications/s2016-shading-course/activision/s2016_pbs_activision_occlusion.pdf slide 63
lpfloat FastSqrt(float x)
{
	return (lpfloat)(asfloat(0x1fbd1df5 + (asint(x) >> 1)));
}

// input [-1, 1] and output [0, PI], from https://seblagarde.wordpress.com/2014/12/01/inverse-trigonometric-functions-gpu-optimization-for-amd-gcn-architecture/
lpfloat FastACos(lpfloat inX)
{
	const lpfloat PI = 3.141593;
	const lpfloat HALF_PI = 1.570796;
	lpfloat x = abs(inX);
	lpfloat res = -0.156583 * x + HALF_PI;
	res *= FastSqrt(1.0 - x);
	return (inX >= 0) ? res : PI - res;
}

///////////////////////////////////////////////////////////////////////////////

// Inputs are screen XY and viewspace depth, output is viewspace position
float3 ScreenToViewPosition(const float2 screenPos, const float viewspaceDepth, const uint eyeIndex)
{
	const float2 _mul = eyeIndex == 0 ? NDCToViewMul.xy : NDCToViewMul.zw;
	const float2 _add = eyeIndex == 0 ? NDCToViewAdd.xy : NDCToViewAdd.zw;

	float3 ret;
	ret.xy = (_mul * screenPos.xy + _add) * viewspaceDepth;
	ret.z = viewspaceDepth;
	return ret;
}

float ScreenToViewDepth(const float screenDepth)
{
	return (CameraData.w / (-screenDepth * CameraData.z + CameraData.x));
}

float3 ViewToWorldPosition(const float3 pos, const float4x4 invView)
{
	float4 worldpos = mul(invView, float4(pos, 1));
	return worldpos.xyz / worldpos.w;
}

float3 ViewToWorldVector(const float3 vec, const float4x4 invView)
{
	return mul((float3x3)invView, vec);
}

///////////////////////////////////////////////////////////////////////////////

// "Efficiently building a matrix to rotate one vector to another"
// http://cs.brown.edu/research/pubs/pdfs/1999/Moller-1999-EBA.pdf / https://dl.acm.org/doi/10.1080/10867651.1999.10487509
// (using https://github.com/assimp/assimp/blob/master/include/assimp/matrix3x3.inl#L275 as a code reference as it seems to be best)
lpfloat3x3 RotFromToMatrix(lpfloat3 from, lpfloat3 to)
{
	const lpfloat e = dot(from, to);
	const lpfloat f = abs(e);  //(e < 0)? -e:e;

	// WARNING: This has not been tested/worked through, especially not for 16bit floats; seems to work in our special use case (from is always {0, 0, -1}) but wouldn't use it in general
	if (f > lpfloat(1.0 - 0.0003))
		return lpfloat3x3(1, 0, 0, 0, 1, 0, 0, 0, 1);

	const lpfloat3 v = cross(from, to);
	/* ... use this hand optimized version (9 mults less) */
	const lpfloat h = (1.0) / (1.0 + e); /* optimization by Gottfried Chen */
	const lpfloat hvx = h * v.x;
	const lpfloat hvz = h * v.z;
	const lpfloat hvxy = hvx * v.y;
	const lpfloat hvxz = hvx * v.z;
	const lpfloat hvyz = hvz * v.y;

	lpfloat3x3 mtx;
	mtx[0][0] = e + hvx * v.x;
	mtx[0][1] = hvxy - v.z;
	mtx[0][2] = hvxz + v.y;

	mtx[1][0] = hvxy + v.z;
	mtx[1][1] = e + h * v.y * v.y;
	mtx[1][2] = hvyz - v.x;

	mtx[2][0] = hvxz - v.y;
	mtx[2][1] = hvyz + v.x;
	mtx[2][2] = e + hvz * v.z;

	return mtx;
}

#endif