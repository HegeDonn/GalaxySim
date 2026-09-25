#include <metal_stdlib>
using namespace metal;
struct PlanetUniforms {
    float4 gasMotion, gasShape;
    float4 cloudControls, materialControls, optics;
    float4 normal, up, right, axis, air, parameters, ship;
};
struct PlanetVertex { float4 position [[position]]; float2 uv; };
vertex PlanetVertex planetVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p*2-1,0,1),p};
}
float hash3(float3 p) {
    p=fract(p*0.1031);p+=dot(p,p.yzx+33.33);
    return fract((p.x+p.y)*p.z);
}
float noise3(float3 p) {
    float3 i=floor(p), f=fract(p); f=f*f*f*(f*(f*6-15)+10);
    return mix(mix(mix(hash3(i),hash3(i+float3(1,0,0)),f.x),
                   mix(hash3(i+float3(0,1,0)),hash3(i+float3(1,1,0)),f.x),f.y),
               mix(mix(hash3(i+float3(0,0,1)),hash3(i+float3(1,0,1)),f.x),
                   mix(hash3(i+float3(0,1,1)),hash3(i+1),f.x),f.y),f.z);
}
float fbm(float3 p) {
    float result=0,weight=0.53;
    for(int i=0;i<5;i++){result+=weight*noise3(p);p=p*2.03+float3(3.7,8.1,2.3);weight*=0.48;}
    return result;
}
// Move through one continuous noise volume. Low-frequency vector warping
// gently deforms the coordinates instead of dissolving between unrelated maps.
float3 weatherCoordinates(float3 p,float evolution,float distortion) {
    float3 drift=float3(0.73,-0.31,0.47)*(evolution*0.012);
    float3 q=p*0.53+drift*0.35;
    float3 warp=float3(noise3(q+float3(13,4,7)),noise3(q+float3(2,19,5)),noise3(q+float3(8,3,23)))-0.5;
    return p+drift+warp*distortion;
}
float3 turn(float3 n,float3 axis,float a) {
    return n*cos(a)+cross(axis,n)*sin(a)+axis*dot(axis,n)*(1-cos(a));
}
float cloudDensity(float3 n,float3 seed,float time,float3 axis,constant PlanetUniforms &u) {
    n=turn(n,axis,u.cloudControls.x*0.0025);
    float3 p=n*5.5+seed;
    float field=fbm(weatherCoordinates(p,u.cloudControls.y,0.75));
    return smoothstep(0.42,0.70,field)*u.cloudControls.z;
}
fragment float4 planetFragment(PlanetVertex in [[stage_in]], constant PlanetUniforms &u [[buffer(0)]]) {
    float time=u.parameters.x, kind=u.parameters.y, phase=u.parameters.w;
    float3 seed=float3(hash3(float3(u.parameters.z,u.ship.z,3)),hash3(float3(1,u.parameters.z,u.ship.z)),hash3(float3(u.ship.z,2,u.parameters.z)))*80;
    float2 xy=(in.uv*2-1)*1.07;
    float r2=dot(xy,xy), atmosphere=1.055;
    bool hasAir=u.air.w>0, gas=kind==1||kind==2, clouds=hasAir&&kind!=6&&!gas;
    float3 normal=u.normal.xyz,up=u.up.xyz,right=u.right.xyz,axis=u.axis.xyz;
    float3 light=normalize(normal*0.8-right*0.6+up*0.7),base=right*xy.x+up*xy.y;
    float3 rgb=0;float alpha=0;
    float z=sqrt(max(0.0,1-r2));
    if(r2<1) {
        float3 n=base+normal*z;
        float field=fbm(n*3.2+seed);
        float detail=fbm(n*19+seed+9);
        float3 albedo;
        float sea=0;
        if(kind==0) {
            sea=1-smoothstep(0.46,0.485,field);
            float mountains=smoothstep(0.58,0.77,field);
            float3 land=mix(float3(0.11,0.24,0.075),float3(0.33,0.29,0.21),mountains)*(0.72+detail*0.55);
            float coast=1-smoothstep(0.01,0.075,abs(field-0.47));
            land=mix(land,float3(0.44,0.39,0.22),coast*0.4);
            // Refract through animated water normals toward a shallow procedural
            // seabed. This is a thin-water approximation, not an ocean simulation.
            float3 waveNormal=normalize(n+right*sin(dot(n,float3(81,127,63))+time)*0.003*u.materialControls.z+up*sin(dot(n,float3(132,57,97))-time*0.7)*0.003*u.materialControls.z);
            float3 underwater=refract(-normal,waveNormal,1.0/1.333);
            float3 bottom=normalize(n+underwater*0.012);
            float bottomField=fbm(bottom*3.2+seed);
            float shallow=1-smoothstep(0.005,0.08,abs(bottomField-0.47));
            float3 water=mix(float3(0.015,0.055,0.13),float3(0.025,0.23,0.25),shallow*0.75);
            albedo=mix(land,water,sea);
            float ice=smoothstep(0.84,0.97,abs(dot(n,axis))+(detail-0.5)*0.10);
            albedo=mix(albedo,float3(0.72,0.83,0.85),ice);sea*=1-ice;
        } else if(gas) {
            float latitude=asin(clamp(dot(n,axis),-1.0,1.0));
            // Latitude-dependent drift gives cloud belts slightly different
            // speeds; evolving vector coordinates distort their eddies smoothly.
            float wind=0.0014*(1-u.gasShape.y+u.gasShape.y*cos(latitude*9));
            float3 weatherNormal=turn(n,axis,u.gasMotion.x*wind);
            float3 weather=weatherCoordinates(weatherNormal*u.gasMotion.w+seed,u.gasMotion.y*0.65,u.gasMotion.z);
            float swirl=fbm(weather);
            float band=0.5+0.5*sin(latitude*u.gasShape.x+(swirl-0.5)*8);
            albedo=kind==1?mix(float3(0.09,0.35,0.44),float3(0.28,0.65,0.7),band):mix(float3(0.32,0.19,0.11),float3(0.76,0.64,0.46),band);
        } else {
            float3 rock=kind==3?float3(0.37,0.36,0.34):kind==4?float3(0.4,0.32,0.45):kind==5?float3(0.32,0.37,0.12):float3(0.57,0.28,0.12);
            albedo=rock*(0.5+field*0.65+detail*0.25);
        }
        float relief=gas?0:(detail-fbm(normalize(n+light*0.005)*19+seed+9))*2;
        float diffuse=max(0.0,dot(n,light)+relief);
        rgb=albedo*(0.045+diffuse*0.95);
        if(sea>0) {
            float3 rippleNormal=normalize(n+right*sin(dot(n,float3(81,127,63))+time)*0.003*u.materialControls.z+up*sin(dot(n,float3(132,57,97))-time*0.7)*0.003*u.materialControls.z);
            float fresnel=0.025+0.975*pow(1-max(0.0,dot(n,normal)),5.0);
            // Broaden the lobe by the pixel normal footprint to avoid sparkling or
            // faceted highlights from undersampled ripple normals.
            float variance=dot(dfdx(rippleNormal),dfdx(rippleNormal))+dot(dfdy(rippleNormal),dfdy(rippleNormal));
            float roughness2=max(0.003,u.optics.x*u.optics.x+variance*2);
            float glint=pow(max(0.0,dot(rippleNormal,normalize(light+normal))),2/roughness2);
            rgb+=sea*(glint*float3(0.8,0.78,0.63)*u.materialControls.w+u.air.xyz*fresnel*0.11);
        }
        if(clouds) {
            float nl=dot(n,light), travel=-nl+sqrt(nl*nl+(1+u.cloudControls.w)*(1+u.cloudControls.w)-1);
            float shadow=cloudDensity(normalize(n+light*travel),seed,time,axis,u);
            rgb*=1-min(0.85,shadow*u.materialControls.x)*max(0.0,nl);
        }
        alpha=1-smoothstep(1-fwidth(r2),1.0,r2);
        rgb*=alpha;
    }
    if(clouds&&r2<(1+u.cloudControls.w)*(1+u.cloudControls.w)) {
        float cz=sqrt((1+u.cloudControls.w)*(1+u.cloudControls.w)-r2);float3 cn=(base+normal*cz)/(1+u.cloudControls.w);
        float cloud=cloudDensity(cn,seed,time,axis,u);
        float slope=cloud-cloudDensity(normalize(cn+light*0.006),seed,time,axis,u);
        float lighting=max(0.04,dot(cn,light)+slope*0.9);
        float opacity=min(0.95,cloud*(gas?0.24:0.86))*smoothstep(0.0,0.015,cz);
        float3 tint=mix(float3(0.9,0.94,1),u.air.xyz*0.45+0.55,kind==0?0.12:0.6);
        rgb=rgb*(1-opacity)+tint*(0.075+lighting*0.925)*opacity;
        alpha+=(1-alpha)*opacity;
    }
    if(hasAir&&r2<atmosphere*atmosphere) {
        float outer=sqrt(atmosphere*atmosphere-r2),inner=r2<1?z:-outer;
        float step=(outer-inner)/8;float depth=0;float3 scattered=0;
        for(int i=0;i<8;i++) {
            float3 p=base+normal*(inner+(float(i)+0.5)*step);
            float radius=length(p),nl=dot(p,light);
            bool shadow=nl<0&&dot(p,p)-nl*nl<1;
            float density=exp(-max(0.0,radius-1)/0.011)*u.air.w;
            float segment=density*step*10*u.materialControls.y,trans=exp(-segment);
            float illumination=shadow?0.012:max(0.08,dot(p/radius,light));
            scattered=scattered*trans+u.air.xyz*(1-trans)*illumination;
            depth+=segment;
        }
        float trans=exp(-depth);rgb=rgb*trans+scattered;alpha+=(1-alpha)*(1-trans);
    }
    // The small navigation ship stays crisp at the drawable's native resolution.
    float scale=max(0.1,1-phase*0.9);
    float2 shipPoint=(in.uv-0.5)*u.ship.y;
    shipPoint.y-=(1-phase)*(14+sin(time*3)*3);
    shipPoint/=scale;
    bool hull=shipPoint.y<18&&shipPoint.y>-12&&abs(shipPoint.x)<(18-shipPoint.y)*0.5
        && (shipPoint.y>-6||abs(shipPoint.x)>(-6-shipPoint.y)*2.5);
    float plumeLength=12+u.ship.x*40;
    float2 plume=(shipPoint-float2(0,-13-plumeLength*0.5))/float2(5,plumeLength*0.5);
    if(dot(plume,plume)<1){rgb=float3(0.95,0.39,0.06);alpha=1;}
    if(hull){rgb=float3(0.98);alpha=1;}
    return float4(clamp(rgb,0.0,1.0),clamp(alpha,0.0,1.0));
}
