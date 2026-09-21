"""Second art pass: ventral districts, recessed hangars, radar and hull detail."""
import bpy, math, random
from mathutils import Vector, Matrix
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene=bpy.context.scene
assert scene.get('ship_export'), 'Select the city ship scene'
root=next(o for o in scene.objects if o.name.startswith('Ship orientation — Y-up to Z-up'))
# Reuse the generator's geometry helpers, without executing scene creation.
source=open(ROOT+'/Tools/Blender/build_cityship.py').read()
for variable,name in [('hull','Titanium ceramic'),('edge','Warm silver'),('blue','Petrol blue plating'),('dark','Recessed machinery'),('amber','Apartment windows'),('ice','Transit lights'),('engine','Ion engine')]:
    globals()[variable]=next(m for m in bpy.data.materials if m.name=='Lumen / '+name)
exec(source[source.index('def mesh('):source.index('# An oval lenticular ring')])
rng=random.Random(98271)
for row,(r0,r1) in enumerate([(.28,.46),(.49,.68),(.71,.89)]):
    for k in range(40):
        a=k*math.tau/40+.012; b=(k+1)*math.tau/40-.012
        verts=[]
        for r in [r0,r1]:
            for j in range(4):
                p=surface(a+(b-a)*j/3,r); p.y=-p.y-.6; verts.append(p)
        mesh('Ventral inset armor',verts,[(j,j+4,j+5,j+1) for j in range(3)],blue if k%8==0 else hull)
        # Occupied lower decks, rather than a blank underside.
        if k%3!=0:
            r=(r0+r1)*.5; p=surface((a+b)*.5,r); p.y=-p.y-1.35
            o=box('Ventral service building',p,(2.6,1.7,5.2),dark,.18); o.rotation_euler.y=-(a+b)*.5
            for side in [-1,1]:
                q=Vector(p); q.x+=side*1.32
                box('Lower deck windows',q,(.045,.22,3.8),amber,0)
# Six large cargo hangars with layered framing and luminous guide lines.
for x,z in [(-30,-50),(30,-50),(-32,12),(32,12),(-26,62),(26,62)]:
    r=math.sqrt((x/72)**2+(z/136)**2); a=math.atan2(z/136,x/72); y=-surface(a,r).y-1.1
    box('Ventral hangar foundation',(x,y,z),(12,2,20),blue,.7)
    box('Deep hangar entrance',(x,y-1.05,z),(9.5,.15,16.8),dark,.1)
    for side in [-1,1]:
        box('Hangar perimeter rim',(x+side*5.2,y-1.4,z),(.7,.6,18.5),edge,.12)
        box('Hangar docking guide',(x+side*4.2,y-1.17,z),(.12,.04,13),ice,0)
    for j in range(7):
        box('Hangar door slats',(x,y-1.2,z-6+j*2),(7.1,.15,.12),hull,.02)
# Paired communications dishes with concave faces, radial ribs and receiver booms.
for side in [-1,1]:
    center=Vector((side*49,20,5))
    beam('Dish support',(side*49,11,5),center,1.2,1.2,blue)
    vertices=[center+Vector((0,-1,0))]
    for ring in range(1,5):
        r=ring*1.2
        for k in range(32):
            a=k*math.tau/32; vertices.append(center+Vector((r*math.cos(a),-1+.12*r*r,r*math.sin(a))))
    faces=[(0,1+k,1+(k+1)%32) for k in range(32)]
    for ring in range(3):
        for k in range(32):
            a=1+ring*32+k; b=1+ring*32+(k+1)%32; faces.append((a,a+32,b+32,b))
    mesh('Concave communications dish',vertices,faces,edge,smooth=True)
    beam('Dish receiver',center-Vector((0,1,0)),center+Vector((0,5,0)),.25,.25,dark)
    for k in range(3):
        a=k*math.tau/3
        beam('Dish receiver strut',center+Vector((4*math.cos(a),1,4*math.sin(a))),center+Vector((0,4,0)),.1,.1,blue)
# The registry faces upward and sits above the bow armor.
registry=next(o for o in scene.objects if o.name.startswith('LUMEN registry'))
registry.rotation_euler.x=-math.pi/2; registry.location.y=12.9
scene['refinement']='ventral armor / occupied lower decks / six hangars / radar dishes'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/LumenCityShip.blend')
result={'scene':scene.name,'objects':len(scene.objects),'refinement':scene['refinement']}
