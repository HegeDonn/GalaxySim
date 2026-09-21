import bpy, math
from mathutils import Vector, Matrix, Euler
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene=bpy.context.scene
# Edit in ship coordinates, then orient the entire Blender model upright.
root=bpy.data.objects.get('Cabin orientation — Y-up to Z-up')
if root: root.rotation_euler=(0,0,0); bpy.context.view_layer.update()
remove_prefixes=('Roof cassette','Inset ceiling','Cooling rib','Deck','Floor tread','Canopy structural hoop','Canopy machined lip','Canopy polymer seal','Canopy identity plate','Legend KEPLER')
for obj in list(scene.objects):
    if obj.name.startswith(remove_prefixes): bpy.data.objects.remove(obj,do_unlink=True)

def mesh(name,vertices,faces,material):
    data=bpy.data.meshes.new(name); data.from_pydata(vertices,[],faces); data.update()
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); data.materials.append(material)
    if root: o.parent=root
    return o
shell=bpy.data.materials['Graphite ceramic']; trim=bpy.data.materials['Brushed titanium']; rubber=bpy.data.materials['Black gasket']
cyan=bpy.data.materials['Ice instrument lamps']
glass=bpy.data.materials.new('Laminated blue glass'); glass.diffuse_color=(.10,.26,.30,.3); glass.use_nodes=True
glass['cabin_kind']=4; glass['cabin_rgb']=(.10,.26,.30)
bs=glass.node_tree.nodes.get('Principled BSDF'); bs.inputs['Base Color'].default_value=(.10,.26,.30,1); bs.inputs['Roughness'].default_value=.16; bs.inputs['Transmission Weight'].default_value=.88; bs.inputs['IOR'].default_value=1.46

def box(name,c,size,m=shell,basis=None):
    h=Vector(size)*.5
    v=[(x*h.x,y*h.y,z*h.z) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    o=mesh(name,v,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)],m); o.location=c
    if basis: o.rotation_euler=Matrix(basis).transposed().to_euler()
    b=o.modifiers.new('Window frame radius','BEVEL'); b.width=min(.025,min(size)*.3); b.segments=3
    o.modifiers.new('Frame normals','WEIGHTED_NORMAL'); return o

def beam(name,a,b,width=.12,depth=.12,m=shell):
    a,b=Vector(a),Vector(b); y=(b-a).normalized(); helper=Vector((0,0,1)) if abs(y.z)<.95 else Vector((0,1,0))
    x=y.cross(helper).normalized(); z=x.cross(y).normalized()
    return box(name,(a+b)*.5,(width,(b-a).length,depth),m,(x,y,z))

def pane(name,points,variant):
    # A single optical interface; thickness is communicated by the double
    # structural lip rather than overlapping transparent faces.
    o=mesh(name,points,[tuple(range(len(points)))],glass); o['screen_variant']=variant
    uv=o.data.uv_layers.new(name='Glass UV')
    for i,p in enumerate(uv.data):
        p.uv=([(0,0),(1,0),(1,1),(0,1)][i] if len(points)==4 else (i/(len(points)-1),i%2))
    return o

# A swept, shallow V-shaped windshield with its ridge projecting forward.
left=[(-2.48,-.72,-2.48),(-2.78,.20,-2.62),(-2.34,1.40,-2.78),(-1.65,1.66,-2.86),(0,1.45,-3.5)]
right=[(-x,y,z) for x,y,z in reversed(left[:-1])]
ring=left+right
for a,b in zip(ring,ring[1:]):
    beam('Swept canopy frame',a,b,.16,.18)
    beam('Swept window gasket',Vector(a)+Vector((0,0,.105)),Vector(b)+Vector((0,0,.105)),.023,.025,rubber)
peak=(0,-.62,-2.90)
for side in [-1,1]:
    beam('Forward peaked sill',(side*2.48,-.72,-2.48),peak,.105,.14)
    points=[(side*x,y,z) for x,y,z in left]+[peak]
    pane('Swept windshield',points,0)
beam('Windshield centre seam',peak,(0,1.45,-3.50),.019,.025,trim)
# Roof perimeter and transverse ribs enclose two long skylights.
for x in [-1.44,0,1.44]:
    box('Skylight longitudinal frame',(x,1.49,-.25),(.16 if x==0 else .22,.12,3.90))
for z in [-2.2,-.90,.50,1.70]:
    box('Skylight cross rib',(0,1.49,z),(3.05,.12,.13))
for side in [-1,1]:
    pane('Roof skylight',[(side*.09,1.50,-2.18),(side*1.32,1.50,-2.18),(side*1.32,1.50,1.64),(side*.09,1.50,1.64)],1)
    # Forward triangular roof facet joins the new windshield peak.
    pane('Forward roof facet',[(0,1.45,-3.5),(side*1.65,1.66,-2.86),(side*1.32,1.50,-2.18),(side*.09,1.50,-2.18)],1)
    beam('Roof forward rake',(0,1.45,-3.5),(side*1.32,1.50,-2.18),.045,.05,trim)
# Floor skin surrounds real apertures, so the stars remain visible below.
for x,width in [(-2.10,.32),(-.82,.18),(.45,.36),(.98,.18),(2.10,.32)]:
    box('Floor longitudinal spar',(x,-1.67,0),(width,.16,5.0))
for z in [-2.42,-1.65,.18,1.12,2.45]: box('Floor transverse spar',(0,-1.67,z),(4.48,.16,.18))
# Opaque aft floor under the seats; forward glazing has thick inset lips.
box('Aft solid deck',(0,-1.67,1.32),(4.5,.14,2.26))
for lo,hi in [(-1.91,-.94),(-.70,.24),(1.10,1.91)]:
    pane('Floor observation glass',[(lo,-1.62,-1.53),(hi,-1.62,-1.53),(hi,-1.62,.06),(lo,-1.62,.06)],2)
    for x in [lo,hi]:
        box('Floor glass seal',(x,-1.601,-.735),(.025,.018,1.65),rubber)
        box('Floor glass edge light',(x,-1.59,-.735),(.007,.006,1.56),cyan)
    for z in [-1.53,.06]: box('Floor glass seal',((lo+hi)*.5,-1.601,z),(hi-lo,.018,.025),rubber)
# Rotate the scene 90 degrees: Blender is now Z-up while the exporter
# explicitly removes this transform for the Y-up simulator.
if root is None:
    root=bpy.data.objects.new('Cabin orientation — Y-up to Z-up',None); scene.collection.objects.link(root)
    for o in list(scene.objects):
        if o!=root and o.parent is None: o.parent=root
root.rotation_euler=(math.pi/2,0,0)
bpy.context.view_layer.update()
for window in bpy.context.window_manager.windows:
    for area in window.screen.areas:
        if area.type=='VIEW_3D':
            space=area.spaces.active
            space.shading.type='MATERIAL'
            space.region_3d.view_perspective='CAMERA'
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/KeplerCabin.blend')
result={'objects':len(scene.objects),'orientation_degrees':90,'roof_windows':True,'floor_windows':3,'front':'swept V canopy'}
