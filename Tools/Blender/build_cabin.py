import bpy, math, os
from mathutils import Vector, Matrix
from pathlib import Path
ROOT = str(Path(__file__).resolve().parents[2])
scene = bpy.data.scenes.new('GalaxySim Cabin — Kepler')
bpy.context.window.scene = scene
materials = {}
def mat(name, color, kind=0, rough=.5, metal=.5):
    m=bpy.data.materials.new(name); m.diffuse_color=(*color,1); m.use_nodes=True
    m['cabin_kind']=kind; m['cabin_rgb']=color
    bs=m.node_tree.nodes.get('Principled BSDF'); bs.inputs['Base Color'].default_value=(*color,1)
    bs.inputs['Roughness'].default_value=rough; bs.inputs['Metallic'].default_value=metal
    if kind==1:
        bs.inputs['Emission Color'].default_value=(*color,1); bs.inputs['Emission Strength'].default_value=2
    materials[name]=m; return m
shell=mat('Graphite ceramic',(.075,.10,.12),rough=.52,metal=.4)
trim=mat('Brushed titanium',(.22,.26,.28),rough=.32,metal=.8)
rubber=mat('Black gasket',(.018,.024,.027),rough=.95,metal=0)
panel=mat('Blue grey instrument enamel',(.10,.17,.19),rough=.38,metal=.5)
cloth=mat('Charcoal upholstery',(.08,.10,.105),kind=3,rough=.95,metal=0)
stitch=mat('Woven piping',(.25,.29,.27),rough=.9,metal=0)
amber=mat('Warm instrument lamps',(.95,.52,.20),kind=1)
cyan=mat('Ice instrument lamps',(.27,.78,.86),kind=1)
white=mat('Warm ceramic lettering',(.63,.65,.57),rough=.6,metal=0)
windowScreen=mat('Dynamic display',(.06,.2,.22),kind=2)

def mesh(name,vertices,faces,material):
    data=bpy.data.meshes.new(name); data.from_pydata(vertices,[],faces); data.update()
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); data.materials.append(material)
    return o

def box(name,c,size,m=shell,bevel=.025,basis=None):
    sx,sy,sz=[x/2 for x in size]
    vertices=[(x*sx,y*sy,z*sz) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    o=mesh(name,vertices,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)],m)
    o.location=c
    if basis: o.rotation_euler=Matrix(basis).transposed().to_euler()
    if bevel:
        mod=o.modifiers.new('Machined edge radius','BEVEL'); mod.width=min(bevel,min(size)*.42); mod.segments=3
        mod=o.modifiers.new('Weighted corner normals','WEIGHTED_NORMAL'); mod.keep_sharp=True
    return o

def beam(name,a,b,width=.12,depth=.12,m=shell):
    a,b=Vector(a),Vector(b); y=(b-a).normalized(); helper=Vector((0,0,1)) if abs(y.z)<.95 else Vector((0,1,0))
    x=y.cross(helper).normalized(); z=x.cross(y).normalized()
    return box(name,(a+b)/2,(width,(b-a).length,depth),m,min(width,depth)*.25,(x,y,z))

def tube(name,points,radius=.025,m=trim):
    data=bpy.data.curves.new(name,'CURVE'); data.dimensions='3D'; data.resolution_u=10
    spl=data.splines.new('BEZIER'); spl.bezier_points.add(len(points)-1)
    for p,co in zip(spl.bezier_points,points): p.co=co; p.handle_left_type='AUTO'; p.handle_right_type='AUTO'
    data.bevel_depth=radius; data.bevel_resolution=3
    o=bpy.data.objects.new(name,data); scene.collection.objects.link(o); data.materials.append(m); return o

def label(text,c,size=.04,m=white,basis=None):
    data=bpy.data.curves.new('Legend '+text,'FONT'); data.body=text; data.size=size; data.extrude=.0004; data.align_x='CENTER'
    o=bpy.data.objects.new('Legend '+text,data); scene.collection.objects.link(o); o.location=c; data.materials.append(m)
    if basis: o.rotation_euler=Matrix(basis).transposed().to_euler()
    return o

def display(name,c,width,height,variant,basis):
    x,y,n=map(Vector,basis); c=Vector(c)
    box(name+' module',c-n*.05,(width+.14,height+.17,.12),panel,.035,basis)
    box(name+' gasket',c+n*.014,(width+.055,height+.055,.018),rubber,.009,basis)
    # Genuine aperture: four separate metal lips around the screen.
    for side in [-1,1]:
        box(name+' lip',c+x*side*(width/2+.021)+n*.03,(.031,height+.065,.035),trim,.008,basis)
        box(name+' lip',c+y*side*(height/2+.02)+n*.03,(width+.045,.03,.035),trim,.007,basis)
    vertices=[c+n*.028-x*width/2-y*height/2,c+n*.028+x*width/2-y*height/2,c+n*.028+x*width/2+y*height/2,c+n*.028-x*width/2+y*height/2]
    o=mesh(name+' LCD',vertices,[(0,1,2,3)],windowScreen); o['screen_variant']=variant
    uv=o.data.uv_layers.new(name='Instrument UV')
    for i,co in enumerate([(0,0),(1,0),(1,1),(0,1)]): uv.data[i].uv=co
    label(name,c+y*(height/2+.049)+n*.055,.026,white,basis)
    for k in range(6):
        p=c+x*((k-2.5)*width/6)-y*(height/2+.043)+n*.052
        box(name+' key',p,(width/9,.02,.022),amber if k==0 else rubber,.005,basis)
    for a in [-1,1]:
        for b in [-1,1]:
            p=c+x*a*(width/2+.055)+y*b*(height/2+.059)+n*.02
            box('Recessed fastener',p,(.017,.017,.012),trim,.007,basis)
            box('Fastener slot',p+n*.007,(.012,.003,.002),rubber,.0004,basis)

# Continuous sill and segmented wraparound instrument bank.
box('Front sill',(0,-.80,-2.12),(4.95,.28,.40),shell,.10)
tube('Window seal',[(-2.4,-.60,-2.08),(0,-.61,-2.22),(2.4,-.60,-2.08)],.027,rubber)
for i,xpos in enumerate([-1.72,-.86,0,.86,1.72]):
    angle=-xpos*.16
    n=Vector((math.sin(angle)*.9,.43,math.cos(angle)*.9)).normalized()
    x=Vector((math.cos(angle),0,-math.sin(angle))); y=n.cross(x).normalized()
    c=(xpos,-.68+(0.075 if i==2 else 0),-1.91+abs(xpos)*.10)
    display(['PORT OPTICS','VELOCITY / c','FLIGHT DIRECTOR','CLOCK / GAMMA','STARBOARD OPTICS'][i],c,.67,.43 if i==2 else .34,[0,1,2,1,0][i],(x,y,n))
    box('Lower control shelf',(xpos,-1.0,-1.57+abs(xpos)*.1),(.80,.12,.37),panel,.035)
    for row in range(2):
        for col in range(5):
            p=(xpos+(col-2)*.125,-.923,-1.66+row*.12+abs(xpos)*.1)
            box('Tactile switch',p,(.07,.035,.06),rubber,.012)
            box('Switch indicator',(p[0],p[1]+.019,p[2]),(.025,.004,.012),cyan if (row+col)%3 else amber,.001)

# Canopy rim, double seals, aft roof and side pillars.
front=[(-2.48,-.72,-2.48),(-2.78,.20,-2.62),(-2.34,1.40,-2.78),(-1.65,1.66,-2.86),(1.65,1.66,-2.86),(2.34,1.40,-2.78),(2.78,.20,-2.62),(2.48,-.72,-2.48)]
for a,b in zip(front,front[1:]):
    beam('Canopy structural hoop',a,b,.20,.23)
    aa=Vector(a)+Vector((0,0,.135)); bb=Vector(b)+Vector((0,0,.135))
    beam('Canopy machined lip',aa,bb,.028,.037,trim)
    beam('Canopy polymer seal',aa+Vector((0,0,.025)),bb+Vector((0,0,.025)),.013,.018,rubber)
for side in [-1,1]:
    tube('Swept roof girder',[(side*1.70,1.60,-2.9),(side*1.55,1.40,-.5),(side*1.72,1.35,1.8)],.105,shell)
    tube('Roof cable duct',[(side*1.82,1.54,-2.75),(side*1.69,1.28,-.5),(side*1.83,1.20,1.9)],.027,rubber)
    beam('Side sill',(side*2.5,-.66,-2.5),(side*2.17,-.66,2.1),.19,.25,panel)
    beam('Side arch',(side*2.18,-.67,.7),(side*1.58,1.4,.6),.15,.18)
    box('Rear side wall',(side*2.20,.06,1.82),(.18,2.7,1.25),shell,.055)
    for z in [-2.2,-1.15,.05]:
        box('Lamp housing',(side*1.52,1.22,z),(.22,.10,.35),trim,.03)
        box('Lamp diffuser',(side*1.52,1.164,z),(.16,.015,.27),amber,.007)
        for dz in [-.10,-.05,0,.05,.10]: box('Lamp grille',(side*1.52,1.15,z+dz),(.19,.018,.012),rubber,.002)
    # Ribbed landing pads and side consoles.
    box('Side equipment console',(side*1.89,-1.0,-.15),(.67,.45,1.86),shell,.09)
    top=(Vector((1,0,0)),Vector((0,0,-1)),Vector((0,1,0)))
    display('AUXILIARY', (side*1.89,-.765,-.65),.42,.43,2,top)
    tube('Console grab handle',[(side*1.49,-.73,.0),(side*1.43,-.56,.12),(side*1.43,-.56,.48),(side*1.49,-.73,.6)],.024,trim)
    for z in [.05,.16,.27,.38,.49]: box('Vent slat',(side*1.94,-.756,z),(.32,.022,.038),rubber,.009)
# Roof tiles with inset seams, machinery and luminous center fixture.
for z in [-1.8,-.8,.2,1.2]:
    box('Roof cassette',(0,1.52,z),(3.05,.15,.94),shell,.06)
    box('Inset ceiling',(0,1.432,z),(1.12,.032,.67),panel,.02)
    for x in [-.42,-.28,-.14,0,.14,.28,.42]: box('Cooling rib',(x,1.404,z),(.035,.023,.53),rubber,.005)
label('KEPLER  /  DEEP FIELD',(0,1.24,-2.70),.105,white)
# Floor, center tunnel, and rear exit.
box('Deck',(0,-1.68,0),(4.5,.16,5.4),shell,.03)
for x in [-1.5,-.75,0,.75,1.5]:
    box('Deck panel',(x,-1.588,.1),(.70,.018,4.7),rubber,.006)
    for z in [-1.5,-.8,-.1,.6,1.3,2.0]: box('Floor tread',(x,-1.571,z),(.53,.008,.017),trim,.002)
box('Aft bulkhead',(0,0,2.35),(4.5,3.1,.18),shell,.05)
box('Pressure door',(0,-.20,2.21),(1.10,2.6,.13),panel,.09)
for x in [-.59,.59]: box('Door locator',(x,-.20,2.12),(.025,2.25,.026),amber,.01)
label('AIRLOCK',(0,.65,2.105),.12,white,(Vector((-1,0,0)),Vector((0,1,0)),Vector((0,0,-1))))
box('Center equipment tunnel',(.67,-1.12,-.2),(.52,.68,1.7),shell,.085)
display('THRUST',(.67,-.77,-.73),.34,.37,1,(Vector((1,0,0)),Vector((0,0,-1)),Vector((0,1,0))))
for x in [.55,.79]:
    box('Lever boot',(x,-.745,-.03),(.14,.055,.42),rubber,.027)
    tube('Throttle lever',[(x,-.70,-.03),(x,-.54,-.06),(x,-.47,-.17)],.025,trim)
    box('Throttle grip',(x,-.455,-.17),(.16,.075,.12),rubber,.032)
    box('Grip marking',(x,-.414,-.17),(.08,.006,.018),amber,.002)
# Rounded upholstered seats, bolsters, harnesses, stitching.
for seatX in [-.22,1.29]:
    box('Seat pedestal',(seatX,-1.37,.64),(.24,.48,.3),trim,.05)
    box('Seat shell',(seatX,-.61,.92),(.74,1.05,.23),shell,.105)
    box('Seat cushion',(seatX,-.99,.43),(.61,.20,.70),cloth,.083)
    box('Lumbar cushion',(seatX,-.61,.745),(.53,.86,.18),cloth,.077)
    box('Head cushion',(seatX,.04,.84),(.47,.28,.25),cloth,.093)
    for dx in [-.275,.275]:
        box('Side bolster',(seatX+dx,-.60,.74),(.12,.89,.24),cloth,.05)
        tube('Seat piping',[(seatX+dx,-.97,.6),(seatX+dx,-.6,.606),(seatX+dx,-.2,.67)],.008,stitch)
    for dx in [-.18,.18]:
        tube('Harness webbing',[(seatX+dx,-.15,.63),(seatX+dx*.55,-.51,.60),(seatX+dx*.2,-.93,.41)],.022,rubber)
    for dx in [-.39,.39]:
        beam('Arm support',(seatX+dx,-1.0,.63),(seatX+dx,-.64,.50),.047,.045,trim)
        box('Armrest',(seatX+dx,-.62,.34),(.13,.09,.49),cloth,.039)
# Blender-only camera and area lights for the editable scene.
camData=bpy.data.cameras.new('Pilot camera'); cam=bpy.data.objects.new('Pilot camera',camData); scene.collection.objects.link(cam)
cam.location=(0,0,0); cam.rotation_euler=(0,0,0); camData.lens=23.5; scene.camera=cam
for name,power,color,loc,size in [('Ceiling softbox',220,(.7,.85,1),(0,1.2,-.4),2.0),('Port amber',130,(1,.45,.16),(-1.4,.3,-1.8),1),('Screen fill',90,(.15,.65,1),(0,-.5,-1.5),1)]:
    d=bpy.data.lights.new(name,'AREA'); d.energy=power; d.color=color; d.shape='DISK'; d.size=size
    o=bpy.data.objects.new(name,d); scene.collection.objects.link(o); o.location=loc
    o.rotation_euler=(Vector((0,-.7,-.2))-o.location).to_track_quat('-Z','Y').to_euler()
scene.world=bpy.data.worlds.new('Cabin studio'); scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.035,.045,.06,1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value=.3
scene.render.engine='CYCLES'; scene.cycles.samples=32
scene.render.resolution_x=1440; scene.render.resolution_y=900; scene.render.resolution_percentage=100
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/Assets/Blender/KeplerCabin.blend')
result={'scene':scene.name,'objects':len(scene.objects),'blend':bpy.data.filepath}
