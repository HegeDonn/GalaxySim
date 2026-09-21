#include <metal_stdlib>
using namespace metal;

struct CabinVertexData { float4 position; float4 normal; float4 color; float4 detail; };
struct CabinUniformData { float4x4 viewProjection; float4 eye; float4 flight; };
struct CabinRaster {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 color;
    float4 detail;
};
vertex CabinRaster cabinVertex(uint id [[vertex_id]],
    const device CabinVertexData* mesh [[buffer(0)]], constant CabinUniformData& u [[buffer(1)]]) {
    CabinVertexData v = mesh[id];
    CabinRaster out;
    out.position = u.viewProjection * v.position;
    out.world = v.position.xyz;
    out.normal = v.normal.xyz;
    out.color = v.color;
    out.detail = v.detail;
    return out;
}
float cabinLine(float value, float width, float aa) {
    return 1.0 - smoothstep(width, width + aa, abs(value));
}
float cabinRect(float2 p, float2 lo, float2 hi, float aa) {
    float2 d = max(lo-p, p-hi);
    return 1.0-smoothstep(0.0, aa, max(d.x,d.y));
}
// Seven-segment numerals remain legible on the small physical instrument.
float cabinDigit(float2 p, int digit, float aa) {
    const ushort mask[10] = {63,6,91,79,102,109,125,7,127,111};
    ushort bits=mask[clamp(digit,0,9)];
    float result=0.0;
    if(bits&1) result+=cabinRect(p,float2(0.15,0.86),float2(0.75,0.98),aa);
    if(bits&2) result+=cabinRect(p,float2(0.73,0.52),float2(0.87,0.88),aa);
    if(bits&4) result+=cabinRect(p,float2(0.73,0.10),float2(0.87,0.46),aa);
    if(bits&8) result+=cabinRect(p,float2(0.15,0.00),float2(0.75,0.12),aa);
    if(bits&16) result+=cabinRect(p,float2(0.03,0.10),float2(0.17,0.46),aa);
    if(bits&32) result+=cabinRect(p,float2(0.03,0.52),float2(0.17,0.88),aa);
    if(bits&64) result+=cabinRect(p,float2(0.15,0.43),float2(0.75,0.55),aa);
    return min(result,1.0);
}
float cabinNumber(float2 uv, float2 origin, float height, float value, int decimals, float aa) {
    float result=0.0;
    int number=int(clamp(value,0.0,99.999)*(decimals==4?10000.0:1000.0)+0.5);
    int decimalAfter=5-decimals;
    int divisor=10000;
    for(int i=0;i<5;i++) {
        float x=origin.x+float(i)*height*0.65+(i>=decimalAfter?height*0.25:0.0);
        float2 p=(uv-float2(x,origin.y))/float2(height*0.55,height);
        result+=cabinDigit(p,(number/divisor)%10,aa/height);
        divisor/=10;
    }
    result+=cabinRect(uv,origin+float2(height*(float(decimalAfter)*0.65-0.08),0),origin+float2(height*(float(decimalAfter)*0.65+0.02),height*0.10),aa);
    return min(result,1.0);
}
float3 cabinScreen(float2 uv, float variant, float beta, float time) {
    float aa = max(length(fwidth(uv)), 0.0015);
    float3 cyan = float3(0.15, 0.77, 0.85);
    float3 amber = float3(1.0, 0.48, 0.15);
    float3 color = float3(0.006,0.025,0.032);
    // Header and margin rails give each instrument an intentional hierarchy.
    color += cyan * cabinRect(uv,float2(0.055,0.89),float2(0.42,0.91),aa)*0.55;
    color += cyan * cabinLine(uv.y-0.84,0.001,aa)*0.23;
    for (int i=0;i<7;i++) {
        float x=0.06+float(i)*0.038;
        color += cyan*cabinRect(uv,float2(x,0.94),float2(x+0.017,0.969),aa)*0.38;
    }
    if (variant < 0.5) {
        float2 p=(uv-float2(0.5,0.43))*float2(1.0,1.08);
        float r=length(p);
        float rings = cabinLine(r-0.14,0.001,aa)+cabinLine(r-0.27,0.001,aa)+cabinLine(r-0.38,0.001,aa);
        color += cyan*rings*0.35;
        color += cyan*(cabinLine(p.x,0.001,aa)+cabinLine(p.y,0.001,aa))*0.16;
        // A ship-frame orientation reticle, not fabricated star detections.
        color += amber*cabinLine(r-(0.08+0.28*beta),0.003,aa)*0.55;
        color += amber*cabinLine(p.x-abs(p.y)*0.65,0.004,aa)*cabinRect(p,float2(-0.04,-0.06),float2(0.04,0.06),aa)*0.7;
    } else if (variant < 1.5) {
        // Top: beta (v/c), lower: Lorentz gamma; both follow actual flight state.
        color += cyan*cabinNumber(uv,float2(0.10,0.57),0.20,beta,4,aa)*0.95;
        float gamma=rsqrt(max(0.000001,1.0-beta*beta));
        color += amber*cabinNumber(uv,float2(0.10,0.29),0.15,gamma,3,aa)*0.8;
        color += cyan*cabinRect(uv,float2(0.08,0.13),float2(0.90,0.185),aa)*0.12;
        color += cyan*cabinRect(uv,float2(0.08,0.13),float2(0.08+0.82*beta,0.185),aa)*0.7;
    } else {
        float gridX=cabinLine(fract(uv.x*10.0)-0.5,0.008,aa*10.0);
        float gridY=cabinLine(fract(uv.y*8.0)-0.5,0.008,aa*8.0);
        color += cyan*(gridX+gridY)*0.06;
        float wave=0.45+0.12*sin(uv.x*12.0-time*0.3)+0.035*sin(uv.x*39.0);
        color += cyan*cabinLine(uv.y-wave,0.003,aa)*0.8;
        color += amber*cabinLine(uv.y-(0.3+uv.x*0.28),0.002,aa)*0.65;
    }
    float edge=min(min(uv.x,1.0-uv.x),min(uv.y,1.0-uv.y));
    color *= smoothstep(0.008,0.028,edge);
    return color;
}
float3 cabinLight(float3 position, float3 normal, float3 view, float3 source, float3 tint, float roughness) {
    float3 delta=source-position;
    float d2=dot(delta,delta);
    float3 light=normalize(delta);
    float ndl=max(dot(normal,light),0.0);
    float spec=pow(max(dot(normal,normalize(light+view)),0.0),mix(90.0,14.0,roughness));
    return tint*(ndl+spec*0.32)/(1.0+d2*0.32);
}
fragment float4 cabinFragment(CabinRaster in [[stage_in]], constant CabinUniformData& u [[buffer(1)]]) {
    float material=in.detail.x;
    if(material>1.5 && material<2.5) return float4(cabinScreen(in.detail.zw,in.detail.y,u.flight.x,u.flight.y),1);
    if(material>0.5 && material<1.5) return float4(in.color.rgb*0.88,1);
    float3 n=normalize(in.normal);
    float3 v=normalize(u.eye.xyz-in.world);
    // Double-sided interior geometry keeps hand-built panels robust.
    if(dot(n,v)<0.0) n=-n;
    float roughness=material>2.5?0.95:0.48;
    float3 illumination=float3(0.25,0.29,0.34);
    illumination += cabinLight(in.world,n,v,float3(0,1.65,-0.65),float3(0.90,0.95,1.0),roughness);
    illumination += cabinLight(in.world,n,v,float3(-1.4,0.3,-1.9),float3(1.0,0.47,0.20)*1.2,roughness);
    illumination += cabinLight(in.world,n,v,float3(1.4,-0.35,-1.65),float3(0.15,0.66,0.86)*1.2,roughness);
    illumination += cabinLight(in.world,n,v,float3(0,-0.6,-1.5),float3(0.13,0.4,0.5)*0.65,roughness);
    float grain=fract(sin(dot(floor(in.world*950.0),float3(12.9898,78.233,39.425)))*43758.5453);
    // Blender exports local ambient visibility in vertex alpha. Procedural
    // fallback vertices use 1, so this remains compatible with both meshes.
    float visibility = clamp(in.color.a, 0.25, 1.0);
    float3 color=in.color.rgb*illumination*(0.985+grain*0.03)*visibility;
    float3 keyDirection=normalize(float3(-1.2,1.25,-0.7)-in.world);
    float edgeSpec=pow(max(dot(n,normalize(keyDirection+v)),0.0),48.0);
    if(material < 2.5) color += float3(0.30,0.36,0.39)*edgeSpec*0.16*visibility;
    if(material>2.5) color *= 0.93+0.07*sin(in.world.y*190.0)*sin(in.world.x*190.0);
    // Gentle output curve: fixtures remain restrained while dark facets retain shape.
    color=color/(1.0+color*0.4);
    return float4(color,1);
}

struct CabinSensorData { float4 a; float4 b; float4 c; };

// Uses the existing HDR/PSF textures, never reads back the drawable. The opaque
// cabin depth buffer protects consoles and canopy ribs from exterior leakage.
fragment float4 cabinGlassFragment(CabinRaster in [[stage_in]],
    constant CabinUniformData& u [[buffer(1)]],
    constant CabinSensorData& sensor [[buffer(2)]],
    texture2d<float> scene [[texture(0)]],
    texture2d<float> blurred [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 screenUV = in.position.xy / u.flight.zw;
    float3 n = normalize(in.normal);
    float3 v = normalize(u.eye.xyz - in.world);
    float fresnel = pow(1.0 - abs(dot(n, v)), 5.0);
    float2 paneUV = clamp(in.detail.zw, 0.0, 1.0);
    float edgeDistance = min(min(paneUV.x, 1.0-paneUV.x), min(paneUV.y, 1.0-paneUV.y));
    float edge = 1.0-smoothstep(0.005, 0.065, edgeDistance);
    // A tiny pane-local bend; soft PSF sampling adds frost without extra passes.
    float2 bend = (paneUV-0.5) * (0.0007 + fresnel*0.0012);
    float2 uv = screenUV + bend;
    float3 soft = blurred.sample(s, uv).rgb;
    // Windscreen stays clearer than the load-bearing observation floor.
    float frost = in.detail.y > 1.5 ? 0.68 : (in.detail.y > 0.5 ? 0.42 : 0.16);
    float3 core = mix(scene.sample(s, uv).rgb, soft, frost);
    // The first PSF octave approximates the weak wider wings on frosted glass.
    float weight = dot(sensor.b, float4(1.0));
    float3 wings = soft * weight;
    wings += soft * 1.5 * float3(1.0,0.42,0.22) * sensor.c.z;
    float3 exposure = (core + wings*sensor.a.w) / (1.0 + weight*sensor.a.w*0.5);
    exposure *= sensor.a.x;
    float3 e = pow(max(exposure,0.0),sensor.a.z);
    float k = pow(max(sensor.a.y,1e-6),sensor.a.z);
    float3 color = e/(e+k);
    float luminance = dot(color,float3(0.2126,0.7152,0.0722));
    color = mix(float3(luminance),color,sensor.c.y);
    color = pow(clamp(color,0.0,1.0),float3(1.0/2.2));
    float2 q = screenUV-0.5;
    color *= clamp(1.0-dot(q,q)*sensor.c.x,0.0,1.0);
    // Restrained colored transmission and edge reflection make the pane visible
    // even against black space. Vertex alpha remains reserved for baked AO.
    float3 tint = mix(float3(1.0), clamp(in.color.rgb,0.0,1.0),0.13);
    color *= tint * (0.97 - 0.06*fresnel - 0.035*edge);
    color += float3(0.017,0.032,0.042)*(0.28+fresnel*0.9+edge*0.7);
    float alpha = 0.88;
    return float4(color*alpha,alpha);
}
