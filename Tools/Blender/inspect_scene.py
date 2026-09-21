import bpy
result = {"version": bpy.app.version_string, "filepath": bpy.data.filepath,
          "scene": bpy.context.scene.name,
          "objects": [{"name": o.name, "type": o.type} for o in bpy.context.scene.objects],
          "scenes": [s.name for s in bpy.data.scenes]}
