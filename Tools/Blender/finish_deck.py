import bpy
from mathutils import Vector
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene=bpy.context.scene; root=bpy.data.objects['Cabin orientation — Y-up to Z-up']
def block(name,c,size):
    h=Vector(size)*.5
    m=bpy.data.meshes.new(name); m.from_pydata([(x*h.x,y*h.y,z*h.z) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]],[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)]); m.update()
    o=bpy.data.objects.new(name,m); scene.collection.objects.link(o); o.parent=root; o.location=c; m.materials.append(bpy.data.materials['Graphite ceramic'])
block('Forward solid deck',(0,-1.67,-2.055),(4.50,.15,.80))
# Narrow solid webs make each observation pane an aperture in a complete deck.
for x,w in [(-1.985,.15),(-.82,.24),(.44,.40),(1.03,.14),(1.985,.15)]: block('Floor aperture web',(x,-1.64,-.735),(w,.12,1.80))
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/KeplerCabin.blend')
result={'saved':bpy.data.filepath,'objects':len(scene.objects)}
