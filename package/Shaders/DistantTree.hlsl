#include "Common/Constants.hlsli"
#include "Common/FrameBuffer.hlsl"
#include "Common/GBuffer.hlsli"
#include "Common/MotionBlur.hlsl"
#include "Common/VR.hlsli"

struct VS_INPUT
{
	float3 Position : POSITION0;
	float2 TexCoord0 : TEXCOORD0;
	float4 InstanceData1 : TEXCOORD4;
	float4 InstanceData2 : TEXCOORD5;
	float4 InstanceData3 : TEXCOORD6;
	float4 InstanceData4 : TEXCOORD7;
#if defined(VR)
	uint InstanceID : SV_INSTANCEID;
#endif  // VR
};

struct VS_OUTPUT
{
	float4 Position : SV_POSITION0;
	float3 TexCoord : TEXCOORD0;

#if defined(RENDER_DEPTH)
	float4 Depth : TEXCOORD3;
#else
	float4 WorldPosition : POSITION1;
	float4 PreviousWorldPosition : POSITION2;
#endif  // RENDER_DEPTH
	float4 ViewPosition : POSITION3;

#if defined(VR)
	float ClipDistance : SV_ClipDistance0;  // o11
	float CullDistance : SV_CullDistance0;  // p11
	uint EyeIndex : EYEIDX0;
#endif  // VR
};

#ifdef VSHADER
cbuffer PerTechnique : register(b0)
{
	float4 FogParam : packoffset(c0);
};

cbuffer PerGeometry : register(b2)
{
#	if !defined(VR)
	row_major float4x4 WorldViewProj[1] : packoffset(c0);
	row_major float4x4 World[1] : packoffset(c4);
	row_major float4x4 PreviousWorld[1] : packoffset(c8);
#	else
	row_major float4x4 WorldViewProj[2] : packoffset(c0);
	row_major float4x4 World[2] : packoffset(c8);
	row_major float4x4 PreviousWorld[2] : packoffset(c16);
#	endif  // !VR
};

VS_OUTPUT main(VS_INPUT input)
{
	VS_OUTPUT vsout;
	uint eyeIndex = GetEyeIndexVS(
#	if defined(VR)
		input.InstanceID
#	endif  // VR
	);

	float3 scaledModelPosition = input.InstanceData1.www * input.Position.xyz;
	float3 adjustedModelPosition = 0.0.xxx;
	adjustedModelPosition.x = dot(float2(1, -1) * input.InstanceData2.xy, scaledModelPosition.xy);
	adjustedModelPosition.y = dot(input.InstanceData2.yx, scaledModelPosition.xy);
	adjustedModelPosition.z = scaledModelPosition.z;
	float4 finalModelPosition = float4(input.InstanceData1.xyz + adjustedModelPosition.xyz, 1.0);
	float4 viewPosition = mul(WorldViewProj[eyeIndex], finalModelPosition);

#	ifdef RENDER_DEPTH
	vsout.Depth.xy = viewPosition.zw;
	vsout.Depth.zw = input.InstanceData2.zw;
#	else
	vsout.WorldPosition = mul(World[eyeIndex], finalModelPosition);
	vsout.PreviousWorldPosition = mul(PreviousWorld[eyeIndex], finalModelPosition);
	vsout.ViewPosition = viewPosition;
#	endif  // RENDER_DEPTH

	vsout.Position = viewPosition;
	vsout.TexCoord = float3(input.TexCoord0.xy, FogParam.z);

#	ifdef VR
	vsout.EyeIndex = eyeIndex;
	VR_OUTPUT VRout = GetVRVSOutput(vsout.Position, eyeIndex);
	vsout.Position = VRout.VRPosition;
	vsout.ClipDistance.x = VRout.ClipDistance;
	vsout.CullDistance.x = VRout.CullDistance;
#	endif  // VR

	return vsout;
}
#endif  // VSHADER

typedef VS_OUTPUT PS_INPUT;

struct PS_OUTPUT
{
	float4 Diffuse : SV_Target0;

#if !defined(RENDER_DEPTH)
#	if defined(DEFERRED)
	float2 MotionVector : SV_Target1;
	float4 Normal : SV_Target2;
	float4 Albedo : SV_Target3;
	float4 Masks : SV_Target6;
#	endif  // DEFERRED
#endif      // !RENDER_DEPTH
};

#ifdef PSHADER
SamplerState SampDiffuse : register(s0);

Texture2D<float4> TexDiffuse : register(t0);

#	if !defined(VR)
cbuffer AlphaTestRefCB : register(b11)
{
	float AlphaTestRefRS : packoffset(c0);
}
#	endif  // !VR

cbuffer PerFrame : register(b12)
{
	float4 UnknownPerFrame1[12] : packoffset(c0);
	row_major float4x4 ScreenProj : packoffset(c12);
	row_major float4x4 PreviousScreenProj : packoffset(c16);
}

cbuffer PerTechnique : register(b0)
{
	float4 DiffuseColor : packoffset(c0);
	float4 AmbientColor : packoffset(c1);
};

const static float DepthOffsets[16] = {
	0.003921568,
	0.533333361,
	0.133333340,
	0.666666687,
	0.800000000,
	0.266666681,
	0.933333337,
	0.400000000,
	0.200000000,
	0.733333349,
	0.066666670,
	0.600000000,
	0.996078432,
	0.466666669,
	0.866666675,
	0.333333343
};

PS_OUTPUT main(PS_INPUT input)
{
	PS_OUTPUT psout;

#	if !defined(VR)
	uint eyeIndex = 0;
#	else
	uint eyeIndex = input.EyeIndex;
#	endif  // !VR

#	if defined(RENDER_DEPTH)
	uint2 temp = uint2(input.Position.xy);
	uint index = ((temp.x << 2) & 12) | (temp.y & 3);

	float depthOffset = 0.5 - DepthOffsets[index];
	float depthModifier = (input.Depth.w * depthOffset) + input.Depth.z - 0.5;

	if (depthModifier < 0) {
		discard;
	}

	float alpha = TexDiffuse.Sample(SampDiffuse, input.TexCoord.xy).w;

	if ((alpha - AlphaTestRefRS) < 0) {
		discard;
	}

	psout.Diffuse.xyz = input.Depth.xxx / input.Depth.yyy;
	psout.Diffuse.w = 0;
#	else
	float4 baseColor = TexDiffuse.Sample(SampDiffuse, input.TexCoord.xy);

#		if defined(DO_ALPHA_TEST)
	if ((baseColor.w - AlphaTestRefRS) < 0) {
		discard;
	}
#		endif  // DO_ALPHA_TEST

#		if defined(DEFERRED)
	psout.Diffuse.xyz = 0;
	psout.Diffuse.w = 1;

	psout.MotionVector = GetSSMotionVector(input.WorldPosition, input.PreviousWorldPosition, eyeIndex);

	float3 ddx = ddx_coarse(input.ViewPosition);
	float3 ddy = ddy_coarse(input.ViewPosition);
	float3 normal = normalize(cross(ddx, ddy));

	psout.Normal.xy = EncodeNormal(normal);
	psout.Normal.zw = 0;

	psout.Albedo = float4(baseColor.xyz * 0.5, 1);
	psout.Masks = float4(0, 0, 1, 0);
#		else
	psout.Diffuse = float4((input.TexCoord.zzz * DiffuseColor.xyz + AmbientColor.xyz) * baseColor.xyz, 1.0);
#		endif  // DEFERRED
#	endif      // RENDER_DEPTH

	return psout;
}
#endif  // PSHADER
