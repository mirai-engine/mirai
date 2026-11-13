package usd

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import mm "mirai:std/math"
import "mirai:std/subprocess"

// USD, USDA and USDC. Composition and the binary crate are the job of the
// external usdcat (--flatten): without it only a USDA file that needs no
// composition can be read. The meshes and materials are read from the
// flattened text by the parser of usd_text.odin. Each file states its units
// and up axis; v counts from the bottom of the image.

FORMAT :: importer.Format{
    name="USD",
    extensions={0=".usd",1=".usda",2=".usdc"},
    version=1,
    space={meters_per_unit=0.01,axes=importer.FACING_PLUS_Z,v_origin=.Bottom},
    sniff=sniff,
    read=read,
}

// What the USD format is given as Format.data.
Options :: struct {
    usdcat:string,  // path of usdcat; "": USD_CAT, well-known places and PATH
    no_usdcat:bool, // read USD text without composing it
}

// FORMAT with options other than its defaults; options outlives the imports.
format :: proc(options:^Options) -> importer.Format {
    with:=FORMAT
    with.data=options
    return with
}

// The text form by its header and the binary crate by its magic. A USDZ is
// a zip the importer does not open.
sniff :: proc(head:[]u8) -> importer.Sniff {
    text:=string(head)
    if strings.has_prefix(text,"#usda") || strings.has_prefix(text,"PXR-USDC") {return .Content}
    return .No
}

@(private="file")
WELL_KNOWN_USDCAT :: [?]string{"/usr/bin/usdcat","/usr/local/bin/usdcat","/opt/homebrew/bin/usdcat"}

// options.usdcat, USD_CAT, the usual places and PATH, in that order.
usdcat_path :: proc(options:Options) -> (path:string,found:bool) {
    if options.usdcat!="" {return options.usdcat,true}
    if value,exists:=os.lookup_env("USD_CAT",context.temp_allocator);exists && value!="" {return value,true}
    for candidate in WELL_KNOWN_USDCAT {
        if os.exists(candidate) {return candidate,true}
    }
    separator:=";" when ODIN_OS==.Windows else ":"
    executable:="usdcat.exe" when ODIN_OS==.Windows else "usdcat"
    environment,_:=os.lookup_env("PATH",context.temp_allocator)
    for directory in strings.split(environment,separator,context.temp_allocator) {
        if directory=="" {continue}
        candidate,_:=filepath.join({directory,executable},context.temp_allocator)
        if os.exists(candidate) {return candidate,true}
    }
    return "",false
}

read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {
    options:Options
    if r.data!=nil {options=(^Options)(r.data)^}
    is_text:=strings.has_prefix(string(bytes),"#usda")
    command,has_tool:=usdcat_path(options)
    if has_tool && !options.no_usdcat {
        state,stdout,stderr,error:=subprocess.exec({command={command,"--flatten","--skipSourceFileComment",r.path}},context.temp_allocator)
        if error!=nil {return importer.fail(r,.Tool,"usdcat could not run (set USD_CAT to its executable): %v",error)}
        if !state.success || state.exit_code!=0 {return importer.fail(r,.Tool,"usdcat could not compose %s: %s",r.file_name,string(stderr))}
        return usd_import(r,string(stdout),true)
    }
    if !is_text {return importer.fail(r,.Tool,"%s is a binary USD file: reading it needs usdcat (set USD_CAT to its executable)",r.file_name)}
    return usd_import(r,string(bytes),false)
}

@(private="file")
Usd_Import :: struct {
    r:^importer.Reader,
    prims:[]Usd_Prim,
    paths:map[string]int,          // path of a prim to its position in prims
    materials:map[int]int,         // Material prim to its row in the model, -1 when it is not imported
    composed:bool,
}

@(private="file")
inverse_checked :: proc(m:mm.Mat4) -> (inverse:mm.Mat4,ok:bool) {
    if abs(linalg.determinant(m))<1e-12 {return 1,false}
    return linalg.inverse(m),true
}

@(private="file")
axis_rotation :: proc(axis:int,degrees:f32) -> mm.Mat4 {
    direction:[3]f32
    direction[axis]=1
    return linalg.matrix4_rotate_f32(math.to_radians(degrees),direction)
}

@(private="file")
op_matrix :: proc(r:^importer.Reader,name:string,property:Usd_Property) -> (m:mm.Mat4,ok:bool) {
    m=1
    values:=usd_numbers(r,property) or_return
    parts:=strings.split(name,":",context.temp_allocator)
    if len(parts)<2 {return m,importer.fail(r,.Malformed,"%s is not the name of a USD transform op",name)}
    op:=parts[1]
    switch {
    case op=="transform":
        if len(values)!=16 {return m,importer.fail(r,.Malformed,"a USD transform op needs a 4x4 matrix")}
        // A row-vector matrix written by rows is, flattened, the column storage of the matrix of column vectors.
        flat:[16]f32
        for v,i in values {flat[i]=f32(v)}
        m=transmute(mm.Mat4)flat
    case op=="translate" || op=="scale" || strings.has_prefix(op,"rotate"):
        v:[3]f32
        if len(values)==1 && (op=="rotateX" || op=="rotateY" || op=="rotateZ") {
            axis:=int(op[len(op)-1]-'X')
            v[axis]=f32(values[0])
        } else if len(values)==3 {
            v={f32(values[0]),f32(values[1]),f32(values[2])}
        } else {
            return m,importer.fail(r,.Malformed,"the USD op %s has %d values",op,len(values))
        }
        switch op {
        case "translate": m=linalg.matrix4_translate_f32(v)
        case "scale": m=linalg.matrix4_scale_f32(v)
        case "rotateX","rotateY","rotateZ","rotateXYZ","rotateXZY","rotateYXZ","rotateYZX","rotateZXY","rotateZYX":
            // The name states the order in which the rotations act on a point.
            for axis_char in op[6:] {
                axis:=int(axis_char-'X')
                m=axis_rotation(axis,v[axis])*m
            }
        case: return m,importer.fail(r,.Unsupported,"the USD rotation op %s is unsupported",op)
        }
    case op=="orient":
        if len(values)!=4 {return m,importer.fail(r,.Malformed,"a USD orient op needs w, x, y and z")}
        length:=math.sqrt(f32(values[0]*values[0]+values[1]*values[1]+values[2]*values[2]+values[3]*values[3]))
        if !(length>1e-12) {return m,importer.fail(r,.Malformed,"a USD orient op has a quaternion of length zero")}
        m=linalg.matrix4_from_quaternion_f32(quaternion(w=f32(values[0])/length,x=f32(values[1])/length,y=f32(values[2])/length,z=f32(values[3])/length))
    case:
        return m,importer.fail(r,.Unsupported,"the USD transform op %s is unsupported",op)
    }
    return m,true
}

@(private="file")
prim_transform :: proc(r:^importer.Reader,prim:^Usd_Prim,parent_world:mm.Mat4) -> bool {
    local:mm.Mat4=1
    reset:=false
    if order,found:=prim.properties["xformOpOrder"];found {
        for op in usd_strings(order) {
            if op=="!resetXformStack!" {reset=true;continue}
            inverse:=strings.has_prefix(op,"!invert!")
            property_name:=op
            if inverse {property_name=op[len("!invert!"):]}
            property,exists:=prim.properties[property_name]
            if !exists {return importer.fail(r,.Malformed,"xformOpOrder names %s, which the prim does not have",property_name)}
            m:=op_matrix(r,property_name,property) or_return
            if inverse {
                inverted,ok:=inverse_checked(m)
                if !ok {return importer.fail(r,.Malformed,"an inverted USD transform op is singular")}
                m=inverted
            }
            local=local*m
        }
    }
    world:=parent_world*local
    if reset {
        world=local
        inverse,ok:=inverse_checked(parent_world)
        if !ok {return importer.fail(r,.Unsupported,"a USD reset transform cannot be kept under a singular parent")}
        local=inverse*world
    }
    prim.local,prim.world=local,world
    return true
}

// What the importer rejects in any prim.
@(private="file")
prim_static :: proc(u:^Usd_Import,prim:Usd_Prim) -> bool {
    r:=u.r
    if property,found:=prim.properties["instanceable"];found && usd_string(property)=="true" {
        return importer.fail(r,.Unsupported,"%s: USD native instances require de-instancing before export",prim.path)
    }
    for key in ([]string{"references","payload","inherits","specializes","variantSets"}) {
        if _,found:=prim.properties[key];found {
            if !u.composed {return importer.fail(r,.Tool,"%s uses %s: composing it needs usdcat (set USD_CAT to its executable)",prim.path,key)}
            return importer.fail(r,.Unsupported,"%s: unresolved USD %s remain after flattening; de-instance before export",prim.path,key)
        }
    }
    for name in prim.properties {
        if strings.has_suffix(name,".timeSamples") {return importer.fail(r,.Unsupported,"%s: time-sampled USD properties are outside the static importer",prim.path)}
    }
    return true
}

@(private="file")
usd_import :: proc(r:^importer.Reader,source:string,composed:bool) -> bool {
    parser:=usd_parse(r,source) or_return
    if !composed {
        if _,found:=parser.metadata["subLayers"];found {return importer.fail(r,.Tool,"%s uses sublayers: composing it needs usdcat (set USD_CAT to its executable)",r.file_name)}
    }
    // Without metadata USD means centimeters and +Y up.
    space:=FORMAT.space
    if property,found:=parser.metadata["metersPerUnit"];found {
        values:=usd_numbers(r,property) or_return
        if len(values)!=1 || values[0]<=0 {return importer.fail(r,.Malformed,"metersPerUnit of the USD file is invalid")}
        space.meters_per_unit=f32(values[0])
    }
    if property,found:=parser.metadata["upAxis"];found {
        axis:=usd_string(property)
        // +Z up: the front of a model is toward -Y.
        if axis=="Z" {space.axes={.Negative_X,.Z,.Y}} else if axis!="Y" {return importer.fail(r,.Malformed,"upAxis of the USD file must be Y or Z")}
    }
    importer.source_space(r,space) or_return
    u:=Usd_Import{r=r,prims=parser.prims[:],composed=composed}
    u.paths.allocator=context.temp_allocator;u.materials.allocator=context.temp_allocator
    for prim,i in parser.prims {u.paths[prim.path]=i}
    prim_nodes:=make([]int,len(parser.prims),context.temp_allocator)
    shading:=make([]bool,len(parser.prims),context.temp_allocator)
    for &prim,i in parser.prims {
        // Materials and what they hold are not nodes of the hierarchy.
        shading[i]=prim.type_name=="Material" || prim.type_name=="Shader" || prim.type_name=="NodeGraph" || (prim.parent>=0 && shading[prim.parent])
        if shading[i] {
            prim_static(&u,prim) or_return
            continue
        }
        parent_world:mm.Mat4=1
        if prim.parent>=0 {parent_world=parser.prims[prim.parent].world}
        if !prim_transform(r,&prim,parent_world) {return false}
        local:=prim.local
        if prim.parent>=0 {
            switch parser.prims[prim.parent].type_name {
            case "RectLight","DiskLight": return importer.fail(r,.Unsupported,"%s: a prim under the %s %s, which its scale sizes; move it out of the light",prim.path,parser.prims[prim.parent].type_name,parser.prims[prim.parent].path)
            }
        }
        bottom:=abs(local[3,0])+abs(local[3,1])+abs(local[3,2])+abs(local[3,3]-1)
        transform,decomposed:=mm.transform_from_matrix(local)
        if bottom>1e-4 || !decomposed || !importer.transform_finite(transform) {
            return importer.fail(r,.Unsupported,"%s: its transform has shear, perspective or a scale of zero; apply it to the geometry before export",prim.path)
        }
        parent:=-1
        if prim.parent>=0 {parent=prim_nodes[prim.parent]}
        visible:=true
        if property,found:=prim.properties["visibility"];found {visible=usd_string(property)!="invisible"}
        if property,found:=prim.properties["active"];found {visible=visible && usd_string(property)!="false"}
        row:=len(r.nodes)
        prim_nodes[i]=row
        append(&r.nodes,importer.Imported_Node{name=importer.own(r,prim.name),parent=parent,transform=transform,mesh=-1,visible=visible})
        switch prim.type_name {
        case "Mesh":
            material:=usd_material(&u,usd_binding(&u,i))
            if importer.failed(r) {return importer.fail_prefix(r,prim.path)}
            if material>=0 {
                for image,slot in r.materials[material].images {
                    if image>=0 && importer.material_map(&r.materials[material].info,slot).uv_set==1 {
                        if "primvars:st1" not_in prim.properties {return importer.fail(r,.Malformed,"%s: its material uses st1 but the mesh has no primvars:st1",prim.path)}
                    }
                }
            }
            mesh_row,has_triangles,ok:=usd_mesh(r,prim,material)
            if !ok {return importer.fail_prefix(r,prim.path)}
            if has_triangles {r.nodes[row].mesh=mesh_row}
            if has_triangles && usd_collides(prim) {usd_collider(r,prim,row,mesh_row) or_return}
        case "SphereLight","DiskLight","RectLight","DistantLight":
            light,read:=usd_light(r,prim)
            if !read {return importer.fail_prefix(r,prim.path)}
            r.nodes[row].light=light
        case "CylinderLight","DomeLight","DomeLight_1","GeometryLight","PortalLight","PluginLight":
            importer.warn(r,"%s: a USD %s is not imported",prim.path,prim.type_name)
        case "Cube","Sphere","Capsule","Cylinder","Cone":
            if !usd_collides(prim) {return importer.fail(r,.Unsupported,"%s: %s is unsupported; export static polygon meshes, or give it PhysicsCollisionAPI to collide as it",prim.path,prim.type_name)}
            usd_collider(r,prim,row,-1) or_return
        case "PointInstancer","BasisCurves","NurbsCurves","NurbsPatch":
            return importer.fail(r,.Unsupported,"%s: %s is unsupported; export static polygon meshes",prim.path,prim.type_name)
        }
        prim_static(&u,prim) or_return
    }
    if r.degenerate>0 {importer.warn(r,"%d faces without area were skipped",r.degenerate)}
    return true
}

// The attribute that gives an attribute its value: the end of its connections,
// through the inputs and outputs of materials and node graphs.
@(private="file")
usd_source :: proc(u:^Usd_Import,prim:int,name:string) -> (int,string) {
    prim,name:=prim,name
    for _ in 0..<16 {
        connection,connected:=u.prims[prim].properties[strings.concatenate({name,".connect"},context.temp_allocator)]
        if !connected {return prim,name}
        target:=usd_string(connection)
        dot:=strings.index_byte(target,'.')
        if dot<0 {break}
        next,known:=u.paths[target[:dot]]
        if !known {break}
        prim,name=next,target[dot+1:]
    }
    return -1,""
}

// The Material prim bound to a prim: by its importer.own material:binding, or by the
// one of the nearest ancestor that has it.
@(private="file")
usd_binding :: proc(u:^Usd_Import,prim:int) -> int {
    for i:=prim;i>=0;i=u.prims[i].parent {
        binding,bound:=u.prims[i].properties["material:binding"]
        if !bound {continue}
        if material,known:=u.paths[usd_string(binding)];known && u.prims[material].type_name=="Material" {return material}
    }
    return -1
}

// What an input of a shader reads: the image and the output of the
// UsdUVTexture it is connected to, and its numbers.
@(private="file")
Usd_Input :: struct {
    numbers:[]f64,
    file,channel:string,
    mapping:asset.Material_Map,
}

@(private="file")
usd_input :: proc(u:^Usd_Import,shader:int,name:string) -> (input:Usd_Input) {
    input.mapping=asset.MATERIAL_MAP_DEFAULT
    prim,attribute:=usd_source(u,shader,name)
    if prim>=0 && u.prims[prim].type_name=="Shader" && strings.has_prefix(attribute,"outputs:") {
        if usd_string(u.prims[prim].properties["info:id"])=="UsdUVTexture" {
            if file_prim,file_attribute:=usd_source(u,prim,"inputs:file");file_prim>=0 {input.file=usd_string(u.prims[file_prim].properties[file_attribute])}
            input.channel=attribute[len("outputs:"):]
            input.mapping=usd_texture_mapping(u,prim)
        }
        prim=-1
    }
    // Next to a connection to a shader, the numbers are those written on the input itself.
    if prim<0 {prim,attribute=shader,name}
    if property,found:=u.prims[prim].properties[attribute];found {input.numbers,_=usd_numbers(u.r,property)}
    return
}

@(private="file")
input_color :: proc(input:Usd_Input,fallback:[3]f32) -> [3]f32 {
    return {f32(input.numbers[0]),f32(input.numbers[1]),f32(input.numbers[2])} if len(input.numbers)==3 else fallback
}

@(private="file")
input_number :: proc(input:Usd_Input,fallback:f32) -> f32 {
    return f32(input.numbers[0]) if len(input.numbers)==1 else fallback
}

// A texture binding without the shader graph, in st as USD counts it: from
// the bottom of the image.
@(private="file")
usd_texture_mapping :: proc(u:^Usd_Import,texture:int) -> (mapping:asset.Material_Map) {
    r:=u.r
    mapping=asset.MATERIAL_MAP_DEFAULT
    prim,attribute:=usd_source(u,texture,"inputs:st")
    if prim<0 {importer.fail(r,.Malformed,"the texture coordinate connection of a USD texture is invalid or cyclic");return}
    if prim==texture {return}
    if u.prims[prim].type_name!="Shader" || !strings.has_prefix(attribute,"outputs:") {
        importer.fail(r,.Unsupported,"USD texture coordinates must come from UsdPrimvarReader_float2 or UsdTransform2d")
        return
    }
    kind:=usd_string(u.prims[prim].properties["info:id"])
    if kind=="UsdTransform2d" {
        scale:=usd_input(u,prim,"inputs:scale").numbers
        offset:=usd_input(u,prim,"inputs:translation").numbers
        if len(scale)==2 {mapping.scale={f32(scale[0]),f32(scale[1])}}
        if len(offset)==2 {mapping.offset={f32(offset[0]),f32(offset[1])}}
        mapping.rotation=math.to_radians(input_number(usd_input(u,prim,"inputs:rotation"),0))
        prim,attribute=usd_source(u,prim,"inputs:in")
        if prim<0 {importer.fail(r,.Malformed,"the input of a UsdTransform2d is invalid or cyclic");return}
        kind=usd_string(u.prims[prim].properties["info:id"])
    }
    if kind!="UsdPrimvarReader_float2" {
        importer.fail(r,.Unsupported,"USD supports one UsdTransform2d fed by a UsdPrimvarReader_float2 texture coordinate reader")
        return
    }
    reader,name:=usd_source(u,prim,"inputs:varname")
    if reader<0 {importer.fail(r,.Malformed,"a USD texture coordinate reader is invalid");return}
    variable:=usd_string(u.prims[reader].properties[name])
    switch variable {
    case "st","": mapping.uv_set=0
    case "st1": mapping.uv_set=1
    case: importer.fail(r,.Unsupported,"the USD texture coordinates %s are unsupported; use st or st1",variable)
    }
    return
}

// usdcat writes the absolute path of the images it can place and leaves the
// others as they were written, relative to the file that names them.
@(private="file")
usd_texture :: proc(u:^Usd_Import,file:string,srgb,normal_map:bool) -> int {
    if file=="" {return -1}
    return importer.image_file(u.r,importer.resolve_path(u.r,file),srgb,normal_map)
}

// A number read by a map from one channel of its image, which then holds the
// whole value: the factor becomes 1.
@(private="file")
usd_scalar_map :: proc(u:^Usd_Import,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,slot:asset.Material_Map_Kind,input:Usd_Input,channel:string,factor:^f32) {
    if input.file=="" {return}
    if input.channel!=channel {
        importer.warn(u.r,"a USD %v texture is read from its %s channel; the one connected (%s) is not imported",slot,channel,input.channel)
        return
    }
    images[slot]=usd_texture(u,input.file,false,false)
    if images[slot]<0 {return}
    importer.material_map(info,slot)^=input.mapping
    factor^=1
}

// The material of a Material prim, read from its UsdPreviewSurface; -1 for a
// material with another surface.
@(private="file")
usd_material :: proc(u:^Usd_Import,material:int) -> int {
    r:=u.r
    if material<0 {return -1}
    if row,found:=u.materials[material];found {return row}
    u.materials[material]=-1
    surface,_:=usd_source(u,material,"outputs:surface")
    if surface<0 || usd_string(u.prims[surface].properties["info:id"])!="UsdPreviewSurface" {return -1}
    info:=asset.MATERIAL_DEFAULTS
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    if input_number(usd_input(u,surface,"inputs:useSpecularWorkflow"),0)!=0 {
        importer.fail(r,.Unsupported,"the USD specular-color workflow is unsupported; export UsdPreviewSurface metallic-roughness")
        return -1
    }
    info.ior=input_number(usd_input(u,surface,"inputs:ior"),1.5)
    if !importer.ior_valid(info.ior) {
        importer.fail(r,.Malformed,"the USD index of refraction must be at least 1")
        return -1
    }
    // A texture multiplies its factor: a textured input leaves the factor at 1.
    diffuse:=usd_input(u,surface,"inputs:diffuseColor")
    color:=input_color(diffuse,{0.18,0.18,0.18})
    info.base_color={clamp(color.x,0,1),clamp(color.y,0,1),clamp(color.z,0,1)}
    if diffuse.channel=="rgb" {
        images[.Base_Color]=usd_texture(u,diffuse.file,true,false)
        importer.material_map(&info,.Base_Color)^=diffuse.mapping
    }
    if images[.Base_Color]>=0 {info.base_color={1,1,1}}
    emissive:=usd_input(u,surface,"inputs:emissiveColor")
    emission:=input_color(emissive,{0,0,0})
    info.emission={max(emission.x,0),max(emission.y,0),max(emission.z,0)}
    if emissive.channel=="rgb" {
        images[.Emission]=usd_texture(u,emissive.file,true,false)
        importer.material_map(&info,.Emission)^=emissive.mapping
    }
    if images[.Emission]>=0 {info.emission={1,1,1}}
    if normal:=usd_input(u,surface,"inputs:normal");normal.channel=="rgb" {
        images[.Normal]=usd_texture(u,normal.file,false,true)
        importer.material_map(&info,.Normal)^=normal.mapping
    }
    if occlusion:=usd_input(u,surface,"inputs:occlusion");occlusion.channel=="r" {
        images[.Occlusion]=usd_texture(u,occlusion.file,false,false)
        importer.material_map(&info,.Occlusion)^=occlusion.mapping
    }
    roughness,metallic:=usd_input(u,surface,"inputs:roughness"),usd_input(u,surface,"inputs:metallic")
    info.roughness=clamp(input_number(roughness,0.5),0,1)
    info.metallic=clamp(input_number(metallic,0),0,1)
    // Mirai reads both from one image, roughness in green and metallic in blue.
    rough_file:=roughness.file if roughness.channel=="g" else ""
    metal_file:=metallic.file if metallic.channel=="b" else ""
    if rough_file!="" && metal_file!="" && rough_file==metal_file && roughness.mapping!=metallic.mapping {
        importer.fail(r,.Unsupported,"USD packed metallic-roughness inputs must use the same texture mapping")
        return -1
    }
    if rough_file=="" || metal_file=="" || rough_file==metal_file {
        images[.Metallic_Roughness]=usd_texture(u,rough_file if rough_file!="" else metal_file,false,false)
        if images[.Metallic_Roughness]>=0 {
            importer.material_map(&info,.Metallic_Roughness)^=roughness.mapping if rough_file!="" else metallic.mapping
            if rough_file!="" {info.roughness=1}
            if metal_file!="" {info.metallic=1}
        }
    }
    opacity:=usd_input(u,surface,"inputs:opacity")
    info.opacity=clamp(input_number(opacity,1),0,1)
    // Opacity is textured only by the alpha of the base color image.
    alpha_map:=opacity.channel=="a" && opacity.file==diffuse.file && images[.Base_Color]>=0
    if alpha_map {info.opacity=1}
    if threshold:=input_number(usd_input(u,surface,"inputs:opacityThreshold"),0);threshold>0 {
        info.alpha_mode=.Mask
        info.alpha_cutoff=clamp(threshold,0,1)
    } else if info.opacity<1 || alpha_map {
        info.alpha_mode=.Blend
    }
    // A white coat; UsdPreviewSurface gives it the index of the surface.
    clearcoat,clearcoat_roughness:=usd_input(u,surface,"inputs:clearcoat"),usd_input(u,surface,"inputs:clearcoatRoughness")
    info.coat.weight=clamp(input_number(clearcoat,0),0,1)
    info.coat.roughness=clamp(input_number(clearcoat_roughness,0.01),0,1)
    if info.ior>=1 {info.coat.ior=info.ior}
    usd_scalar_map(u,&info,&images,.Coat,clearcoat,"r",&info.coat.weight)
    usd_scalar_map(u,&info,&images,.Coat_Roughness,clearcoat_roughness,"g",&info.coat.roughness)
    if importer.failed(r) {return -1}
    name:=u.prims[material].name
    // Materials under different prims may share a name: the second is named by its path.
    if r.material_names[name] {name=u.prims[material].path}
    row:=importer.material_add(r,name,len(r.materials),info,images)
    u.materials[material]=row
    return row
}

@(private="file")
usd_mesh :: proc(r:^importer.Reader,prim:Usd_Prim,material:int) -> (row:int,has_triangles,ok:bool) {
    points_property,has_points:=prim.properties["points"]
    counts_property,has_counts:=prim.properties["faceVertexCounts"]
    indices_property,has_indices:=prim.properties["faceVertexIndices"]
    if !has_points || !has_counts || !has_indices {return 0,false,importer.fail(r,.Malformed,"a mesh needs points, faceVertexCounts and faceVertexIndices")}
    points:=usd_vec3s(r,points_property) or_return
    counts:=usd_ints(r,counts_property) or_return
    indices:=usd_ints(r,indices_property) or_return
    total:=0
    for count in counts {
        if count<3 {return 0,false,importer.fail(r,.Malformed,"a mesh has a face with fewer than three vertices")}
        total+=count
    }
    if total!=len(indices) {return 0,false,importer.fail(r,.Malformed,"faceVertexCounts does not match the length of faceVertexIndices")}
    for index in indices {
        if index<0 || index>=len(points) {return 0,false,importer.fail(r,.Malformed,"a vertex index of the mesh is outside the points")}
    }
    if property,found:=prim.properties["subdivisionScheme"];found {
        if usd_string(property)!="none" {return 0,false,importer.fail(r,.Unsupported,"subdivision surfaces are unsupported; apply the subdivision and export subdivisionScheme = none")}
    } else {
        return 0,false,importer.fail(r,.Unsupported,"a USD mesh defaults to Catmull-Clark subdivision; export subdivisionScheme = none for polygon geometry")
    }
    holes:=make(map[int]bool,context.temp_allocator)
    if property,found:=prim.properties["holeIndices"];found {
        values:=usd_ints(r,property) or_return
        for v in values {
            if v<0 || v>=len(counts) {return 0,false,importer.fail(r,.Malformed,"holeIndices is outside the faces")}
            holes[v]=true
        }
    }
    reverse:=false
    if property,found:=prim.properties["orientation"];found {
        orientation:=usd_string(property)
        if orientation=="leftHanded" {reverse=true} else if orientation!="rightHanded" {return 0,false,importer.fail(r,.Malformed,"the orientation of the mesh is unknown")}
    }
    // displayColor stands in for the material of a mesh that has none.
    colors:[][3]f32
    color_interpolation:="constant"
    if property,found:=prim.properties["primvars:displayColor"];found && material<0 {
        values:=usd_vec3s(r,property) or_return
        colors,color_interpolation=usd_primvar(r,prim,"primvars:displayColor",values,"constant",len(counts),len(points),len(indices)) or_return
    }
    normals:[][3]f32
    normal_interpolation:="vertex"
    normal_name:="primvars:normals" if "primvars:normals" in prim.properties else "normals"
    if property,found:=prim.properties[normal_name];found {
        values:=usd_vec3s(r,property) or_return
        normals,normal_interpolation=usd_primvar(r,prim,normal_name,values,"vertex" if normal_name=="normals" else "constant",len(counts),len(points),len(indices)) or_return
    }
    uvs,uvs1:[][2]f32
    uv_interpolation,uv1_interpolation:="constant","constant"
    if property,found:=prim.properties["primvars:st"];found {
        values:=usd_vec2s(r,property) or_return
        uvs,uv_interpolation=usd_primvar(r,prim,"primvars:st",values,"constant",len(counts),len(points),len(indices)) or_return
    }
    if property,found:=prim.properties["primvars:st1"];found {
        values:=usd_vec2s(r,property) or_return
        uvs1,uv1_interpolation=usd_primvar(r,prim,"primvars:st1",values,"constant",len(counts),len(points),len(indices)) or_return
    }

    builder:importer.Mesh_Builder
    importer.builder_init(&builder,r)
    label:=r.materials[material].name if material>=0 else ""
    slot:=importer.builder_slot(&builder,1,label,material) or_return
    builder.has_uv1=len(uvs1)>0
    default_color:=[3]f32{1,1,1} if material>=0 else {0.8,0.8,0.8}
    polygon:=make([dynamic][3]f32,context.temp_allocator)
    triangles:=make([dynamic][3]int,context.temp_allocator)
    scratch:=make([dynamic][2]f32,context.temp_allocator)
    result:=make([dynamic]u32,context.temp_allocator)
    offset:=0
    for count,face in counts {
        if !holes[face] {
            clear(&polygon);clear(&triangles)
            for j in 0..<count {append(&polygon,points[indices[offset+j]])}
            if importer.polygon_triangulate(r,polygon[:],&triangles,&scratch,&result) {
                fallback:=importer.polygon_normal(polygon[:])
                for triangle in triangles {
                    order:=triangle
                    if reverse {order[0],order[2]=order[2],order[0]}
                    flat:=importer.face_normal(polygon[order[0]],polygon[order[1]],polygon[order[2]],fallback if !reverse else -fallback)
                    corners:[3]importer.Corner
                    for corner,k in order {
                        at:=offset+corner
                        point:=indices[at]
                        normal:=flat
                        if len(normals)>0 {normal=importer.normal_of(normals[usd_primvar_index(normal_interpolation,face,point,at)],flat)}
                        color:=default_color
                        if len(colors)>0 {color=colors[usd_primvar_index(color_interpolation,face,point,at)]}
                        corners[k]={position=polygon[corner],normal=normal,has_uv=len(uvs)>0,has_uv1=len(uvs1)>0,color=importer.pack_color({color.x,color.y,color.z,1})}
                        if len(uvs)>0 {corners[k].uv=uvs[usd_primvar_index(uv_interpolation,face,point,at)]}
                        if len(uvs1)>0 {corners[k].uv1=uvs1[usd_primvar_index(uv1_interpolation,face,point,at)]}
                    }
                    importer.builder_triangle(&builder,slot,corners)
                }
            } else {
                r.degenerate+=1
            }
        }
        offset+=count
    }
    if importer.builder_triangles(&builder)==0 {return 0,false,true}
    return importer.mesh_add(r,importer.builder_finish(&builder,prim.name)),true,true
}
