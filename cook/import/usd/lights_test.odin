package usd

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import "mirai:std/base"
import mm "mirai:std/math"

// A Z-up stage in centimeters with a floor and each light UsdLux has an
// equivalent for.
@(private="file")
LIGHTS :: `#usda 1.0
(
    metersPerUnit = 0.01
    upAxis = "Z"
)
def Xform "World"
{
    def SphereLight "Bulb"
    {
        float inputs:intensity = 100
        float inputs:exposure = 1
        color3f inputs:color = (1, 0.5, 0.25)
        float inputs:radius = 5
        double3 xformOp:translate = (100, 0, 200)
        uniform token[] xformOpOrder = ["xformOp:translate"]
        def Xform "Shade"
        {
            double3 xformOp:translate = (0, 0, 10)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
    }
    def SphereLight "Spot" (
        prepend apiSchemas = ["ShapingAPI"]
    )
    {
        float inputs:intensity = 10
        float inputs:radius = 2
        bool inputs:treatAsPoint = 1
        float inputs:shaping:cone:angle = 30
        float inputs:shaping:cone:softness = 0.5
    }
    def RectLight "Panel"
    {
        float inputs:intensity = 10
        float inputs:width = 200
        float inputs:height = 50
        bool inputs:normalize = 1
        float3 xformOp:scale = (2, 1, 1)
        uniform token[] xformOpOrder = ["xformOp:scale"]
    }
    def DiskLight "Disk"
    {
        float intensity = 4
        float radius = 10
    }
    def DistantLight "Sun"
    {
        float inputs:intensity = 50000
        bool inputs:enableColorTemperature = 1
        float inputs:colorTemperature = 6500
    }
    def DistantLight "Noon"
    {
        float inputs:intensity = 100000
        float inputs:angle = 2
        bool inputs:normalize = 1
    }
    def DomeLight "Sky"
    {
    }
    def Mesh "Floor"
    {
        point3f[] points = [(0, 0, 0), (100, 0, 0), (0, 100, 0)]
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        uniform token subdivisionScheme = "none"
    }
}
`

@(private="file")
light_of :: proc(t:^testing.T,model:^importer.Imported_Model,name:string) -> (light:importer.Imported_Light,row:int) {
    row=find_node(model,name)
    if !testing.expectf(t,row>=0,"the node %s",name) {return}
    has:bool
    light,has=model.nodes[row].light.?
    testing.expectf(t,has,"%s has a light",name)
    return
}

@(private="file")
near :: proc(a,b:f32,tolerance:f32=1e-4) -> bool {return abs(a-b)<=tolerance*max(abs(b),1e-6)}

// Each light reaches its node in the units of Imported_Light: the luminance
// of UsdLux times the area a point or spot shows in m², a rectangle in nits
// and a sun in lux; it shines down in the engine as it shines down in a
// Z-up stage, and the children of a light stay where they were.
@(test)
usd_lights_are_imported_in_photometric_units_toward_their_axis :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"lights")
    if folder=="" {return}
    model,ok:=import_ok(t,write_text(folder,"lights.usda",LIGHTS),TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    down:=[3]f32{0,-1,0}

    bulb,bulb_row:=light_of(t,&model,"Bulb")
    radius,has_radius:=bulb.radius.?
    testing.expectf(t,bulb.kind==.Point && has_radius && near(radius,0.05),"a sphere of 5 cm is a point of that radius: %v",bulb)
    testing.expectf(t,near(bulb.intensity,200*math.PI*0.05*0.05),"candelas of 200 nits over a disc of 5 cm: %v",bulb.intensity)
    testing.expect(t,bulb.color=={1,0.5,0.25})
    if bulb_row>=0 {testing.expect(t,close_to(world_transform(&model,bulb_row).position,{-1,2,0}),"Z up and centimeters are the engine's")}
    if shade:=find_node(&model,"Shade");testing.expect(t,shade>=0) {
        world:=world_transform(&model,shade)
        testing.expectf(t,close_to(world.position,{-1,2.1,0}) && close_to(mm.quat_forward(world.rotation),{0,0,-1}),"the child of a light keeps its place and turn: %v",world)
    }

    spot,spot_row:=light_of(t,&model,"Spot")
    spot_radius,spot_sized:=spot.radius.?
    testing.expectf(t,spot.kind==.Spot && spot_sized && spot_radius==0,"a cone makes a spot, a point as treatAsPoint asks: %v",spot)
    testing.expect(t,near(spot.outer_cone,math.to_radians(f32(30))) && near(spot.inner_cone,math.to_radians(f32(15))),"the cone and its softness")
    testing.expectf(t,near(spot.intensity,10*math.PI*0.02*0.02),"the candelas of the sphere it was given: %v",spot.intensity)
    if spot_row>=0 {testing.expect(t,close_to(mm.quat_forward(world_transform(&model,spot_row).rotation),down),"it shines down, along -Z of its prim")}

    panel,panel_row:=light_of(t,&model,"Panel")
    testing.expectf(t,panel.kind==.Rect && close_to({panel.size.x,panel.size.y,0},{2,0.5,0}),"a rectangle in meters: %v",panel)
    testing.expectf(t,near(panel.intensity,10.0/(200*50*2)),"normalize divides by its area in the world, in the units of the stage: %v",panel.intensity)
    if panel_row>=0 {
        world:=world_transform(&model,panel_row)
        testing.expect(t,close_to(mm.quat_forward(world.rotation),down),"it lights the floor")
        x,y:=mm.quat_rotate(world.rotation,{1,0,0}),mm.quat_rotate(world.rotation,{0,1,0})
        testing.expectf(t,abs(x.x)>0.999 && abs(y.z)>0.999,"its width and height stay along x and y of the prim: %v %v",x,y)
        testing.expectf(t,close_to(world.scale,{2,1,1}),"the scale of the prim stays on its x: %v",world.scale)
    }

    disk,_:=light_of(t,&model,"Disk")
    side:=0.1*math.sqrt(f32(math.PI))
    testing.expectf(t,disk.kind==.Rect && near(disk.size.x,side) && near(disk.size.y,side) && disk.intensity==4,"a disk is the square of its area, in its nits, read by the names before inputs: %v",disk)

    sun,sun_row:=light_of(t,&model,"Sun")
    disc:=math.PI*math.pow(math.sin(math.to_radians(f64(0.53))/2),2)
    white:=mm.blackbody_linear(6500)
    peak:=max(white.r,white.g,white.b)
    testing.expectf(t,sun.kind==.Directional && near(sun.intensity,f32(50000*disc)*peak),"without normalize, the luminance over the disc of the sun, its color below one: %v",sun.intensity)
    testing.expectf(t,abs(sun.color.r-1)<0.06 && abs(sun.color.g-1)<0.06 && abs(sun.color.b-1)<0.06,"6500 K is about white: %v",sun.color)
    if sun_row>=0 {testing.expect(t,close_to(mm.quat_forward(world_transform(&model,sun_row).rotation),down),"the sun shines down")}
    noon,_:=light_of(t,&model,"Noon")
    testing.expectf(t,noon.kind==.Directional && noon.intensity==100000,"normalized, the intensity is the lux it gives: %v",noon.intensity)

    sky:=find_node(&model,"Sky")
    testing.expect(t,sky>=0 && model.nodes[sky].light==nil,"a dome light is a node without a light")
    testing.expectf(t,len(model.warnings)==2,"the disk and the dome are reported: %v",model.warnings)
}

// What a light cannot be is refused with the prim that has it.
@(test)
usd_lights_that_cannot_be_kept_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"lights-refused")
    if folder=="" {return}
    HEADER :: "#usda 1.0\n(\n metersPerUnit = 1\n upAxis = \"Y\"\n)\n"
    cases:=[]struct{body:string,code:importer.Error_Code,part:string}{
        {"def RectLight \"Panel\"\n{\n def Xform \"Inside\"\n {\n }\n}\n",.Unsupported,"/Panel/Inside"},
        {"def SphereLight \"Bulb\"\n{\n float inputs:radius = -1\n}\n",.Malformed,"/Bulb"},
        {"def SphereLight \"Bulb\"\n{\n float inputs:intensity = -5\n}\n",.Malformed,"negative"},
        {"def DiskLight \"Spot\"\n{\n float inputs:shaping:cone:angle = 0\n}\n",.Malformed,"cone"},
    }
    for entry,i in cases {
        path:=write_text(folder,fmt.tprintf("case-%d.usda",i),strings.concatenate({HEADER,entry.body},context.temp_allocator))
        _,error:=usd_read(path,TEXT_ONLY)
        testing.expectf(t,error.code==entry.code && contains(error.message,entry.part),"case %d: %v %s",i,error.code,error.message)
    }
}
