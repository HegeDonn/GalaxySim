import bpy, math, os, struct, json, time
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
started=time.monotonic()
scene=bpy.context.scene; graph=bpy.context.evaluated_depsgraph_get()
assert scene.get('ship_export'), 'Select the LUMEN city ship scene before export'
orientation=next((o for o in scene.objects if o.name.startswith('Ship orientation — Y-up to Z-up')),None)
assert orientation is not None, 'Missing ship orientation root'
ship_inverse=orientation.matrix_world.inverted() if orientation else __import__('mathutils').Matrix.Identity(4)
chunks=[]; bvh_vertices=[]; bvh_faces=[]
for obj in scene.objects:
    if obj.type not in {'MESH','CURVE','FONT'} or obj.get('ship_skip_export',False): continue
    evaluated=obj.evaluated_get(graph); mesh=evaluated.to_mesh()
    if not mesh: continue
    mesh.calc_loop_triangles(); matrix=ship_inverse @ obj.matrix_world; normal_matrix=matrix.to_3x3().inverted().transposed()
    positions=[matrix @ v.co for v in mesh.vertices]
    if not (mesh.materials and mesh.materials[0].get('ship_kind',0)==4):
        base=len(bvh_vertices); bvh_vertices.extend(positions)
        bvh_faces.extend([tuple(base+i for i in tri.vertices) for tri in mesh.loop_triangles])
    normals=[(normal_matrix @ n.vector).normalized() for n in mesh.corner_normals]
    materials=list(mesh.materials); uv=mesh.uv_layers.active
    for tri in mesh.loop_triangles:
        material=materials[tri.material_index] if materials else None
        color=tuple(material.get('ship_rgb',(.1,.13,.15))) if material else (.1,.13,.15)
        kind=float(material.get('ship_kind',0)) if material else 0
        variant=float(material.get('ship_roughness',.5)) if material else .5
        for vi,li in zip(tri.vertices,tri.loops):
            tex=tuple(uv.data[li].uv) if kind in (2,4) and uv else (0,0)
            chunks.append((positions[vi],normals[li],color,kind,variant,tex))
    evaluated.to_mesh_clear()
bounds=[[min(p[k] for p,*_ in chunks) for k in range(3)],[max(p[k] for p,*_ in chunks) for k in range(3)]]
assert all(abs(v)<250 for row in bounds for v in row), str(bounds)
bvh=BVHTree.FromPolygons(bvh_vertices,bvh_faces,all_triangles=True,epsilon=0)
cache={}; ao_min=1; ao_max=0
samples=[Vector((0,0,1)),Vector((.65,0,.76)),Vector((-.65,0,.76)),Vector((0,.65,.76)),Vector((0,-.65,.76))]
output=bytearray(b'GSCABIN1'+struct.pack('<I',len(chunks)))
for p,n,color,kind,variant,uv in chunks:
    ao=1.0
    if kind in (0,3):
        key=tuple(round(v,3) for v in (*p,*n))
        if key in cache: ao=cache[key]
        else:
            helper=Vector((0,1,0)) if abs(n.y)<.95 else Vector((1,0,0))
            tangent=n.cross(helper).normalized(); bitangent=n.cross(tangent)
            occlusion=0
            for s in samples:
                direction=tangent*s.x+bitangent*s.y+n*s.z
                hit,normal,index,distance=bvh.ray_cast(p+n*.025,direction,5.0)
                if hit is not None: occlusion+=(1-distance/5.0)
            ao=1-.70*occlusion/len(samples); cache[key]=ao
        ao_min=min(ao_min,ao); ao_max=max(ao_max,ao)
    output.extend(struct.pack('<16f',*p,1,*n,0,*color,ao,kind,variant,*uv))
path=ROOT+'/Sources/GalaxySim/Resources/Ship'; os.makedirs(path,exist_ok=True)
with open(path+'/ship.mesh','wb') as f: f.write(output)
meta={'bounds':bounds,'format':'GSCABIN1','triangles':len(chunks)//3,'bytes':len(output),'objects':len(scene.objects),'ao_range':[ao_min,ao_max],'bake_seconds':time.monotonic()-started,'source':'Assets/Blender/LumenCityShip.blend','shader':'color.w contains baked local ambient visibility'}
with open(path+'/manifest.json','w') as f: json.dump(meta,f,indent=2)
result=meta
