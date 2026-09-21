"""User revision: inhabited hull grooves, no exposed buildings; self-lit dark metal."""
import bpy, math, random
from mathutils import Vector, Matrix
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene=bpy.context.scene
assert scene.get('ship_export'), 'Select LUMEN scene'
root=next(o for o in scene.objects if o.name.startswith('Ship orientation — Y-up to Z-up'))
source=open(ROOT+'/Tools/Blender/build_cityship.py').read()
for variable,name in [('hull','Titanium ceramic'),('edge','Warm silver'),('blue','Petrol blue plating'),('dark','Recessed machinery'),('amber','Apartment windows'),('ice','Transit lights'),('engine','Ion engine')]:
    globals()[variable]=bpy.data.materials['Lumen / '+name]
exec(source[source.index('def mesh('):source.index('# An oval lenticular ring')])
# Preserve the old construction nondestructively, but exclude it from the scene/export.
prefixes=('CITY DISTRICTS','District architecture','Radial armor','Oval pressure hull','Recessed city window','Ventral service building','Lower deck windows','Ventral inset armor','Command citadel tier','Citadel observation gallery','Lower belt reinforcement','Ventral armored rib','Transit trunk')
for o in list(scene.objects):
    if o.name.startswith(prefixes):
        o.hide_render=True; o.hide_set(True); o['ship_skip_export']=True
# Remove only geometry made by this revision when rerunning it.
for o in list(scene.objects):
    if o.get('groove_revision'): bpy.data.objects.remove(o,do_unlink=True)
old_objects=set(scene.objects)
for mat,rgb,rough in [(hull,(.10,.14,.17),.32),(edge,(.20,.23,.25),.30),(blue,(.045,.10,.13),.38)]:
    mat['ship_rgb']=rgb; mat['ship_roughness']=rough
    p=mat.node_tree.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*rgb,1); p.inputs['Roughness'].default_value=rough; p.inputs['Metallic'].default_value=.88
# Lathed oval hull with actual inset horizontal channels on its outer face.
levels=[-10,-7,-4,0,4,7,10]
ys=sorted(set([-12+i*.25 for i in range(97)]+[y+d for y in levels for d in [-.48,-.32,.32,.48]]))
profile=[]
for y in ys:
    radius=.60+.40*math.sqrt(max(0,1-(y/12)**2))
    distance=min(abs(y-level) for level in levels)
    cut=.018*min(1,max(0,(.48-distance)/.16))
    profile.append((radius-cut,y))
# Inner wall closes the open throat; upper and lower rim connect continuously.
for i in range(1,65):
    y=12-i*24/65; profile.append((.60-.40*math.sqrt(max(0,1-(y/12)**2)),y))
na=224; nv=len(profile); verts=[]; faces=[]
for a in range(na):
    t=a*math.tau/na
    for r,y in profile: verts.append((72*r*math.cos(t),y,136*r*math.sin(t)))
for a in range(na):
    for j in range(nv): faces.append((a*nv+j,a*nv+(j+1)%nv,((a+1)%na)*nv+(j+1)%nv,((a+1)%na)*nv+j))
o=mesh('Grooved oval pressure hull',verts,faces,hull,smooth=True)
# Windows are set back inside the channels, behind their overhanging lips.
rng=random.Random(9982)
for level in levels:
    verts=[]; faces=[]; indices=[]
    r=.60+.40*math.sqrt(1-(level/12)**2)-.016
    for k in range(520):
        if rng.random()<.33: continue
        a=k*math.tau/520+.0012; b=a+.0065
        base=len(verts)
        for t,y in [(a,level-.16),(b,level-.16),(b,level+.16),(a,level+.16)]:
            verts.append((72*r*math.cos(t),y,136*r*math.sin(t)))
        faces.append(tuple(range(base,base+4))); indices.append(0 if rng.random()<.88 else 1)
    mesh('Inset horizontal inhabited deck',verts,faces,amber,indices,[amber,ice])
# Low, horizontal bridge slot replaces the tiered building silhouette.
for side in [-1,1]:
    box('Inset bridge glazing',(side*6.52,16.8,-4),(.035,.30,56),ice,0)
# Visible lamp emitters match fixed local light positions in Ship.metal.
lamps=[((-45,16,-46),ice),((44,15,18),None),((-18,15,95),ice),((18,15,95),ice)]
red=bpy.data.materials['Lumen / Navigation beacons']
for position,mat in lamps:
    mat=mat or red
    box('Hull lamp socket',Vector(position)-Vector((0,.35,0)),(2.2,.65,3.2),dark,.15)
    box('Hull lamp emitter',position,(1.2,.14,2.2),mat,.04)
    data=bpy.data.lights.new('Local hull wash','POINT'); data.energy=800 if mat==ice else 450; data.color=(.08,.35,1) if mat==ice else (1,.08,.035); data.shadow_soft_size=1.5
    lamp=bpy.data.objects.new('Local hull wash',data); scene.collection.objects.link(lamp); lamp.parent=root; lamp.location=position
# Remove the omnipresent studio light from Blender too.
for o in scene.objects:
    if o.type=='LIGHT' and o.name.startswith(('Soft key','Warm rim')): o.hide_render=True; o.hide_set(True)
scene.world.node_tree.nodes['Background'].inputs[1].default_value=.003
for o in set(scene.objects)-old_objects: o['groove_revision']=True
scene['art_direction']='No exposed buildings. Inhabited horizontal hull grooves, dark reflective metal, local cyan/red lamps and engine light.'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/LumenCityShip.blend')
result={'scene':scene.name,'profile_sections':nv,'art_direction':scene['art_direction']}
