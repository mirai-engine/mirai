package usd

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import mm "mirai:std/math"
import importer "mirai:cook/import"

// USDA is read by the parser of the importer; what needs composition or the
// binary crate needs usdcat, and those tests are skipped without it.
TEXT_ONLY :: Options{no_usdcat=true}

color_of :: proc(color:u32) -> [3]f32 {
    return {f32(color&0xff)/255,f32(color>>8&0xff)/255,f32(color>>16&0xff)/255}
}

@(private="file")
requires_usdcat :: proc(t:^testing.T) -> bool {
    if _,found:=usdcat_path({});!found {
        log.warn("usdcat is not installed: the tests that compose or decode USD were not run")
        return false
    }
    return true
}

@(private="file")
mesh_named :: proc(model:^importer.Imported_Model,name:string) -> ^importer.Imported_Mesh {
    for &mesh in model.meshes {
        if mesh.name==name {return &mesh}
    }
    return nil
}

@(private="file")
corner_normal :: proc(vertex:u32) -> [3]f32 {return mm.normal_unpack(vertex)}

@(test)
a_usda_hierarchy_keeps_its_transforms_and_display_color :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"hierarchy.usda",TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    child:=find_node(&model,"Child")
    testing.expect(t,child>=0 && model.nodes[child].mesh==0)
    if child<0 {return}
    testing.expect(t,close_to(world_transform(&model,child).position,{-2,3,0}),"the hierarchy and its transforms survive")
    testing.expect_value(t,triangle_count(&model.meshes[0]),1)
    for vertex in model.meshes[0].vertices {testing.expect(t,close_to(color_of(vertex.color),{0.2,0.8,0.4},1.0/255),"a uniform displayColor survives")}
    testing.expect(t,.Has_Colors in model.meshes[0].flags)
    testing.expect_value(t,len(model.warnings),0)
}

@(test)
composed_and_binary_usd_need_usdcat :: proc(t:^testing.T) {
    _,error:=usd_read(FIXTURES+"referenced.usda",TEXT_ONLY)
    testing.expect_value(t,error.code,importer.Error_Code.Tool)
    testing.expect(t,contains(error.message,"usdcat"),error.message)
    _,error=usd_read(FIXTURES+"hierarchy.usdc",TEXT_ONLY)
    testing.expect_value(t,error.code,importer.Error_Code.Tool)
    testing.expect(t,contains(error.message,"binary") && contains(error.message,"usdcat"),error.message)
    _,error=usd_read(FIXTURES+"hierarchy.usdc",{usdcat="usdcat-that-does-not-exist"})
    testing.expect_value(t,error.code,importer.Error_Code.Tool)

    if !requires_usdcat(t) {return}
    for filename in ([]string{"hierarchy.usda","hierarchy.usdc","referenced.usda"}) {
        model,ok:=import_ok(t,fmt.tprintf("%s%s",FIXTURES,filename))
        if !ok {continue}
        defer importer.model_destroy(&model)
        child:=find_node(&model,"Child")
        expected:=[3]f32{-2,3,0}
        if filename=="referenced.usda" {expected={-8,3,0}}
        testing.expect(t,child>=0 && close_to(world_transform(&model,child).position,expected),"the reference and its override survive flattening")
    }
}

@(test)
units_and_up_axis_are_baked_into_meters_and_y_up :: proc(t:^testing.T) {
    folder:=temp_folder("usd-units")
    defer os.remove_all(folder)
    path:=write_text(folder,"units.usda",`#usda 1.0
(
 metersPerUnit = 0.01
 upAxis = "Z"
)
def Xform "Root"
{
 matrix4d xformOp:transform = ((1,0,0,0),(0,1,0,0),(0,0,1,0),(0,0,100,1))
 uniform token[] xformOpOrder = ["xformOp:transform"]
 def Mesh "Polygon"
 {
  point3f[] points = [(0,0,0),(100,0,0),(0,100,0)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
 }
}`)
    model,ok:=import_ok(t,path,TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),2)
    testing.expect_value(t,len(model.meshes),1)
    polygon:=find_node(&model,"Polygon")
    world:=world_transform(&model,polygon)
    corners:=triangle_positions(&model.meshes[0],0)
    a,b:=mm.transform_point(world,corners[0]),mm.transform_point(world,corners[1])
    testing.expect(t,close_to(a,{0,1,0}),"centimeters and Z-up become meters and Y-up")
    testing.expect(t,abs(linalg.length(b-a)-1)<1e-5,"the geometry is in meters")
    testing.expect(t,close_to(model.nodes[find_node(&model,"Root")].transform.position,{0,1,0}) && close_to(corners[1],{-1,0,0}) && close_to(corners[2],{0,0,1}),"no node holds the units: nodes and points are in meters, +Y up")
}

@(test)
transform_ops_compose_in_the_order_usd_states :: proc(t:^testing.T) {
    folder:=temp_folder("usd-ops")
    defer os.remove_all(folder)
    path:=write_text(folder,"ops.usda",`#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Xform "Moved"
{
 double3 xformOp:translate = (1, 2, 3)
 float3 xformOp:rotateXYZ = (0, 90, 0)
 float3 xformOp:scale = (2, 2, 2)
 uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"]
 def Mesh "Tri"
 {
  point3f[] points = [(1,0,0),(0,1,0),(0,0,1)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
 }
}
def Xform "Quaternion"
{
 quatf xformOp:orient = (0.70710678, 0, 0.70710678, 0)
 uniform token[] xformOpOrder = ["xformOp:orient"]
}
def Xform "Sheared"
{
 matrix4d xformOp:transform = ((1,0,0,0),(0.5,1,0,0),(0,0,1,0),(0,0,0,1))
 uniform token[] xformOpOrder = ["xformOp:transform"]
}
`)
    _,error:=usd_read(path,TEXT_ONLY)
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)
    testing.expect(t,contains(error.message,"shear") && contains(error.message,"/Sheared"),error.message)
    text:=strings.concatenate({`#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Xform "Moved"
{
 double3 xformOp:translate = (1, 2, 3)
 float3 xformOp:rotateXYZ = (0, 90, 0)
 float3 xformOp:scale = (2, 2, 2)
 uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"]
 def Mesh "Tri"
 {
  point3f[] points = [(1,0,0),(0,1,0),(0,0,1)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
 }
}
def Xform "Quaternion"
{
 quatf xformOp:orient = (0.70710678, 0, 0.70710678, 0)
 uniform token[] xformOpOrder = ["xformOp:orient"]
}
`},context.temp_allocator)
    path=write_text(folder,"ok.usda",text)
    model,ok:=import_ok(t,path,TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    tri:=find_node(&model,"Tri")
    world:=world_transform(&model,tri)
    // Scale, then rotate 90 degrees about Y, then translate: (1,0,0) goes to (2,0,0), (0,0,-2), (1,2,3)+(0,0,-2).
    corners:=triangle_positions(&model.meshes[0],0)
    testing.expect(t,close_to(mm.transform_point(world,corners[0]),{-1,2,-1}) && close_to(mm.transform_point(world,corners[2]),{-3,2,-3}),"ops act in the order of xformOpOrder")
    quaternion_node:=find_node(&model,"Quaternion")
    rotated:=mm.transform_direction(model.nodes[quaternion_node].transform,{1,0,0})
    testing.expect(t,close_to(rotated,{0,0,-1},1e-4),"an orient op is a rotation")
}

@(test)
normals_texture_coordinates_and_materials_of_usd_meshes :: proc(t:^testing.T) {
    model,ok:=import_ok(t,FIXTURES+"material.usda",TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    wall,leaf,pane,plain:=mesh_named(&model,"Wall"),mesh_named(&model,"Leaf"),mesh_named(&model,"Pane"),mesh_named(&model,"Plain")
    testing.expect(t,len(model.meshes)==4 && wall!=nil && leaf!=nil && pane!=nil && plain!=nil)
    if wall==nil || leaf==nil || pane==nil || plain==nil {return}
    for node in model.nodes {testing.expect(t,node.name!="Paint" && node.name!="Surface" && node.name!="Color","materials and their shaders are not nodes")}
    testing.expect_value(t,len(model.materials),3)
    testing.expect_value(t,len(model.warnings),0)
    directory:=model.source[:strings.last_index_byte(model.source,'/')]

    testing.expect_value(t,triangle_count(wall),2)
    for i in 0..<2 {
        corners:=importer.mesh_triangle(wall,i)
        for vertex in corners {
            p:=vertex.position
            expected:=[3]f32{-0.70710678,0,-0.70710678} if p=={-1,0,0} else {0,0,-1}
            testing.expect(t,close_to(corner_normal(vertex.normal),expected,1e-3),"primvars:normals wins over normals and is read per corner, through its indices")
            testing.expect(t,vertex.uv=={-p.x,1-p.y},"USD counts v from the bottom of the image")
            testing.expect(t,vertex.color==importer.WHITE,"displayColor is left out of a mesh with a material")
        }
    }
    paint_row:=wall.slots[0].material
    testing.expect(t,paint_row>=0 && model.materials[paint_row].name=="Paint","the binding of a parent prim reaches the mesh")
    paint:=&model.materials[paint_row]
    testing.expect(t,paint.info.base_color=={1,1,1} && close_to(paint.info.emission,{0.1,0.2,0}),"a textured color leaves its factor at 1; a constant one is kept")
    testing.expect(t,abs(paint.info.metallic-0.25)<1e-5 && abs(paint.info.roughness-0.4)<1e-5 && paint.images[.Metallic_Roughness]<0)
    testing.expect(t,paint.info.alpha_mode==.Opaque && paint.info.opacity==1 && paint.images[.Emission]<0 && paint.images[.Occlusion]<0)
    color,normal:=paint.images[.Base_Color],paint.images[.Normal]
    testing.expect(t,color>=0 && normal>=0)
    if color>=0 && normal>=0 {
        testing.expect(t,model.images[color].path==fmt.tprintf("%s/textures/paint color.png",directory) && model.images[color].srgb && !model.images[color].normal_map,"an image usdcat did not find is a file next to the USD file, with the spaces of its name")
        testing.expect(t,model.images[normal].path==fmt.tprintf("%s/textures/paint_normal.png",directory) && model.images[normal].normal_map && !model.images[normal].srgb,"the image of the normal input is read as a normal map")
    }

    testing.expect_value(t,triangle_count(leaf),1)
    corners:=importer.mesh_triangle(leaf,0)
    testing.expect(t,close_to(corner_normal(corners[0].normal),{0,1,0},1e-3) && close_to(corner_normal(corners[2].normal),{0,0.6,-0.8},1e-3),"normals per point are normalized")
    testing.expect(t,close_to(corner_normal(corners[1].normal),{0,1,0},1e-3),"a normal without length becomes the flat one")
    testing.expect(t,corners[0].uv=={0,1} && corners[1].uv=={1,1} && corners[2].uv=={0.25,0.25},"texture coordinates per point")
    cutout:=&model.materials[leaf.slots[0].material]
    testing.expect_value(t,cutout.name,"Leaf")
    testing.expect(t,cutout.info.alpha_mode==.Mask && abs(cutout.info.alpha_cutoff-0.3)<1e-5 && cutout.info.opacity==1,"opacityThreshold cuts by the alpha of the diffuse image")
    leaf_color,packed:=cutout.images[.Base_Color],cutout.images[.Metallic_Roughness]
    testing.expect(t,leaf_color>=0 && packed>=0 && cutout.images[.Occlusion]==packed && cutout.info.roughness==1 && cutout.info.metallic==1,"roughness in green and metallic in blue of one image are the packed map; occlusion in its red shares it")
    if leaf_color>=0 && packed>=0 {
        testing.expect(t,model.images[leaf_color].path==fmt.tprintf("%s/textures/leaf.png",directory) && abs(model.images[leaf_color].alpha_cutoff-0.3)<1e-5,"a masked material asks its image to keep the coverage of its cutoff")
        testing.expect(t,model.images[packed].path==fmt.tprintf("%s/textures/leaf_orm.png",directory) && !model.images[packed].srgb && !model.images[packed].normal_map)
    }

    testing.expect_value(t,triangle_count(pane),2)
    for i in 0..<2 {
        for vertex in importer.mesh_triangle(pane,i) {
            testing.expect(t,close_to(corner_normal(vertex.normal),{0,0,-1} if i==0 else {0,1,0},1e-3),"normals per face")
            testing.expect(t,vertex.uv=={0,0},"a mesh without st has no texture coordinates")
        }
    }
    glass:=&model.materials[pane.slots[0].material]
    testing.expect_value(t,glass.name,"Glass")
    testing.expect(t,close_to(glass.info.base_color,{0.2,0.4,0.6}),"an input connected to an input of its material takes that value")
    testing.expect(t,glass.info.alpha_mode==.Blend && abs(glass.info.opacity-0.5)<1e-5,"an opacity below 1 blends")
    testing.expect(t,abs(glass.info.roughness-0.5)<1e-5 && glass.info.metallic==0,"a separate roughness map is left out and the input keeps the default of UsdPreviewSurface")
    for image in glass.images {testing.expect(t,image<0)}
    for image in model.images {testing.expect(t,!contains(image.path,"glass_roughness"),"a map that is left out has no image")}

    testing.expect_value(t,triangle_count(plain),1)
    testing.expect(t,plain.slots[0].material==-1 && plain.slots[0].label=="Slot 1","a mesh without a material has a slot without material")
    for vertex in plain.vertices {
        testing.expect(t,close_to(color_of(vertex.color),{0.2,0.8,0.4},1.0/255) && close_to(corner_normal(vertex.normal),{0,0,-1},1e-3),"a mesh without a material keeps its displayColor; without normals it is flat")
    }
}

NETWORKS :: `#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Xform "A"
{
 rel material:binding = </A/Mat>
 def Material "Mat"
 {
  token outputs:surface.connect = </A/Mat/Graph.outputs:surface>
  def NodeGraph "Graph"
  {
   token outputs:surface.connect = </A/Mat/Graph/Surface.outputs:surface>
   def Shader "Surface"
   {
    uniform token info:id = "UsdPreviewSurface"
    color3f inputs:emissiveColor.connect = </A/Mat/Graph/Glow.outputs:rgb>
    float inputs:metallic = 0.5 (
     displayName = "Metallic"
    )
    float inputs:opacity = 0.25
    float inputs:opacityThreshold = 0
    float inputs:roughness = 0.7
    float inputs:roughness.connect = </A/Mat/Graph/Rough.outputs:g>
    token outputs:surface
   }
   def Shader "Glow"
   {
    uniform token info:id = "UsdUVTexture"
    asset inputs:file = @maps/glow.png@
    float3 outputs:rgb
   }
   def Shader "Rough"
   {
    uniform token info:id = "UsdUVTexture"
    asset inputs:file = @maps/rough.png@
    float outputs:g
   }
  }
 }
 def Mesh "Inherits"
 {
  point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
  color3f[] primvars:displayColor = [(0.2,0.8,0.4)]
  texCoord2f[] primvars:st = [(0,0),(1,0),(0,1)] (
   elementSize = 1
   interpolation = "vertex"
  )
 }
 def Mesh "Own"
 {
  rel material:binding = </B/Mat>
  point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
 }
}
def Xform "B"
{
 def Material "Mat"
 {
  token outputs:surface.connect = </B/Mat/Surface.outputs:surface>
  def Shader "Surface"
  {
   uniform token info:id = "UsdPreviewSurface"
   float inputs:metallic.connect = </B/Mat/Metal.outputs:b>
   float inputs:roughness.connect = </B/Mat/Rough.outputs:g>
   token outputs:surface
  }
  def Shader "Metal"
  {
   uniform token info:id = "UsdUVTexture"
   asset inputs:file = @maps/metal.png@
   float outputs:b
  }
  def Shader "Rough"
  {
   uniform token info:id = "UsdUVTexture"
   asset inputs:file = @maps/rough.png@
   float outputs:g
  }
 }
 def Material "Custom"
 {
  token outputs:mtlx:surface.connect = </B/Custom/Surface.outputs:out>
  def Shader "Surface"
  {
   uniform token info:id = "ND_standard_surface_surfaceshader"
   token outputs:out
  }
 }
 def Mesh "Unsupported"
 {
  rel material:binding = </B/Custom>
  point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
  int[] faceVertexCounts = [3]
  int[] faceVertexIndices = [0,1,2]
  uniform token subdivisionScheme = "none"
  color3f[] primvars:displayColor = [(0.2,0.8,0.4)]
 }
}`

@(test)
usd_material_networks_resolve_through_graphs_and_bindings :: proc(t:^testing.T) {
    folder:=temp_folder("usd-networks")
    defer os.remove_all(folder)
    path:=write_text(folder,"networks.usda",NETWORKS)
    model,ok:=import_ok(t,path,TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),3)
    testing.expect_value(t,len(model.materials),2)
    inherits,own,unsupported:=mesh_named(&model,"Inherits"),mesh_named(&model,"Own"),mesh_named(&model,"Unsupported")
    testing.expect(t,inherits!=nil && own!=nil && unsupported!=nil)
    if inherits==nil || own==nil || unsupported==nil {return}
    testing.expect(t,importer.mesh_triangle(inherits,0)[2].uv=={0,0},"metadata before the interpolation of a primvar is skipped")
    first:=&model.materials[inherits.slots[0].material]
    testing.expect_value(t,first.name,"Mat")
    packed,glow:=first.images[.Metallic_Roughness],first.images[.Emission]
    testing.expect(t,packed>=0 && strings.has_suffix(model.images[packed].path,"/maps/rough.png") && first.info.roughness==1 && abs(first.info.metallic-0.5)<1e-5,"roughness alone in the green of an image is the packed map, next to a constant metallic")
    testing.expect(t,glow>=0 && model.images[glow].srgb && first.info.emission=={1,1,1},"a textured emission leaves its factor at 1")
    testing.expect(t,first.info.alpha_mode==.Blend && abs(first.info.opacity-0.25)<1e-5,"an opacityThreshold of 0 does not mask")
    second:=&model.materials[own.slots[0].material]
    testing.expect_value(t,second.name,"/B/Mat")
    testing.expect(t,abs(second.info.roughness-0.5)<1e-5 && second.info.metallic==0,"metallic and roughness in different images cannot be packed: both keep their defaults")
    for image in second.images {testing.expect(t,image<0)}
    testing.expect(t,own.vertices[0].color==importer.WHITE)
    testing.expect(t,unsupported.slots[0].material==-1 && close_to(color_of(unsupported.vertices[0].color),{0.2,0.8,0.4},1.0/255),"a mesh whose material is not imported keeps its displayColor")
}

@(test)
images_next_to_the_usd_file_and_failures_without_leftovers :: proc(t:^testing.T) {
    folder:=temp_folder("usd-images")
    defer os.remove_all(folder)
    MATERIAL :: `#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Material "Paint"
{
 token outputs:surface.connect = </Paint/Surface.outputs:surface>
 def Shader "Surface"
 {
  uniform token info:id = "UsdPreviewSurface"
  color3f inputs:diffuseColor.connect = </Paint/Color.outputs:rgb>
  token outputs:surface
 }
 def Shader "Color"
 {
  uniform token info:id = "UsdUVTexture"
  asset inputs:file = @color.png@
  float3 outputs:rgb
 }
}
def Mesh "Painted"
{
 rel material:binding = </Paint>
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
 uniform token subdivisionScheme = "none"
}
`
    write_text(folder,"color.png","the image")
    model,ok:=import_ok(t,write_text(folder,"model.usda",MATERIAL),TEXT_ONLY)
    if ok {
        testing.expect(t,len(model.materials)==1 && len(model.images)==1 && model.materials[0].name=="Paint")
        testing.expect(t,strings.has_suffix(model.images[0].path,"/color.png") && os.exists(model.images[0].path),"the path names the image next to the USD file")
        importer.model_destroy(&model)
    }
    broken:=write_text(folder,"broken.usda",strings.concatenate({MATERIAL,`def Mesh "Broken"
{
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
 uniform token subdivisionScheme = "none"
 texCoord2f[] primvars:st = [(0,0),(1,0)] (
  interpolation = "vertex"
 )
}
`},context.temp_allocator))
    _,error:=usd_read(broken,TEXT_ONLY)
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expect(t,contains(error.message,"primvars:st") && contains(error.message,"/Broken"),error.message)
}

@(test)
what_a_static_importer_cannot_hold_is_rejected_by_name :: proc(t:^testing.T) {
    folder:=temp_folder("usd-reject")
    defer os.remove_all(folder)
    HEADER :: "#usda 1.0\n(\n metersPerUnit = 1\n upAxis = \"Y\"\n)\n"
    TRIANGLE :: "  point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]\n  int[] faceVertexCounts = [3]\n  int[] faceVertexIndices = [0,1,2]\n"
    cases:=[?]struct{body,expect:string,code:importer.Error_Code}{
        {"def Mesh \"M\"\n{\n"+TRIANGLE+"}\n","Catmull-Clark",.Unsupported},
        {"def Mesh \"M\"\n{\n"+TRIANGLE+"  uniform token subdivisionScheme = \"catmullClark\"\n}\n","subdivision",.Unsupported},
        {"def Sphere \"S\"\n{\n}\n","Sphere",.Unsupported},
        {"def Mesh \"M\"\n{\n"+TRIANGLE+"  uniform token subdivisionScheme = \"none\"\n  point3f[] points.timeSamples = {0: [(0,0,0),(1,0,0),(0,1,0)]}\n}\n","time-sampled",.Unsupported},
        {"def Mesh \"M\"\n{\n point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]\n int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0,1,7]\n uniform token subdivisionScheme = \"none\"\n}\n","outside",.Malformed},
        {"def Mesh \"M\"\n{\n"+TRIANGLE+"  uniform token subdivisionScheme = \"none\"\n","not closed",.Malformed},
        {"def Mesh \"M\"\n{\n point3f[] points = [(0,0,zero),(1,0,0),(0,1,0)]\n int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0,1,2]\n uniform token subdivisionScheme = \"none\"\n}\n","numbers",.Malformed},
        {"def Mesh \"M\"\n{\n"+TRIANGLE+"  uniform token subdivisionScheme = \"none\"\n  token orientation = \"sideways\"\n}\n","orientation",.Malformed},
        {"# nothing at all\n","no polygon geometry",.Malformed},
    }
    for entry,i in cases {
        path:=write_text(folder,fmt.tprintf("case-%d.usda",i),strings.concatenate({HEADER,entry.body},context.temp_allocator))
        _,error:=usd_read(path,TEXT_ONLY)
        testing.expectf(t,error.code==entry.code && contains(error.message,entry.expect),"case %d: %v %s",i,error.code,error.message)
    }
}

@(test)
left_handed_meshes_flip_their_winding_and_holes_are_skipped :: proc(t:^testing.T) {
    folder:=temp_folder("usd-winding")
    defer os.remove_all(folder)
    path:=write_text(folder,"w.usda",`#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Mesh "Left"
{
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0),(1,1,0)]
 int[] faceVertexCounts = [3, 3]
 int[] faceVertexIndices = [0,1,2, 1,3,2]
 int[] holeIndices = [1]
 uniform token orientation = "leftHanded"
 uniform token subdivisionScheme = "none"
}
`)
    model,ok:=import_ok(t,path,TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    mesh:=&model.meshes[0]
    testing.expect_value(t,triangle_count(mesh),1)
    testing.expect(t,close_to(corner_normal(mesh.vertices[0].normal),{0,0,1},1e-3),"a left-handed face looks the other way")
}

@(private="file")
write_tool :: proc(folder,name,windows,unix:string) -> string {
    when ODIN_OS==.Windows {
        path:=write_text(folder,fmt.tprintf("%s.bat",name),windows)
    } else {
        path:=write_text(folder,name,unix)
        _=os.chmod(path,{.Read_User,.Write_User,.Execute_User})
    }
    return path
}

@(test)
the_text_of_usdcat_is_what_is_read_and_its_failure_is_reported :: proc(t:^testing.T) {
    folder:=temp_folder("usd-tool")
    defer os.remove_all(folder)
    flattened:=write_text(folder,"flattened.usda",`#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Mesh "FromTheTool"
{
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
 uniform token subdivisionScheme = "none"
}
`)
    tool:=write_tool(folder,"usdcat","@echo off\r\ntype \"%~dp0flattened.usda\"\r\n","#!/bin/sh\ncat \"$(dirname \"$0\")/flattened.usda\"\n")
    _=flattened
    source:=write_text(folder,"binary.usdc","PXR-USDC and a body that no text parser could read")
    model,ok:=import_ok(t,source,{usdcat=tool})
    if ok {
        testing.expect(t,len(model.meshes)==1 && model.meshes[0].name=="FromTheTool","the flattened text of the tool is what is imported")
        importer.model_destroy(&model)
    }
    failing:=write_tool(folder,"failing","@echo off\r\necho cannot compose 1>&2\r\nexit /b 3\r\n","#!/bin/sh\necho cannot compose >&2\nexit 3\n")
    _,error:=usd_read(source,{usdcat=failing})
    testing.expect_value(t,error.code,importer.Error_Code.Tool)
    testing.expect(t,contains(error.message,"cannot compose"),error.message)
}

@(test)
a_usd_texture_transform_is_turned_to_v_from_the_top :: proc(t:^testing.T) {
    folder:=temp_folder("usd-transform")
    defer os.remove_all(folder)
    STAGE :: `#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Material "Paint"
{
 token outputs:surface.connect = </Paint/Surface.outputs:surface>
 def Shader "Surface"
 {
  uniform token info:id = "UsdPreviewSurface"
  color3f inputs:diffuseColor.connect = </Paint/Color.outputs:rgb>
  token outputs:surface
 }
 def Shader "Color"
 {
  uniform token info:id = "UsdUVTexture"
  asset inputs:file = @color.png@
  float2 inputs:st.connect = </Paint/Place.outputs:result>
  float3 outputs:rgb
 }
 def Shader "Place"
 {
  uniform token info:id = "UsdTransform2d"
  float2 inputs:in.connect = </Paint/Reader.outputs:result>
  float inputs:rotation = 90
  float2 inputs:scale = (2, 1)
  float2 inputs:translation = (0.25, 0)
  float2 outputs:result
 }
 def Shader "Reader"
 {
  uniform token info:id = "UsdPrimvarReader_float2"
  token inputs:varname = "st"
  float2 outputs:result
 }
}
def Mesh "Painted"
{
 rel material:binding = </Paint>
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
 texCoord2f[] primvars:st = [(0,0),(1,0),(0,1)] (
  interpolation = "vertex"
 )
 uniform token subdivisionScheme = "none"
}
`
    write_text(folder,"color.png","the image")
    model,ok:=import_ok(t,write_text(folder,"model.usda",STAGE),TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    // st' = R(90°)·S·st + t in st, from the bottom; the same mapping read from the top.
    base:=importer.material_map(&model.materials[0].info,.Base_Color)
    angle:=math.to_radians(f32(90))
    testing.expect_value(t,base.rotation,-angle)
    testing.expect_value(t,base.scale,[2]f32{2,1})
    testing.expect_value(t,base.offset,[2]f32{0.25-math.sin(angle),1-math.cos(angle)})
    corners:=importer.mesh_triangle(&model.meshes[0],0)
    testing.expect(t,corners[0].uv=={0,1} && corners[2].uv=={0,0},"st counts v from the bottom")
}

@(test)
a_usd_clearcoat_is_a_white_coat_of_the_index_of_the_surface :: proc(t:^testing.T) {
    folder:=temp_folder("usd-clearcoat")
    defer os.remove_all(folder)
    STAGE :: `#usda 1.0
(
 metersPerUnit = 1
 upAxis = "Y"
)
def Material "Lacquer"
{
 token outputs:surface.connect = </Lacquer/Surface.outputs:surface>
 def Shader "Surface"
 {
  uniform token info:id = "UsdPreviewSurface"
  float inputs:clearcoat = 0.7
  float inputs:clearcoatRoughness.connect = </Lacquer/Rough.outputs:g>
  float inputs:ior = 1.4
  token outputs:surface
 }
 def Shader "Rough"
 {
  uniform token info:id = "UsdUVTexture"
  asset inputs:file = @rough.png@
  float outputs:g
 }
}
def Mesh "Coated"
{
 rel material:binding = </Lacquer>
 point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
 texCoord2f[] primvars:st = [(0,0),(1,0),(0,1)] (
  interpolation = "vertex"
 )
 uniform token subdivisionScheme = "none"
}
`
    write_text(folder,"rough.png","the image")
    model,ok:=import_ok(t,write_text(folder,"model.usda",STAGE),TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.materials),1) {return}
    coat:=model.materials[0].info.coat
    testing.expect(t,coat.weight==0.7 && coat.ior==1.4 && coat.color=={1,1,1},"the coat takes its amount and the index of the surface")
    testing.expect(t,coat.roughness==1 && model.materials[0].images[.Coat_Roughness]>=0,"a textured roughness is read from green and leaves the factor at 1")
    testing.expect_value(t,model.materials[0].images[.Coat],-1)
}
