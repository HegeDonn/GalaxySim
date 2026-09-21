import bpy
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene=bpy.context.scene
# Close the pressure shell behind the independent instrument modules.
def box(name,center,size,material):
    h=[v/2 for v in size]
    corners=[(x*h[0],y*h[1],z*h[2]) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    m=bpy.data.meshes.new(name); m.from_pydata(corners,[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)]); m.update()
    o=bpy.data.objects.new(name,m); scene.collection.objects.link(o); o.location=center; m.materials.append(bpy.data.materials[material])
    b=o.modifiers.new('Soft edges','BEVEL'); b.width=.025; b.segments=3
    o.modifiers.new('Corner normals','WEIGHTED_NORMAL')
box('Forward pressure shell',(0,-1.19,-2.02),(4.96,1.01,.18),'Graphite ceramic')
for side in [-1,1]: box('Lower side pressure shell',(side*2.24,-1.15,-.22),(.18,1.10,4.4),'Graphite ceramic')
box('Canopy identity plate',(0,1.275,-2.75),(1.90,.24,.07),'Blue grey instrument enamel')
# Keep flat main panels but smooth the rounded bevels and tubular rails.
for obj in scene.objects:
    if obj.type=='MESH':
        for modifier in obj.modifiers:
            if modifier.type=='BEVEL': modifier.harden_normals=True
    if obj.type=='CURVE': obj.data.resolution_u=8
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/KeplerCabin.blend')
result={'objects':len(scene.objects),'saved':bpy.data.filepath}
