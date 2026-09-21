"""Deterministic city-ship authoring. Geometry Nodes controls district density/seed."""
import bpy, math, random
from mathutils import Vector, Matrix
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
rng=random.Random(74021)
scene=bpy.data.scenes.new('LUMEN — City Ship'); bpy.context.window.scene=scene
scene['ship_export']=True
root=bpy.data.objects.new('Ship orientation — Y-up to Z-up',None); scene.collection.objects.link(root)
materials=[]
def material(name,rgb,kind=0,rough=.48):
    m=bpy.data.materials.new('Lumen / '+name); m.diffuse_color=(*rgb,1); m.use_nodes=True
    m['ship_rgb']=rgb; m['ship_kind']=kind; m['ship_roughness']=rough
    b=m.node_tree.nodes.get('Principled BSDF'); b.inputs['Base Color'].default_value=(*rgb,1)
    b.inputs['Metallic'].default_value=.75 if kind==0 else .15; b.inputs['Roughness'].default_value=rough
    if kind in (1,2):
        b.inputs['Emission Color'].default_value=(*rgb,1); b.inputs['Emission Strength'].default_value=3 if kind==1 else 6
    materials.append(m); return m
hull=material('Titanium ceramic',(.27,.34,.38),0,.42)
edge=material('Warm silver',(.42,.44,.41),0,.40)
blue=material('Petrol blue plating',(.08,.23,.28),0,.52)
dark=material('Recessed machinery',(.025,.041,.052),3,.83)
amber=material('Apartment windows',(.95,.55,.20),1)
ice=material('Transit lights',(.18,.68,.92),1)
engine=material('Ion engine',(.12,.58,1.0),2)
red=material('Navigation beacons',(.88,.14,.035),1)

def mesh(name,verts,faces,m,indices=None,allmats=None,smooth=False):
    data=bpy.data.meshes.new(name); data.from_pydata(verts,[],faces); data.update()
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); o.parent=root
    for mat in (allmats or [m]): data.materials.append(mat)
    if indices:
        for p,i in zip(data.polygons,indices): p.material_index=i
    for p in data.polygons: p.use_smooth=smooth
    return o

def box(name,c,size,m=hull,bevel=.3,basis=None):
    h=Vector(size)*.5
    vs=[(x*h.x,y*h.y,z*h.z) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    o=mesh(name,vs,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)],m); o.location=c
    if basis: o.rotation_euler=Matrix(basis).transposed().to_euler()
    if bevel:
        mod=o.modifiers.new('Machined edges','BEVEL'); mod.width=min(bevel,min(size)*.3); mod.segments=2
        mod=o.modifiers.new('Weighted normals','WEIGHTED_NORMAL'); mod.keep_sharp=True
    return o

def tube(name,points,radius,m):
    data=bpy.data.curves.new(name,'CURVE'); data.dimensions='3D'; data.resolution_u=8
    spl=data.splines.new('POLY'); spl.points.add(len(points)-1)
    for p,co in zip(spl.points,points): p.co=(*co,1)
    data.bevel_depth=radius; data.bevel_resolution=2
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); data.materials.append(m); o.parent=root; return o

def beam(name,a,b,width,depth,m=hull):
    a,b=Vector(a),Vector(b); y=(b-a).normalized(); helper=Vector((0,0,1)) if abs(y.z)<.95 else Vector((0,1,0))
    x=y.cross(helper).normalized(); z=x.cross(y).normalized()
    return box(name,(a+b)*.5,(width,(b-a).length,depth),m,.25,(x,y,z))

def surface(theta,r,lift=0):
    return Vector((72*r*math.cos(theta),12*math.sqrt(max(0,1-((r-.60)/.40)**2))+lift,136*r*math.sin(theta)))
# An oval lenticular ring with a genuine open throat. No boolean fragments.
vs=[]; fs=[]; na=160; nb=24
for a in range(na):
    t=a*2*math.pi/na
    for b in range(nb):
        p=b*2*math.pi/nb; r=.60+.40*math.cos(p)
        vs.append((72*r*math.cos(t),12*math.sin(p),136*r*math.sin(t)))
for a in range(na):
    for b in range(nb): fs.append((a*nb+b,((a+1)%na)*nb+b,((a+1)%na)*nb+(b+1)%nb,a*nb+(b+1)%nb))
mesh('Oval pressure hull with open central throat',vs,fs,dark,smooth=True)
# Individually stepped armor sectors. Gaps between them form continuous city grooves.
for row,(inner,outer) in enumerate([(.215,.38),(.415,.56),(.60,.75),(.79,.99)]):
    segments=48 if row>0 else 32
    for sector in range(segments):
        a=sector*2*math.pi/segments+.009; b=(sector+1)*2*math.pi/segments-.009
        points=[]
        for r in [inner,outer]:
            for j in range(5): points.append(surface(a+(b-a)*j/4,r,1.05+row*.12))
        top=[0,1,2,3,4,9,8,7,6,5]; verts=[tuple(p) for p in points]+[tuple(p-Vector((0,1.6,0))) for p in points]
        faces=[(j,j+1,j+6,j+5) for j in range(4)]
        for j in range(len(top)): faces.append((top[j],top[(j+1)%len(top)],top[(j+1)%len(top)]+10,top[j]+10))
        faces.extend([(10+j,15+j,16+j,11+j) for j in range(4)])
        mesh('Radial armor / district %d.%d'%(row,sector),verts,faces,blue if (sector+row*3)%9==0 else (edge if sector%7==0 else hull))
# Hundreds of lit slots buried in perimeter decks, each separated by dark mullions.
for r in [.395,.578,.770,.995]:
    for k in range(240):
        if rng.random()<.20: continue
        a=k*2*math.pi/240+.002; b=a+.013
        if r<.98:
            p=surface(a,r,.34); q=surface(b,r,.34); lift=Vector((0,.5,0))
        else:
            p=Vector((72*r*math.cos(a),-.2,136*r*math.sin(a))); q=Vector((72*r*math.cos(b),-.2,136*r*math.sin(b))); lift=Vector((0,.48,0))
        mesh('Recessed city window', [p,q,q+lift,p+lift],[(0,1,2,3)],amber if rng.random()<.78 else ice)
# Lower hull belts and reinforcing ribs are visible while orbiting under the ship.
for y,r in [(-2.8,.974),(-5.2,.94),(-8.0,.875)]:
    points=[(72*r*math.cos(t*math.pi/64),y,136*r*math.sin(t*math.pi/64)) for t in range(129)]
    tube('Lower belt reinforcement',points,.5,blue)
for k in range(28):
    a=k*2*math.pi/28
    points=[]
    for j in range(9):
        r=.25+j*.09; p=surface(a,r); p.y=-p.y-.3; points.append(p)
    tube('Ventral armored rib',points,.42,hull)
# A city module containing literal rows of windows, instanced with Geometry Nodes.
verts=[]; faces=[]; mids=[]
def addquad(points,matindex):
    base=len(verts); verts.extend(points); faces.append(tuple(range(base,base+len(points)))); mids.append(matindex)
def cuboid(c,size,mi):
    c=Vector(c); h=Vector(size)*.5
    p=[tuple(c+Vector((x*h.x,y*h.y,z*h.z))) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    for face in [(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)]: addquad([p[i] for i in face],mi)
cuboid((0,.47,0),(1,.94,1),0); cuboid((0,.99,0),(.85,.10,.85),1); cuboid((.08,1.08,-.08),(.30,.10,.38),1)
for level in [.22,.43,.64,.83]:
    for cell in range(4):
        p=-.40+cell*.22; q=p+.115
        for side in [-1,1]:
            addquad([(p,level,side*.503),(q,level,side*.503),(q,level+.047,side*.503),(p,level+.047,side*.503)],2 if cell!=2 else 3)
            addquad([(side*.503,level,p),(side*.503,level,q),(side*.503,level+.047,q),(side*.503,level+.047,p)],2 if cell!=1 else 3)
module=mesh('District architecture / instance source',verts,faces,dark,allmats=[dark,hull,amber,ice],indices=mids)
# Source object lives away from the model; Object Info ORIGINAL ignores transform.
module.location=(0,-1000,0); module['ship_skip_export']=True; module.hide_render=True
points=[]; scales=[]; rotations=[]
for k in range(660):
    a=rng.uniform(0,math.tau); r=rng.uniform(.44,.88)
    # Leave two broad transit corridors and machinery clearances.
    if abs(math.cos(a))<.16 or (.55<r<.62): continue
    p=surface(a,r,2.0); points.append(tuple(p))
    h=rng.uniform(1.3,5.5)*(1.65 if r<.60 else 1)
    scales.append((rng.uniform(1.1,2.7),h,rng.uniform(1.7,4.2)))
    rotations.append((0,-a,0))
pointmesh=mesh('CITY DISTRICTS — Geometry Nodes',points,[],dark)
for name,values in [('district_scale',scales),('district_rotation',rotations)]:
    attr=pointmesh.data.attributes.new(name,'FLOAT_VECTOR','POINT')
    for d,v in zip(attr.data,values): d.vector=v
node=bpy.data.node_groups.new('LUMEN / procedural city districts','GeometryNodeTree')
node.interface.new_socket(name='Geometry',in_out='INPUT',socket_type='NodeSocketGeometry'); node.interface.new_socket(name='Geometry',in_out='OUTPUT',socket_type='NodeSocketGeometry')
s=node.interface.new_socket(name='Density',in_out='INPUT',socket_type='NodeSocketFloat'); s.default_value=1; s.min_value=0; s.max_value=1
s=node.interface.new_socket(name='Seed',in_out='INPUT',socket_type='NodeSocketInt'); s.default_value=74021
n=node.nodes; l=node.links
inp=n.new('NodeGroupInput'); inp.location=(-650,100)
out=n.new('NodeGroupOutput'); out.location=(450,100)
info=n.new('GeometryNodeObjectInfo'); info.location=(-450,-220); info.inputs['Object'].default_value=module; info.transform_space='ORIGINAL'
scale=n.new('GeometryNodeInputNamedAttribute'); scale.data_type='FLOAT_VECTOR'; scale.inputs['Name'].default_value='district_scale'; scale.location=(-230,-230)
rot=n.new('GeometryNodeInputNamedAttribute'); rot.data_type='FLOAT_VECTOR'; rot.inputs['Name'].default_value='district_rotation'; rot.location=(-230,-400)
randomNode=n.new('FunctionNodeRandomValue'); randomNode.data_type='FLOAT'; randomNode.location=(-650,400); l.new(inp.outputs['Seed'],randomNode.inputs['Seed'])
compare=n.new('ShaderNodeMath'); compare.operation='GREATER_THAN'; compare.location=(-430,350); l.new(randomNode.outputs['Value'],compare.inputs[0]); l.new(inp.outputs['Density'],compare.inputs[1])
delete=n.new('GeometryNodeDeleteGeometry'); delete.domain='POINT'; delete.location=(-220,150); l.new(inp.outputs['Geometry'],delete.inputs['Geometry']); l.new(compare.outputs[0],delete.inputs['Selection'])
inst=n.new('GeometryNodeInstanceOnPoints'); inst.location=(0,100); l.new(delete.outputs['Geometry'],inst.inputs['Points']); l.new(info.outputs['Geometry'],inst.inputs['Instance']); l.new(scale.outputs['Attribute'],inst.inputs['Scale']); l.new(rot.outputs['Attribute'],inst.inputs['Rotation'])
real=n.new('GeometryNodeRealizeInstances'); real.location=(230,100); l.new(inst.outputs['Instances'],real.inputs['Geometry']); l.new(real.outputs['Geometry'],out.inputs['Geometry'])
mod=pointmesh.modifiers.new('Edit city density and seed','NODES'); mod.node_group=node
# Bridges over the open throat and a tiered command citadel.
for z in [-37,34]: beam('Open-throat bridge',(-28,10,z),(28,10,z),4.0,3.8,blue)
box('Command island',(0,15,0),(13,7,76),blue,1.2)
for level in range(5):
    w=13-level*1.8; d=28-level*3.2; y=20+level*3.0
    box('Command citadel tier',(0,y,19),(w,2.6,d),hull,.4)
    for side in [-1,1]:
        box('Citadel observation gallery',(side*(w/2+.025),y+.1,19),(.04,.38,d*.78),ice,.0)
        box('Citadel observation gallery',(0,y+.1,19+side*(d/2+.025)),(w*.82,.38,.04),amber,.0)
# Deep open bays between the central island and oval hull make the silhouette porous.
for side in [-1,1]:
    box('Forward sensor cheek',(side*12,3,-127),(10,7,31),blue,2)
    box('Bow spear',(side*5,1,-143),(5,3,22),hull,.8)
    beam('Outrigger pylon',(side*58,0,38),(side*84,0,54),5,5,blue)
    box('Outrigger city pod',(side*83,1,55),(11,9,38),hull,2)
    for row in [-1,1]: box('Pod city band',(side*88.6,row*1.6,55),(.06,.55,29),amber,0)
    # Dish + thin antenna forest contrasts with the broad oval silhouette.
    for j in range(5):
        x=side*(25+j*3); z=33+j*4; y=surface(math.atan2(z/136,x/72),math.sqrt((x/72)**2+(z/136)**2)).y+3
        beam('Antenna mast',(x,y,z),(x,y+8+j*1.8,z),.35,.35,edge)
        beam('Antenna spreader',(x-2,y+5+j,z),(x+2,y+5+j,z),.14,.14,edge)
        box('Mast beacon',(x,y+8+j*1.8,z),(.6,.6,.6),red,.1)
# Engine nacelles: a ring mesh with recessed luminous core, facing aft (+Z).
for x in [-31,31]:
    box('Engine nacelle',(x,-3,110),(21,15,41),blue,3.0)
    for z in [99,105,111,117]: box('Engine armor collar',(x,-3,z),(22,16,1.1),edge,.3)
    for radius,depth,mat in [(8.5,132,dark),(7.0,133,edge),(5.7,134,engine)]:
        vs=[(x,-3,depth)]+[(x+radius*math.cos(i*math.tau/48),-3+radius*.70*math.sin(i*math.tau/48),depth) for i in range(48)]
        mesh('Engine recessed aperture',vs,[(0,i+1,(i+1)%48+1) for i in range(48)],mat)
    for y in [-5.3,-3,-.7]: box('Engine louver',(x,y,134.1),(10,.4,.7),dark,.15)
    tube('Engine service line',[(x,-10,88),(x,-10,110),(x,-8,125)],.30,ice)
# Thin equatorial navigation accents and hull registry.
for side in [-1,1]:
    tube('Transit trunk',[(side*57,10,-55),(side*61,9,-25),(side*61,9,25),(side*54,11,55)],.22,ice)
text=bpy.data.curves.new('LUMEN hull registry','FONT'); text.body='L U M E N'; text.size=5; text.extrude=.025; text.align_x='CENTER'
o=bpy.data.objects.new('LUMEN registry',text); scene.collection.objects.link(o); o.parent=root; o.location=(0,7,-109); o.rotation_euler=(math.pi/2,0,0); text.materials.append(edge)
# Blender is upright Z-up; export explicitly removes this orientation root.
root.rotation_euler=(math.pi/2,0,0)
c=bpy.data.cameras.new('City ship showcase'); cam=bpy.data.objects.new('City ship showcase',c); scene.collection.objects.link(cam); cam.parent=root
cam.location=(210,155,245); cam.rotation_euler=(Vector((0,0,0))-cam.location).to_track_quat('-Z','Y').to_euler(); c.lens=42; c.clip_end=3000; scene.camera=cam
for name,pos,power,color,size in [('Soft key',(-170,230,-90),1500000,(.78,.87,1),220),('Warm rim',(150,90,120),900000,(1,.6,.3),160)]:
    data=bpy.data.lights.new(name,'AREA'); data.energy=power; data.color=color; data.shape='DISK'; data.size=size
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); o.parent=root; o.location=pos; o.rotation_euler=(-Vector(pos)).to_track_quat('-Z','Y').to_euler()
scene.world=bpy.data.worlds.new('Deep space studio'); scene.world.use_nodes=True; scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.08,.12,.18,1); scene.world.node_tree.nodes['Background'].inputs[1].default_value=.3
scene.render.engine='CYCLES'; scene.cycles.samples=32; scene.render.resolution_x=1600; scene.render.resolution_y=1000; scene.render.resolution_percentage=100
bpy.context.view_layer.update()
for window in bpy.context.window_manager.windows:
    for area in window.screen.areas:
        if area.type=='VIEW_3D': area.spaces.active.region_3d.view_perspective='CAMERA'; area.spaces.active.shading.type='MATERIAL'
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/LumenCityShip.blend')
result={'scene':scene.name,'objects':len(scene.objects),'district_instances':len(points),'node_group':node.name,'blend':bpy.data.filepath}
