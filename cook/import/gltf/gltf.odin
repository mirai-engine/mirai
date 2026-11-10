package gltf

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import cg "vendor:cgltf"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import mm "mirai:std/math"

// glTF 2.0 and GLB through cgltf: scene hierarchy, instances, triangles,
// strips and fans, metallic-roughness materials with their extensions, lights
// and bind-space skinned meshes with their rig and animation clips. Its space
// is the engine's.

FORMAT :: importer.Format{
    name="glTF",
    extensions={0=".gltf",1=".glb"},
    version=2,
    space=importer.GLTF_SPACE,
    sniff=sniff,
    read=read,
}

// A GLB by its magic; a glTF by the asset object near the start of a JSON
// file, and any JSON object named .gltf, whose keys may come in any order.
sniff :: proc(head:[]u8) -> importer.Sniff {
    if len(head)>=4 && string(head[:4])=="glTF" {return .Content}
    head:=head
    if len(head)>=3 && head[0]==0xef && head[1]==0xbb && head[2]==0xbf {head=head[3:]}
    text:=strings.trim_left_space(string(head))
    if !strings.has_prefix(text,"{") {return .No}
    return .Content if strings.contains(text,`"asset"`) else .Extension
}

@(private="file")
Gltf :: struct {
    r:^importer.Reader,
    data:^cg.data,
    mesh_rows:map[^cg.mesh]int,
    visited:map[^cg.node]bool,
    materials:map[^cg.material]int,
    image_names:map[^cg.image]string,
    used_image_names:map[string]bool,
    paths:[]string,
    skin_rows:map[^cg.skin]int,
}

@(private="file")
Gltf_Rig :: struct {
    joints:[]asset.Rig_Joint,
    skeleton:int,
}

@(private="file")
Accessors :: struct {
    positions,normals,tangents,uvs,uvs1,colors,joints,weights,joints1,weights1:^cg.accessor,
}

read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {
    options:cg.options
    data,result:=cg.parse(options,raw_data(bytes),uint(len(bytes)))
    if result!=.success {return importer.fail(r,result==.unknown_format?importer.Error_Code.Unsupported:importer.Error_Code.Malformed,"glTF parse failed: %v",result)}
    defer cg.free(data)
    for buffer in data.buffers {
        if buffer.uri!=nil && !strings.has_prefix(string(buffer.uri),"data:") && importer.unsafe_path(string(buffer.uri)) {return importer.fail(r,.Malformed,"a glTF buffer names the device %s",string(buffer.uri))}
    }
    path:=strings.clone_to_cstring(r.path,context.temp_allocator)
    for buffer in data.buffers {
        if buffer.uri!=nil && !strings.has_prefix(string(buffer.uri),"data:") {importer.read_note(r,importer.resolve_path(r,string(buffer.uri)))}
    }
    if result=cg.load_buffers(options,data,path);result!=.success {
        return importer.fail(r,result==.file_not_found?importer.Error_Code.Read:importer.Error_Code.Malformed,"glTF buffers could not be loaded: %v",result)
    }
    if result=cg.validate(data);result!=.success {return importer.fail(r,.Malformed,"glTF validation failed: %v",result)}
    for extension in data.extensions_required {
        if string(extension)=="KHR_draco_mesh_compression" {
            return importer.fail(r,.Unsupported,"Draco-compressed glTF geometry is unsupported; export without Draco or with meshopt")
        }
    }
    // cgltf frees the data of a view, and these are scratch memory of the import.
    defer for &view in data.buffer_views {if view.has_meshopt_compression {view.data=nil}}
    if !meshopt_decode(r,data) {return false}
    g:=Gltf{r=r,data=data}
    g.mesh_rows.allocator=context.temp_allocator;g.visited.allocator=context.temp_allocator
    g.materials.allocator=context.temp_allocator
    g.image_names.allocator=context.temp_allocator;g.used_image_names.allocator=context.temp_allocator
    g.skin_rows.allocator=context.temp_allocator
    g.paths=make([]string,len(data.nodes),context.temp_allocator)
    if !gltf_paths(&g) {return false}
    selected:=data.scene
    if selected==nil && len(data.scenes)>0 {selected=&data.scenes[0]}
    if selected!=nil {
        for node in selected.nodes {if !gltf_node(&g,node,-1) {return false}}
    } else {
        for &node in data.nodes {if node.parent==nil && !gltf_node(&g,&node,-1) {return false}}
    }
    // A skin no mesh uses, as in a file of clips, still gives its skeleton.
    for &skin in data.skins {
        if &skin in g.skin_rows {continue}
        if _,_,ok:=gltf_skeleton(&g,&skin);!ok {return false}
    }
    if r.degenerate>0 {importer.warn(r,"%d triangles without area were skipped",r.degenerate)}
    return gltf_animations(&g)
}

@(private="file")
node_index :: proc(g:^Gltf,node:^cg.node) -> int {
    return int((uintptr(node)-uintptr(raw_data(g.data.nodes)))/size_of(cg.node))
}

@(private="file")
node_target :: proc(g:^Gltf,node:^cg.node) -> string {return g.paths[node_index(g,node)]}

@(private="file")
gltf_paths :: proc(g:^Gltf) -> bool {
    fill :: proc(g:^Gltf,node:^cg.node,depth:int) -> bool {
        if depth>importer.MAX_DEPTH {return importer.fail(g.r,.Limit,"a glTF node hierarchy is too deep or cyclic")}
        row:=node_index(g,node)
        if g.paths[row]!="" {return true}
        prefix:=""
        if node.parent!=nil {
            if !fill(g,node.parent,depth+1) {return false}
            prefix=fmt.tprintf("%s/",node_target(g,node.parent))
        }
        path:=fmt.tprintf("%s%s",prefix,importer.target_segment(node_label(node)))
        if len(path)>=asset.NODE_PATH_CAPACITY {return importer.fail(g.r,.Limit,"glTF node path %s exceeds %d bytes",path,asset.NODE_PATH_CAPACITY-1)}
        g.paths[row]=importer.own(g.r,path)
        return true
    }
    for &node in g.data.nodes {if !fill(g,&node,0) {return false}}
    // Clips and skins bind nodes by path: a path one of them names must be
    // one node's. Siblings that share a name and that nothing binds (the
    // instances of a scene named after what they place) are imported.
    shared:=make(map[string]int,len(g.paths),context.temp_allocator)
    for path in g.paths {shared[path]+=1}
    bound :: proc(g:^Gltf,shared:^map[string]int,node:^cg.node) -> bool {
        if node==nil || shared[node_target(g,node)]<2 {return true}
        return importer.fail(g.r,.Malformed,"glTF nodes share the path %s, which a clip or a skin binds; give siblings distinct names before export",node_target(g,node))
    }
    for &skin in g.data.skins {
        for joint in skin.joints {if !bound(g,&shared,joint) {return false}}
        if !bound(g,&shared,skin.skeleton) {return false}
    }
    for &animation in g.data.animations {
        for &channel in animation.channels {if !bound(g,&shared,channel.target_node) {return false}}
    }
    return true
}

@(private="file")
node_label :: proc(node:^cg.node) -> string {
    if node.name!=nil && string(node.name)!="" {return string(node.name)}
    if node.skin!=nil {return "Skeleton"}
    if node.mesh!=nil {return "Mesh"}
    return "Node"
}

// The local transform of a node, from its TRS or by decomposing its matrix.
@(private="file")
node_transform :: proc(r:^importer.Reader,node:^cg.node) -> (transform:mm.Transform,ok:bool) {
    transform=mm.TRANSFORM_IDENTITY
    if node.has_matrix {
        decomposed,valid:=mm.transform_from_matrix(transmute(mm.Mat4)node.matrix_)
        if !valid || !importer.transform_finite(decomposed) {
            return transform,importer.fail(r,.Unsupported,"glTF node %s: its matrix has shear, perspective or a scale of zero; apply it to the geometry before export",node_label(node))
        }
        return decomposed,true
    }
    if node.has_translation {transform.position=node.translation}
    if node.has_scale {transform.scale=node.scale}
    if node.has_rotation {
        q:=node.rotation
        length:=math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
        if !(length>1e-6) || length-length!=0 {return transform,importer.fail(r,.Malformed,"glTF node %s: its rotation has no length",node_label(node))}
        transform.rotation=quaternion(x=q[0]/length,y=q[1]/length,z=q[2]/length,w=q[3]/length)
    }
    if !importer.transform_finite(transform) {return transform,importer.fail(r,.Malformed,"glTF node %s: its transform has a number that is not finite",node_label(node))}
    for axis in transform.scale {
        if abs(axis)<1e-8 {return transform,importer.fail(r,.Unsupported,"glTF node %s: a scale of zero cannot be edited as a transform",node_label(node))}
    }
    return transform,true
}

@(private="file")
gltf_node :: proc(g:^Gltf,node:^cg.node,parent:int,depth:=0) -> bool {
    r:=g.r
    if depth>importer.MAX_DEPTH {return importer.fail(r,.Limit,"the glTF scene nests nodes deeper than %d levels",importer.MAX_DEPTH)}
    if g.visited[node] {return importer.fail(r,.Malformed,"the glTF scene has a cycle or repeats a node under several parents")}
    g.visited[node]=true
    if len(node.weights)>0 {
        targets:=len(node.mesh.primitives[0].targets) if node.mesh!=nil && len(node.mesh.primitives)>0 else 0
        if len(node.weights)!=targets {return importer.fail(r,.Malformed,"glTF node %s has %d morph weights for %d morph targets",node_label(node),len(node.weights),targets)}
        own:=0
        for weight,i in node.weights {
            if weight-weight!=0 {return importer.fail(r,.Malformed,"glTF node %s has a morph weight that is not finite",node_label(node))}
            if weight!=(node.mesh.weights[i] if i<len(node.mesh.weights) else 0) {own+=1}
        }
        if own>asset.MORPH_WEIGHTS {return importer.fail(r,.Limit,"glTF node %s sets %d morph weights apart from its mesh; an entity keeps %d: give the mesh those weights or animate them",node_label(node),own,asset.MORPH_WEIGHTS)}
    }
    if node.has_mesh_gpu_instancing {return importer.fail(r,.Unsupported,"glTF GPU instancing is unsupported; export ordinary scene nodes")}
    transform,ok:=node_transform(r,node)
    if !ok {return false}
    name:=string(node.name)
    if name=="" {name="Node"}
    row:=len(r.nodes)
    imported:=importer.Imported_Node{name=importer.own(r,name),path=node_target(g,node),target=base.name_hash(node_target(g,node)),parent=parent,transform=transform,mesh=-1,visible=true}
    if light:=node.light;light!=nil {
        kind:importer.Light_Kind
        #partial switch light.type {
        case .point: kind=.Point
        case .spot: kind=.Spot
        }
        imported.light=importer.Imported_Light{kind=kind,color=light.color,intensity=light.intensity,range=light.range,inner_cone=light.spot_inner_cone_angle,outer_cone=light.spot_outer_cone_angle}
    }
    append(&r.nodes,imported)
    if node.mesh!=nil {
        mesh_row,found:=g.mesh_rows[node.mesh]
        if !found || node.skin!=nil {
            built:bool
            mesh_row,built=gltf_mesh(g,node.mesh,node.skin,node)
            if !built {return false}
            if node.skin==nil {g.mesh_rows[node.mesh]=mesh_row}
        }
        r.nodes[row].mesh=mesh_row
        r.nodes[row].morph_weights=importer.own_slice(r,node.weights)
    } else if node.skin!=nil {
        if _,ok:=gltf_rig(g,node);!ok {return false}
    }
    for child in node.children {
        if !gltf_node(g,child,row,depth+1) {return false}
    }
    return true
}

// Where an image of the model is: bytes inside it (a buffer view of a GLB, or
// a base64 data URI), or a file next to it. ok false for an image with neither.
@(private="file")
gltf_image_source :: proc(g:^Gltf,image:^cg.image) -> (bytes:[]u8,path:string,ok:bool) {
    if bv:=image.buffer_view;bv!=nil {
        base:=bv.data
        if base==nil && bv.buffer!=nil && bv.buffer.data!=nil {base=rawptr(uintptr(bv.buffer.data)+uintptr(bv.offset))}
        if base==nil || bv.size==0 {return}
        return (cast([^]u8)base)[:bv.size],"",true
    }
    if image.uri==nil {return}
    uri:=string(image.uri)
    if strings.has_prefix(uri,"data:") {
        comma:=strings.index_byte(uri,',')
        if comma<0 || !strings.contains(uri[:comma],"base64") {return}
        decoded,error:=base64.decode(uri[comma+1:],allocator=context.temp_allocator)
        if error!=nil || len(decoded)==0 {return}
        return decoded,"",true
    }
    buffer:=make([]u8,len(uri)+1,context.temp_allocator)
    copy(buffer,uri)
    length:=cg.decode_uri(raw_data(buffer))
    return nil,importer.resolve_path(g.r,string(buffer[:length])),true
}

// The name an image of the model takes, unique among them.
@(private="file")
gltf_image_name :: proc(g:^Gltf,image:^cg.image) -> (name:string,index:int) {
    index=int((uintptr(image)-uintptr(raw_data(g.data.images)))/size_of(cg.image))
    named:bool
    name,named=g.image_names[image]
    if !named {
        label:=string(image.name) if image.name!=nil && string(image.name)!="" else fmt.tprintf("image %d",index)
        name=importer.unique_name(g.r,&g.used_image_names,label,index)
        g.image_names[image]=name
    }
    return
}

// The image a texture of the model shows: a file next to the model, or bytes inside it.
@(private="file")
gltf_texture :: proc(g:^Gltf,view:cg.texture_view,srgb,normal_map:bool) -> int {
    r:=g.r
    if view.texture==nil || view.texture.image_==nil {return -1}
    image:=view.texture.image_
    name,index:=gltf_image_name(g,image)
    bytes,path,found:=gltf_image_source(g,image)
    if !found {return -1}
    if path!="" {return importer.image_file(r,path,srgb,normal_map)}
    return importer.image_embedded(r,fmt.tprintf("%s#%d",r.path,index),name,bytes,srgb,normal_map)
}

// The pixels of the image a texture shows, decoded; ok false when it cannot be.
@(private="file")
gltf_pixels :: proc(g:^Gltf,view:cg.texture_view) -> (image:textures.Image,ok:bool) {
    if view.texture==nil || view.texture.image_==nil {return}
    bytes,path,found:=gltf_image_source(g,view.texture.image_)
    if !found {return}
    if path!="" {
        data,error:=os.read_entire_file_from_path(path,context.temp_allocator)
        if error!=nil {return}
        bytes=data
    }
    decoded,error:=textures.image_decode(bytes,context.temp_allocator)
    return decoded,error==.None
}

// The mapping of a texture binding: its transform and texcoord; no map borrows another's UVs.
@(private="file")
gltf_map_of :: proc(g:^Gltf,view:cg.texture_view) -> (map_:asset.Material_Map,ok:bool) {
    uv_set:=int(view.texcoord)
    map_=asset.MATERIAL_MAP_DEFAULT
    if view.has_transform {
        map_.scale=view.transform.scale
        map_.offset=view.transform.offset
        map_.rotation=view.transform.rotation
        if view.transform.has_texcoord {uv_set=int(view.transform.texcoord)}
    }
    if uv_set<0 || uv_set>1 {return map_,importer.fail(g.r,.Unsupported,"a glTF material uses a texture coordinate set other than TEXCOORD_0 and TEXCOORD_1")}
    map_.uv_set=u32(uv_set)
    return map_,true
}

@(private="file")
gltf_map :: proc(g:^Gltf,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,slot:asset.Material_Map_Kind,view:cg.texture_view,srgb,normal_map:bool) -> bool {
    if view.texture==nil {return true}
    importer.material_map(info,slot)^=gltf_map_of(g,view) or_return
    images[slot]=gltf_texture(g,view,srgb,normal_map)
    return true
}

@(private="file")
unit3 :: proc(v:[3]f32) -> [3]f32 {return {clamp(v[0],0,1),clamp(v[1],0,1),clamp(v[2],0,1)}}

// KHR_materials_clearcoat: a white coat of this index of refraction.
@(private="file")
GLTF_CLEARCOAT_IOR :: 1.5

@(private="file")
gltf_material :: proc(g:^Gltf,mat:^cg.material) -> (row:int,ok:bool) {
    r:=g.r
    if mat==nil {return -1,true}
    if known,found:=g.materials[mat];found {return known,true}
    index:=int((uintptr(mat)-uintptr(raw_data(g.data.materials)))/size_of(cg.material))
    name:=string(mat.name) if mat.name!=nil && string(mat.name)!="" else fmt.tprintf("material %d",index)
    info:=asset.MATERIAL_DEFAULTS
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    #partial switch mat.alpha_mode {
    case .mask:
        info.alpha_mode=.Mask
        info.alpha_cutoff=clamp(mat.alpha_cutoff,0,1)
    case .blend:
        info.alpha_mode=.Blend
    }
    // glTF gives emission no unit: its viewers show 1 as the white of the
    // display, so it is relative to the exposure.
    info.emission_mode=.Relative
    if mat.unlit {
        gltf_unlit(g,&info,&images,mat,name) or_return
    } else {
        gltf_lit(g,&info,&images,mat,name) or_return
    }
    unsupported:=[?]struct{present:b32,extension:string}{{mat.has_iridescence,"KHR_materials_iridescence"},{mat.has_dispersion,"KHR_materials_dispersion"}}
    for entry in unsupported {
        if entry.present {importer.warn(r,"glTF material %s uses %s, which is not imported",name,entry.extension)}
    }
    row=importer.material_add(r,name,index,info,images)
    g.materials[mat]=row
    return row,true
}

// KHR_materials_unlit shows the base color as it is: Mirai's unlit material
// emits it relative to the exposure, as glTF viewers show it, and keeps its opacity.
@(private="file")
gltf_unlit :: proc(g:^Gltf,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,mat:^cg.material,name:string) -> bool {
    info.unlit=true
    colored: for mesh in g.data.meshes {
        for primitive in mesh.primitives {
            if primitive.material!=mat {continue}
            for attribute in primitive.attributes {
                if attribute.type==.color {
                    importer.warn(g.r,"glTF material %s is unlit: the vertex colors of its primitives do not tint its emission",name)
                    break colored
                }
            }
        }
    }
    if !mat.has_pbr_metallic_roughness {return true}
    pbr:=mat.pbr_metallic_roughness
    info.base_color=unit3(pbr.base_color_factor.xyz)
    info.opacity=clamp(pbr.base_color_factor[3],0,1)
    info.emission=info.base_color
    gltf_map(g,info,images,.Base_Color,pbr.base_color_texture,true,false) or_return
    gltf_map(g,info,images,.Emission,pbr.base_color_texture,true,false) or_return
    return true
}

@(private="file")
gltf_lit :: proc(g:^Gltf,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,mat:^cg.material,name:string) -> bool {
    r:=g.r
    // Without a metallic-roughness block glTF means its defaults: a rough metal.
    info.metallic=1
    if mat.has_pbr_metallic_roughness {
        pbr:=mat.pbr_metallic_roughness
        info.base_color=unit3(pbr.base_color_factor.xyz)
        info.opacity=clamp(pbr.base_color_factor[3],0,1)
        info.metallic=clamp(pbr.metallic_factor,0,1)
        info.roughness=clamp(pbr.roughness_factor,0,1)
        gltf_map(g,info,images,.Base_Color,pbr.base_color_texture,true,false) or_return
        // An anisotropic lobe with textures takes its roughness from one converted with it.
        if !gltf_anisotropy_textured(mat) {gltf_map(g,info,images,.Metallic_Roughness,pbr.metallic_roughness_texture,false,false) or_return}
    } else if mat.has_pbr_specular_glossiness {
        sg:=mat.pbr_specular_glossiness
        textured:=sg.specular_glossiness_texture.texture!=nil
        importer.specular_glossiness(info,{diffuse=sg.diffuse_factor,specular=sg.specular_factor,glossiness=sg.glossiness_factor,textured=textured})
        gltf_map(g,info,images,.Base_Color,sg.diffuse_texture,true,false) or_return
        if textured {importer.warn(r,"glTF material %s: its specular-glossiness texture is not imported; it is a dielectric with its diffuse color",name)}
    }
    gltf_map(g,info,images,.Normal,mat.normal_texture,false,true) or_return
    if mat.normal_texture.texture!=nil {info.normal_scale=clamp(mat.normal_texture.scale,-16,16)}
    gltf_map(g,info,images,.Occlusion,mat.occlusion_texture,false,false) or_return
    if mat.occlusion_texture.texture!=nil {info.occlusion_strength=clamp(mat.occlusion_texture.scale,0,1)}
    info.emission={max(mat.emissive_factor[0],0),max(mat.emissive_factor[1],0),max(mat.emissive_factor[2],0)}
    if mat.has_emissive_strength {info.emission*=max(mat.emissive_strength.emissive_strength,0)}
    gltf_map(g,info,images,.Emission,mat.emissive_texture,true,false) or_return
    if mat.has_specular {
        info.specular_factor=clamp(mat.specular.specular_factor,0,1)
        info.specular_color=unit3(mat.specular.specular_color_factor)
        gltf_map(g,info,images,.Specular,mat.specular.specular_texture,false,false) or_return
        gltf_map(g,info,images,.Specular_Color,mat.specular.specular_color_texture,true,false) or_return
    }
    if mat.has_transmission {info.transmission=clamp(mat.transmission.transmission_factor,0,1)}
    if mat.has_ior {
        info.ior=mat.ior.ior
        if !importer.ior_valid(info.ior) {return importer.fail(r,.Malformed,"glTF material %s: the index of refraction must be 0 or at least 1",name)}
    }
    if mat.has_volume {
        info.thickness=max(mat.volume.thickness_factor,0)
        info.attenuation_color=unit3(mat.volume.attenuation_color)
        // glTF leaves the distance out for a solid that absorbs nothing.
        if mat.volume.attenuation_distance>0 && mat.volume.attenuation_distance<1e6 {info.attenuation_distance=mat.volume.attenuation_distance}
    }
    if mat.has_clearcoat && mat.clearcoat.clearcoat_factor>0 {
        coat:=mat.clearcoat
        info.coat.weight=clamp(coat.clearcoat_factor,0,1)
        info.coat.roughness=clamp(coat.clearcoat_roughness_factor,0,1)
        info.coat.ior=GLTF_CLEARCOAT_IOR
        gltf_map(g,info,images,.Coat,coat.clearcoat_texture,false,false) or_return
        gltf_map(g,info,images,.Coat_Roughness,coat.clearcoat_roughness_texture,false,false) or_return
        gltf_map(g,info,images,.Coat_Normal,coat.clearcoat_normal_texture,false,true) or_return
        if coat.clearcoat_normal_texture.texture!=nil {info.coat.normal_scale=clamp(coat.clearcoat_normal_texture.scale,-16,16)}
    }
    if mat.has_sheen {
        // The sheen of color c lies over the base as c·f + (1 - max(c)·E)·base:
        // the fuzz of weight max(c) and color c/max(c).
        sheen:=mat.sheen
        color:=unit3(sheen.sheen_color_factor)
        weight:=max(color[0],color[1],color[2])
        if weight>0 {
            info.fuzz.weight=weight
            info.fuzz.color=color/weight
            info.fuzz.roughness=clamp(sheen.sheen_roughness_factor,0,1)
            gltf_map(g,info,images,.Fuzz_Color,sheen.sheen_color_texture,true,false) or_return
            gltf_map(g,info,images,.Fuzz_Roughness,sheen.sheen_roughness_texture,false,false) or_return
            if sheen.sheen_color_texture.texture!=nil {
                importer.warn(r,"glTF material %s: KHR_materials_sheen darkens the base by the brightest channel of its color factor, not of its color texture",name)
            }
        }
    }
    if mat.has_diffuse_transmission {
        transmission:=&mat.diffuse_transmission
        info.diffuse_transmission.weight=clamp(transmission.diffuse_transmission_factor,0,1)
        info.diffuse_transmission.color=unit3(transmission.diffuse_transmission_color_factor)
        if info.diffuse_transmission.weight>0 {
            gltf_map(g,info,images,.Diffuse_Transmission,transmission.diffuse_transmission_texture,false,false) or_return
            gltf_map(g,info,images,.Diffuse_Transmission_Color,transmission.diffuse_transmission_color_texture,true,false) or_return
        }
    }
    if mat.has_anisotropy && mat.anisotropy.anisotropy_strength>0 {
        anisotropy:=mat.anisotropy
        info.anisotropy.rotation=anisotropy.anisotropy_rotation
        textured:=gltf_anisotropy_textured(mat)
        baked:=false
        if textured {baked=gltf_anisotropy_bake(g,info,images,mat) or_return}
        if !baked {
            if mat.has_pbr_metallic_roughness {gltf_map(g,info,images,.Metallic_Roughness,mat.pbr_metallic_roughness.metallic_roughness_texture,false,false) or_return}
            info.roughness,info.anisotropy.amount=gltf_anisotropy(info.roughness,clamp(anisotropy.anisotropy_strength,0,1))
            gltf_map(g,info,images,.Anisotropy,anisotropy.anisotropy_texture,false,false) or_return
        }
        if textured && !baked {
            importer.warn(r,"glTF material %s: its roughness and anisotropy textures differ in texture coordinates or cannot be read; KHR_materials_anisotropy is converted exactly for its factors and the textures scale the result",name)
        }
    }
    return true
}

// Whether a texture varies the roughness or the anisotropy of an anisotropic lobe.
@(private="file")
gltf_anisotropy_textured :: proc(mat:^cg.material) -> bool {
    if !mat.has_anisotropy || mat.anisotropy.anisotropy_strength<=0 {return false}
    return mat.anisotropy.anisotropy_texture.texture!=nil || bool(mat.has_pbr_metallic_roughness) && mat.pbr_metallic_roughness.metallic_roughness_texture.texture!=nil
}

// The roughness and the anisotropy of an anisotropic lobe with textures,
// converted texel by texel (gltf_anisotropy) into a metallic-roughness and an
// anisotropy image of the larger size: the alphas match where the factors do
// not. False when the two textures differ in texture coordinates or one
// cannot be decoded.
@(private="file")
gltf_anisotropy_bake :: proc(g:^Gltf,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,mat:^cg.material) -> (baked,ok:bool) {
    views:=[2]cg.texture_view{{},mat.anisotropy.anisotropy_texture}
    if mat.has_pbr_metallic_roughness {views[0]=mat.pbr_metallic_roughness.metallic_roughness_texture}
    sources:[2]textures.Image
    mappings:[2]asset.Material_Map
    present:[2]bool
    width,height:=0,0
    for view,i in views {
        if view.texture==nil {continue}
        mappings[i]=gltf_map_of(g,view) or_return
        decoded,read:=gltf_pixels(g,view)
        if !read {return false,true}
        sources[i],present[i]=decoded,true
        width,height=max(width,decoded.width),max(height,decoded.height)
    }
    if present[0] && present[1] && mappings[0]!=mappings[1] {return false,true}
    texel :: proc(image:textures.Image,x,y,width,height:int) -> [4]u8 {
        sx,sy:=min(x*image.width/width,image.width-1),min(y*image.height/height,image.height-1)
        at:=(sy*image.width+sx)*4
        return {image.pixels[at],image.pixels[at+1],image.pixels[at+2],image.pixels[at+3]}
    }
    // Without its texture glTF means a direction along the tangent and a strength of one.
    ALONG_TANGENT :: [4]u8{255,128,255,255}
    strength:=clamp(mat.anisotropy.anisotropy_strength,0,1)
    rough:=make([]u8,width*height*4,context.temp_allocator)
    turned:=make([]u8,width*height*4,context.temp_allocator)
    for y in 0..<height {
        for x in 0..<width {
            at:=(y*width+x)*4
            mr:=texel(sources[0],x,y,width,height) if present[0] else [4]u8{255,255,255,255}
            along:=texel(sources[1],x,y,width,height) if present[1] else ALONG_TANGENT
            r,a:=gltf_anisotropy(info.roughness*f32(mr[1])/255,strength*f32(along[2])/255)
            rough[at],rough[at+1],rough[at+2],rough[at+3]=mr[0],u8(math.round(r*255)),mr[2],mr[3]
            turned[at],turned[at+1],turned[at+2],turned[at+3]=along[0],along[1],u8(math.round(a*255)),255
        }
    }
    index:=int((uintptr(mat)-uintptr(raw_data(g.data.materials)))/size_of(cg.material))
    label:=string(mat.name) if mat.name!=nil && string(mat.name)!="" else fmt.tprintf("material %d",index)
    key:=fmt.tprintf("%s#anisotropy%d",g.r.path,index)
    mapping:=mappings[0] if present[0] else mappings[1]
    images[.Metallic_Roughness]=importer.image_pixels(g.r,fmt.tprintf("%s roughness",key),fmt.tprintf("%s roughness",label),textures.rgba8(rough,width,height),false,false)
    images[.Anisotropy]=importer.image_pixels(g.r,key,fmt.tprintf("%s anisotropy",label),textures.rgba8(turned,width,height),false,false)
    importer.material_map(info,.Metallic_Roughness)^=mapping
    importer.material_map(info,.Anisotropy)^=mapping
    info.roughness,info.anisotropy.amount=1,1
    return true,true
}

// The OpenPBR roughness and anisotropy of the lobe KHR_materials_anisotropy
// makes from a roughness and a strength: the same alphas along the tangent,
// mix(r², 1, s²), and along the bitangent, r².
@(private="file")
gltf_anisotropy :: proc(roughness,strength:f32) -> (openpbr_roughness,anisotropy:f32) {
    along_bitangent:=roughness*roughness
    along_tangent:=math.lerp(along_bitangent,1,strength*strength)
    if along_tangent<=0 {return roughness,0}
    anisotropy=1-along_bitangent/along_tangent
    openpbr_roughness=math.pow((along_tangent*along_tangent+along_bitangent*along_bitangent)*0.5,0.25)
    return
}

@(private="file")
floats :: proc(m:^mm.Mat4) -> [^]f32 {return cast([^]f32)m}

@(private="file")
joint_matrix_finite :: proc(m:mm.Mat4) -> bool {
    for column in 0..<4 {
        for row in 0..<4 {
            v:=m[row,column]
            if v-v!=0 {return false}
        }
    }
    return true
}

// The skeleton of a skin: its joints and their ancestors, a parent before
// its children. rows gives the bone of each node of the file, -1 for none.
@(private="file")
gltf_skeleton :: proc(g:^Gltf,skin:^cg.skin) -> (skeleton:int,rows:[]int,ok:bool) {
    r:=g.r
    if len(skin.joints)==0 {return 0,nil,importer.fail(r,.Malformed,"the glTF skin has no joints")}
    if len(skin.joints)>1<<16 {return 0,nil,importer.fail(r,.Limit,"the glTF skin has more than 65536 joints")}
    needed:=make([]bool,len(g.data.nodes),context.temp_allocator)
    mark :: proc(g:^Gltf,node:^cg.node,needed:[]bool) {
        node:=node
        for node!=nil {
            index:=node_index(g,node)
            if needed[index] {break}
            needed[index]=true
            node=node.parent
        }
    }
    for joint in skin.joints {mark(g,joint,needed)}
    rows=make([]int,len(g.data.nodes),context.temp_allocator)
    for &row in rows {row=-1}
    nodes:=make([dynamic]asset.Skeleton_Bone,context.temp_allocator)
    // A parent comes before its children whatever the order of the file.
    emit :: proc(g:^Gltf,node:^cg.node,needed:[]bool,rows:[]int,nodes:^[dynamic]asset.Skeleton_Bone,depth:=0) -> bool {
        if depth>importer.MAX_DEPTH {return importer.fail(g.r,.Limit,"a glTF skeleton nests nodes deeper than %d levels",importer.MAX_DEPTH)}
        transform,ok:=node_transform(g.r,node)
        if !ok {return false}
        row:=asset.Skeleton_Bone{parent=-1,target=base.name_hash(node_target(g,node)),translation=transform.position,rotation=transform.rotation,scale=transform.scale}
        asset.text_set(row.name[:],node_label(node))
        asset.text_set(row.path[:],node_target(g,node))
        if node.parent!=nil {row.parent=i32(rows[node_index(g,node.parent)])}
        rows[node_index(g,node)]=len(nodes)
        append(nodes,row)
        for child in node.children {
            if needed[node_index(g,child)] && !emit(g,child,needed,rows,nodes,depth+1) {return false}
        }
        return true
    }
    for &node,index in g.data.nodes {
        if needed[index] && (node.parent==nil || !needed[node_index(g,node.parent)]) && !emit(g,&node,needed,rows,&nodes) {return 0,nil,false}
    }
    found:bool
    if skeleton,found=g.skin_rows[skin];!found {
        name:=string(skin.name)
        if name=="" {name=fmt.tprintf("%s skeleton",node_target(g,skin.joints[0]))}
        for existing in r.skeletons {if existing.name==name {return 0,nil,importer.fail(r,.Malformed,"glTF skins share the name %s; give skins distinct names before export",name)}}
        skeleton=len(r.skeletons)
        append(&r.skeletons,importer.Imported_Skeleton{name=importer.own(r,name),bones=importer.own_slice(r,nodes[:])})
        g.skin_rows[skin]=skeleton
    }
    return skeleton,rows,true
}

@(private="file")
gltf_rig :: proc(g:^Gltf,mesh_node:^cg.node) -> (pose:Gltf_Rig,ok:bool) {
    r:=g.r
    skin:=mesh_node.skin
    skeleton,rows:=gltf_skeleton(g,skin) or_return
    mesh_world:mm.Mat4
    cg.node_transform_world(mesh_node,floats(&mesh_world))
    if !joint_matrix_finite(mesh_world) || abs(linalg.determinant(mesh_world))<1e-12 {return {},importer.fail(r,.Malformed,"the transform of a skinned mesh node is singular")}
    ibm:=skin.inverse_bind_matrices
    if ibm!=nil && (ibm.type!=.mat4 || int(ibm.count)!=len(skin.joints)) {return {},importer.fail(r,.Malformed,"the inverse-bind matrices of a glTF skin must match its joint count")}
    pose.skeleton=skeleton
    joints:=make([]asset.Rig_Joint,len(skin.joints),r.out)
    for joint,i in skin.joints {
        inverse_bind:mm.Mat4=1
        if ibm!=nil && !cg.accessor_read_float(ibm,uint(i),floats(&inverse_bind),16) {return {},importer.fail(r,.Malformed,"the inverse-bind matrices of a glTF skin cannot be decoded")}
        if !joint_matrix_finite(inverse_bind) {return {},importer.fail(r,.Malformed,"an inverse-bind matrix is not finite")}
        if abs(inverse_bind[3,0])+abs(inverse_bind[3,1])+abs(inverse_bind[3,2])+abs(inverse_bind[3,3]-1)>1e-5 {return {},importer.fail(r,.Unsupported,"an inverse-bind matrix must be affine")}
        if abs(linalg.determinant(inverse_bind))<1e-12 {return {},importer.fail(r,.Malformed,"an inverse-bind matrix is singular")}
        joint_world:mm.Mat4
        cg.node_transform_world(joint,floats(&joint_world))
        if !joint_matrix_finite(joint_world) {return {},importer.fail(r,.Malformed,"the transform of a joint is not finite")}
        joints[i]={node=u32(rows[node_index(g,joint)]),inverse_bind=inverse_bind}
    }
    pose.joints=joints
    return pose,true
}

@(private="file")
gltf_mesh :: proc(g:^Gltf,mesh:^cg.mesh,skin:^cg.skin,node:^cg.node) -> (row:int,ok:bool) {
    r:=g.r
    pose:Gltf_Rig
    if skin!=nil {pose=gltf_rig(g,node) or_return}
    builder:importer.Mesh_Builder
    importer.builder_init(&builder,r,skin!=nil)
    name:=string(mesh.name)
    if name=="" {name=string(node.name)}
    if name=="" {name=fmt.tprintf("mesh %d",int((uintptr(mesh)-uintptr(raw_data(g.data.meshes)))/size_of(cg.mesh)))}
    // The morph vertices are those of the primitives one after another.
    targets:=len(mesh.primitives[0].targets) if len(mesh.primitives)>0 else 0
    if targets>asset.MESH_MAX_MORPHS {return 0,importer.fail(r,.Limit,"glTF mesh %s has %d morph targets; the engine keeps up to %d",name,targets,asset.MESH_MAX_MORPHS)}
    if len(mesh.weights)!=0 && len(mesh.weights)!=targets {return 0,importer.fail(r,.Malformed,"glTF mesh %s has %d morph weights for %d morph targets",name,len(mesh.weights),targets)}
    morph_first:=make([]u32,len(mesh.primitives)+1,context.temp_allocator)
    for primitive,primitive_index in mesh.primitives {
        if len(primitive.targets)!=targets {return 0,importer.fail(r,.Malformed,"the primitives of glTF mesh %s have different numbers of morph targets",name)}
        positions:uint
        for attribute in primitive.attributes {if attribute.type==.position {positions=attribute.data.count}}
        morph_first[primitive_index+1]=morph_first[primitive_index]+u32(positions if targets>0 else 0)
    }
    for primitive,primitive_index in mesh.primitives {
        a:Accessors
        for attribute in primitive.attributes {
            switch {
            case attribute.type==.position: a.positions=attribute.data
            case attribute.type==.normal: a.normals=attribute.data
            case attribute.type==.tangent: a.tangents=attribute.data
            case attribute.type==.texcoord && attribute.index==0: a.uvs=attribute.data
            case attribute.type==.texcoord && attribute.index==1: a.uvs1=attribute.data
            case attribute.type==.color && attribute.index==0: a.colors=attribute.data
            case attribute.type==.joints && attribute.index==0: a.joints=attribute.data
            case attribute.type==.weights && attribute.index==0: a.weights=attribute.data
            case attribute.type==.joints && attribute.index==1: a.joints1=attribute.data
            case attribute.type==.weights && attribute.index==1: a.weights1=attribute.data
            case skin!=nil && (attribute.type==.joints || attribute.type==.weights) && attribute.index>1:
                return 0,importer.fail(r,.Unsupported,"more than eight glTF skin influences per vertex are unsupported")
            }
        }
        if a.positions==nil {return 0,importer.fail(r,.Malformed,"a glTF primitive is missing POSITION")}
        if skin!=nil && (a.joints==nil || a.weights==nil || a.joints.type!=.vec4 || a.weights.type!=.vec4 || a.joints.count!=a.positions.count || a.weights.count!=a.positions.count) {
            return 0,importer.fail(r,.Malformed,"a skinned primitive needs JOINTS_0 and WEIGHTS_0 accessors of four components, as many as POSITION")
        }
        if skin!=nil && (a.joints1!=nil || a.weights1!=nil) && (a.joints1==nil || a.weights1==nil || a.joints1.type!=.vec4 || a.weights1.type!=.vec4 || a.joints1.count!=a.positions.count || a.weights1.count!=a.positions.count) {
            return 0,importer.fail(r,.Malformed,"JOINTS_1 and WEIGHTS_1 must both have four components per vertex")
        }
        if primitive.has_draco_mesh_compression {return 0,importer.fail(r,.Unsupported,"Draco glTF geometry is unsupported")}
        if primitive.type!=.triangles && primitive.type!=.triangle_strip && primitive.type!=.triangle_fan {
            return 0,importer.fail(r,.Unsupported,"glTF points and lines are unsupported; export triangle meshes")
        }
        material_row:=gltf_material(g,primitive.material) or_return
        if material_row>=0 {
            images:=r.materials[material_row].images
            for image,slot in images {
                if image<0 {continue}
                uv_set:=importer.material_map(&r.materials[material_row].info,slot).uv_set
                if uv_set==0 && a.uvs==nil {return 0,importer.fail(r,.Malformed,"a glTF material uses TEXCOORD_0 but its primitive has none")}
                if uv_set==1 && a.uvs1==nil {return 0,importer.fail(r,.Malformed,"a glTF material uses TEXCOORD_1 but its primitive has none")}
            }
        }
        label:=string(primitive.material.name) if primitive.material!=nil && primitive.material.name!=nil else ""
        slot:=importer.builder_slot(&builder,u32(primitive_index+1),label,material_row) or_return
        gltf_primitive(g,&builder,primitive,a,slot,&pose,morph_first[primitive_index] if targets>0 else max(u32)) or_return
    }
    imported:=importer.builder_finish(&builder,name)
    if targets>0 && !gltf_morphs(g,mesh,&builder,&imported,name,morph_first) {return 0,false}
    if skin!=nil {
        imported.joints=pose.joints
        imported.skeleton=pose.skeleton
    }
    return importer.mesh_add(r,imported),true
}

// The morph targets of a mesh, read primitive by primitive into its morph
// vertices: a target without an attribute moves nothing of it.
@(private="file")
gltf_morphs :: proc(g:^Gltf,mesh:^cg.mesh,builder:^importer.Mesh_Builder,imported:^importer.Imported_Mesh,name:string,first:[]u32) -> bool {
    r:=g.r
    count:=int(first[len(first)-1])
    positions:=make([][3]f32,count,context.temp_allocator)
    normals:=make([][3]f32,count,context.temp_allocator)
    tangents:=make([][3]f32,count,context.temp_allocator)
    ignored:=false
    for t in 0..<len(mesh.primitives[0].targets) {
        shape:=importer.Morph_Shape{name=gltf_morph_name(mesh,t),positions=positions}
        if len(mesh.weights)>0 {shape.weight=mesh.weights[t]}
        for &value in positions {value={}}
        has_normals,has_tangents:=false,false
        for primitive,p in mesh.primitives {
            vertices:=int(first[p+1]-first[p])
            base_normals,base_tangents:=false,false
            for attribute in primitive.attributes {base_normals ||= attribute.type==.normal;base_tangents ||= attribute.type==.tangent}
            for attribute in primitive.targets[t].attributes {
                out:[][3]f32
                #partial switch attribute.type {
                case .position: out=positions[first[p]:][:vertices]
                case .normal:
                    if !base_normals {return importer.fail(r,.Malformed,"glTF mesh %s: morph target %s moves normals its primitive does not have",name,shape.name)}
                    if !has_normals {for &value in normals {value={}};has_normals=true}
                    out=normals[first[p]:][:vertices]
                case .tangent:
                    if !base_tangents || !base_normals {continue}
                    if !has_tangents {for &value in tangents {value={}};has_tangents=true}
                    out=tangents[first[p]:][:vertices]
                case:
                    ignored=true
                    continue
                }
                accessor:=attribute.data
                if accessor==nil || accessor.type!=.vec3 || accessor.count!=uint(vertices) {return importer.fail(r,.Malformed,"glTF mesh %s: morph target %s has an accessor that is not VEC3 or not one per vertex",name,shape.name)}
                if cg.accessor_unpack_floats(accessor,cast([^]f32)raw_data(out),accessor.count*3)!=accessor.count*3 {return importer.fail(r,.Malformed,"glTF mesh %s: morph target %s cannot be decoded",name,shape.name)}
            }
        }
        if has_normals {shape.normals=normals}
        if has_tangents {shape.tangents=tangents}
        if !importer.builder_morph(builder,imported,shape) {return false}
    }
    if ignored {importer.warn(r,"glTF mesh %s: morph targets move texture coordinates or colors, which the engine does not morph",name)}
    return true
}

@(private="file")
gltf_morph_name :: proc(mesh:^cg.mesh,index:int) -> string {
    if index<len(mesh.target_names) && mesh.target_names[index]!=nil && string(mesh.target_names[index])!="" {return string(mesh.target_names[index])}
    return fmt.tprintf("Morph %d",index+1)
}

// morph_first: the morph vertex of its first vertex, max(u32) when its mesh does not morph.
@(private="file")
gltf_primitive :: proc(g:^Gltf,builder:^importer.Mesh_Builder,primitive:cg.primitive,a:Accessors,slot:int,pose:^Gltf_Rig,morph_first:u32) -> bool {
    r:=g.r
    count:=int(a.positions.count)
    skinned:=a.joints!=nil && len(pose.joints)>0
    if a.uvs1!=nil {builder.has_uv1=true}
    index_count:=count
    if primitive.indices!=nil {index_count=int(primitive.indices.count)}
    if primitive.type==.triangles && index_count%3!=0 {return importer.fail(r,.Malformed,"a glTF triangle index count is not a multiple of three")}
    triangle_count:=index_count-2
    if primitive.type==.triangles {triangle_count=index_count/3}
    if triangle_count<=0 {return true}

    positions:=make([][3]f32,count,context.temp_allocator)
    normals:=make([][3]f32,count if a.normals!=nil else 0,context.temp_allocator)
    // The tangents of the file are kept only with its normals: MikkTSpace makes them from both.
    has_tangents:=a.tangents!=nil && a.normals!=nil
    tangents:=make([][4]f32,count if has_tangents else 0,context.temp_allocator)
    uvs:=make([][2]f32,count if a.uvs!=nil else 0,context.temp_allocator)
    uvs1:=make([][2]f32,count if a.uvs1!=nil else 0,context.temp_allocator)
    colors:=make([]u32,count if a.colors!=nil else 0,context.temp_allocator)
    skins:=make([]asset.Skin_Vertex,count if skinned else 0,context.temp_allocator)
    values:[4]f32
    for i in 0..<count {
        if !cg.accessor_read_float(a.positions,uint(i),raw_data(&values),3) {return importer.fail(r,.Malformed,"the glTF POSITION accessor cannot be decoded")}
        positions[i]={values[0],values[1],values[2]}
        if !importer.finite3(positions[i]) {return importer.fail(r,.Malformed,"the glTF POSITION accessor has a number that is not finite")}
        if a.normals!=nil {
            if uint(i)>=a.normals.count || !cg.accessor_read_float(a.normals,uint(i),raw_data(&values),3) {return importer.fail(r,.Malformed,"the glTF NORMAL accessor cannot be decoded")}
            normals[i]={values[0],values[1],values[2]}
            if !importer.finite3(normals[i]) {return importer.fail(r,.Malformed,"the glTF NORMAL accessor has a number that is not finite")}
        }
        if has_tangents {
            if uint(i)>=a.tangents.count || a.tangents.type!=.vec4 || !cg.accessor_read_float(a.tangents,uint(i),raw_data(&values),4) {return importer.fail(r,.Malformed,"the glTF TANGENT accessor cannot be decoded: it needs four components per vertex")}
            tangents[i]=values
            if !importer.finite3(values.xyz) || values.w-values.w!=0 {return importer.fail(r,.Malformed,"the glTF TANGENT accessor has a number that is not finite")}
        }
        if a.uvs!=nil {
            if uint(i)>=a.uvs.count || !cg.accessor_read_float(a.uvs,uint(i),raw_data(&values),2) {return importer.fail(r,.Malformed,"the glTF TEXCOORD_0 accessor cannot be decoded")}
            uvs[i]={values[0],values[1]}
        }
        if a.uvs1!=nil {
            if uint(i)>=a.uvs1.count || !cg.accessor_read_float(a.uvs1,uint(i),raw_data(&values),2) {return importer.fail(r,.Malformed,"the glTF TEXCOORD_1 accessor cannot be decoded")}
            uvs1[i]={values[0],values[1]}
        }
        if a.colors!=nil {
            components:uint=4 if a.colors.type==.vec4 else 3
            values={0,0,0,1}
            if uint(i)>=a.colors.count || !cg.accessor_read_float(a.colors,uint(i),raw_data(&values),components) {return importer.fail(r,.Malformed,"the glTF COLOR_0 accessor cannot be decoded")}
            colors[i]=importer.pack_color(values)
        }
        if skinned {
            influence:=&skins[i]
            joints:[8]u32
            weights:[8]f32
            if !cg.accessor_read_uint(a.joints,uint(i),raw_data(&joints),4) || !cg.accessor_read_float(a.weights,uint(i),raw_data(&weights),4) {
                return importer.fail(r,.Malformed,"the glTF joint and weight accessors cannot be decoded")
            }
            if a.joints1!=nil && (!cg.accessor_read_uint(a.joints1,uint(i),&joints[4],4) || !cg.accessor_read_float(a.weights1,uint(i),&weights[4],4)) {
                return importer.fail(r,.Malformed,"the secondary glTF joint and weight accessors cannot be decoded")
            }
            total:f32
            for weight,at in weights {
                if weight-weight!=0 || weight<0 {return importer.fail(r,.Malformed,"a glTF skin weight is negative or not finite")}
                // glTF only recommends 0 for the joint of an unused influence.
                if weight==0 {continue}
                if int(joints[at])>=len(pose.joints) {return importer.fail(r,.Malformed,"a glTF skin joint index is outside the skin")}
                total+=weight
            }
            if !(total>1e-8) || total-total!=0 {return importer.fail(r,.Malformed,"a glTF skin vertex has no positive influence weight")}
            influence.weights=asset.skin_weights_quantize(weights)
            for weight,at in influence.weights {
                if weight>0 {influence.joints[at]=u16(joints[at])}
            }
        }
    }
    for i in 0..<triangle_count {
        at:[3]int
        #partial switch primitive.type {
        case .triangles: at={i*3,i*3+1,i*3+2}
        case .triangle_strip:
            at={i,i+1,i+2}
            if i%2==1 {at[0],at[1]=at[1],at[0]}
        case .triangle_fan: at={0,i+1,i+2}
        }
        source:[3]int
        for k in 0..<3 {
            source[k]=at[k]
            if primitive.indices!=nil {source[k]=int(cg.accessor_read_index(primitive.indices,uint(at[k])))}
            if source[k]>=count {return importer.fail(r,.Malformed,"a glTF index is outside POSITION")}
        }
        if linalg.length(linalg.cross(positions[source[1]]-positions[source[0]],positions[source[2]]-positions[source[0]]))<1e-9 {
            r.degenerate+=1
            continue
        }
        flat:=importer.face_normal(positions[source[0]],positions[source[1]],positions[source[2]],{0,0,1})
        corners:[3]importer.Corner
        corner_skin:[3]asset.Skin_Vertex
        for k in 0..<3 {
            s:=source[k]
            normal:=flat
            if a.normals!=nil {normal=importer.normal_of(normals[s],flat)}
            corners[k]={position=positions[s],normal=normal,has_uv=a.uvs!=nil,has_uv1=a.uvs1!=nil,color=importer.WHITE,flat=a.normals==nil}
            if morph_first!=max(u32) {corners[k].morph=morph_first+u32(s)+1}
            if a.uvs!=nil {corners[k].uv=uvs[s]}
            if a.uvs1!=nil {corners[k].uv1=uvs1[s]}
            if a.colors!=nil {corners[k].color=colors[s]}
            if has_tangents {corners[k].tangent,corners[k].has_tangent=tangents[s],true}
            if skinned {corner_skin[k]=skins[s]}
        }
        importer.builder_triangle(builder,slot,corners,corner_skin)
    }
    return true
}

@(private="file")
gltf_animations :: proc(g:^Gltf) -> bool {
    r:=g.r
    if len(g.data.animations)>asset.ANIMATION_MAX_CLIPS {return importer.fail(r,.Limit,"too many glTF animation clips")}
    names:=make(map[string]bool,context.temp_allocator)
    total_tracks,total_keys,total_markers:=0,0,0
    for animation,clip_index in g.data.animations {
        name:=string(animation.name)
        if name=="" {name=fmt.tprintf("Animation %d",clip_index)}
        name=importer.unique_name(r,&names,name,clip_index)
        if len(name)>=asset.ANIMATION_NAME_CAPACITY {return importer.fail(r,.Limit,"glTF animation name %s is too long",name)}
        tracks:=make([dynamic]asset.Animation_Track_Desc,0,len(animation.channels),r.out)
        seen:=make(map[struct {node:^cg.node,path:cg.animation_path_type}]bool,context.temp_allocator)
        for channel in animation.channels {
            if channel.target_node==nil || channel.sampler==nil {return importer.fail(r,.Malformed,"glTF animation %s has a channel without a target or sampler",name)}
            key:=struct {node:^cg.node,path:cg.animation_path_type}{channel.target_node,channel.target_path}
            if seen[key] {return importer.fail(r,.Malformed,"glTF animation %s repeats a channel for one node property",name)}
            seen[key]=true
            if channel.target_path==.weights {
                if !gltf_weight_tracks(g,name,channel,&tracks,&total_keys) {return false}
                continue
            }
            if channel.target_node.has_matrix {return importer.fail(r,.Malformed,"glTF animation %s targets a matrix node; animated nodes require TRS",name)}
            property:anim.Property
            components:uint=3
            #partial switch channel.target_path {
            case .translation: property=.Position
            case .rotation: property=.Rotation;components=4
            case .scale: property=.Scale
            case: return importer.fail(r,.Unsupported,"glTF animation %s has an unsupported target path",name)
            }
            sampler:=channel.sampler
            input,output:=sampler.input,sampler.output
            if input==nil || output==nil || input.type!=.scalar || input.component_type!=.r_32f || input.count==0 {
                return importer.fail(r,.Malformed,"glTF animation %s requires nonempty scalar float times",name)
            }
            expected:=cg.type.vec3 if components==3 else cg.type.vec4
            // Rotations may be normalized integers, as meshopt's quaternion filter writes them.
            quantized:=property==.Rotation && output.normalized && (output.component_type==.r_8 || output.component_type==.r_8u || output.component_type==.r_16 || output.component_type==.r_16u)
            if output.type!=expected || output.component_type!=.r_32f && !quantized {return importer.fail(r,.Malformed,"glTF animation %s has output components inconsistent with its target",name)}
            interpolation:anim.Interpolation
            multiplier:uint=1
            #partial switch sampler.interpolation {
            case .linear: interpolation=.Linear
            case .step: interpolation=.Step
            case .cubic_spline: interpolation=.Cubic_Spline;multiplier=3
            case: return importer.fail(r,.Unsupported,"glTF animation %s has an unsupported interpolation",name)
            }
            if input.count>uint(asset.ANIMATION_MAX_KEYS-total_keys) {return importer.fail(r,.Limit,"too many glTF animation keys")}
            if output.count!=input.count*multiplier {return importer.fail(r,.Malformed,"glTF animation %s has inconsistent key counts",name)}
            total_keys+=int(input.count)
            keys:=make([]anim.Keyframe,int(input.count),r.out)
            for &frame,k in keys {
                frame.interpolation=interpolation
                if !cg.accessor_read_float(input,uint(k),&frame.time,1) || frame.time-frame.time!=0 || frame.time<0 || k>0 && frame.time<=keys[k-1].time {
                    return importer.fail(r,.Malformed,"glTF animation %s times must be finite, nonnegative and strictly increasing",name)
                }
                first:=uint(k)*multiplier
                if multiplier==3 {
                    frame.tangents=true
                    if !cg.accessor_read_float(output,first,raw_data(&frame.in_slope),components) || !cg.accessor_read_float(output,first+2,raw_data(&frame.out_slope),components) {
                        return importer.fail(r,.Malformed,"glTF animation %s tangents cannot be decoded",name)
                    }
                    first+=1
                }
                if !cg.accessor_read_float(output,first,raw_data(&frame.value),components) {return importer.fail(r,.Malformed,"glTF animation %s values cannot be decoded",name)}
                for component in 0..<4 {
                    a,b,d:=frame.value[component],frame.in_slope[component],frame.out_slope[component]
                    if a-a!=0 || b-b!=0 || d-d!=0 {return importer.fail(r,.Malformed,"glTF animation %s has a non-finite value or tangent",name)}
                }
                if property==.Rotation {
                    length:=linalg.length(frame.value)
                    if !(length>1e-8) {return importer.fail(r,.Malformed,"glTF animation %s has a zero quaternion",name)}
                    frame.value/=length
                }
            }
            append(&tracks,asset.Animation_Track_Desc{target=importer.own(r,node_target(g,channel.target_node)),property=property,keys=keys})
        }
        total_tracks+=len(tracks)
        if total_tracks>asset.ANIMATION_MAX_TRACKS {return importer.fail(r,.Limit,"too many glTF animation tracks")}
        markers,read:=gltf_markers(g,name,animation.extras,&total_markers)
        if !read {return false}
        append(&r.animations,asset.Animation_Clip_Desc{name=name,tracks=tracks[:],markers=markers})
    }
    return true
}

// The morph weights a channel animates: a Float track of each target of the
// mesh of its node, named "<node>/@morph/<target>".
@(private="file")
gltf_weight_tracks :: proc(g:^Gltf,clip:string,channel:cg.animation_channel,tracks:^[dynamic]asset.Animation_Track_Desc,total_keys:^int) -> bool {
    r:=g.r
    node:=channel.target_node
    mesh:=node.mesh
    if mesh==nil || len(mesh.primitives)==0 || len(mesh.primitives[0].targets)==0 {return importer.fail(r,.Malformed,"glTF animation %s animates the morph weights of node %s, which has no morph targets",clip,node_label(node))}
    count:=len(mesh.primitives[0].targets)
    input,output:=channel.sampler.input,channel.sampler.output
    if input==nil || output==nil || input.type!=.scalar || output.type!=.scalar || input.component_type!=.r_32f || input.count==0 {return importer.fail(r,.Malformed,"glTF animation %s needs scalar float times and weights for node %s",clip,node_label(node))}
    interpolation:anim.Interpolation
    multiplier:uint=1
    #partial switch channel.sampler.interpolation {
    case .linear: interpolation=.Linear
    case .step: interpolation=.Step
    case .cubic_spline: interpolation=.Cubic_Spline;multiplier=3
    case: return importer.fail(r,.Unsupported,"glTF animation %s has an unsupported interpolation",clip)
    }
    if input.count*uint(count)>uint(asset.ANIMATION_MAX_KEYS-total_keys^) {return importer.fail(r,.Limit,"too many glTF animation keys")}
    if output.count!=input.count*multiplier*uint(count) {return importer.fail(r,.Malformed,"glTF animation %s has %d weights for %d times and %d morph targets",clip,output.count,input.count,count)}
    total_keys^+=int(input.count)*count
    times:=make([]f32,int(input.count),context.temp_allocator)
    values:=make([]f32,int(output.count),context.temp_allocator)
    if cg.accessor_unpack_floats(input,raw_data(times),input.count)!=input.count || cg.accessor_unpack_floats(output,raw_data(values),output.count)!=output.count {return importer.fail(r,.Malformed,"glTF animation %s weights cannot be decoded",clip)}
    for time,k in times {
        if time-time!=0 || time<0 || k>0 && time<=times[k-1] {return importer.fail(r,.Malformed,"glTF animation %s times must be finite, nonnegative and strictly increasing",clip)}
    }
    for value in values {if value-value!=0 {return importer.fail(r,.Malformed,"glTF animation %s has a morph weight or tangent that is not finite",clip)}}
    for t in 0..<count {
        target:=fmt.tprintf("%s%s%s",node_target(g,node),asset.ANIMATION_MORPH_PATH,gltf_morph_name(mesh,t))
        if len(target)>=asset.NODE_PATH_CAPACITY {return importer.fail(r,.Limit,"the morph track %s is longer than %d bytes",target,asset.NODE_PATH_CAPACITY-1)}
        keys:=make([]anim.Keyframe,int(input.count),r.out)
        for &frame,k in keys {
            frame.interpolation,frame.time=interpolation,times[k]
            // A key holds the weights of all targets; a cubic one, in-tangents, values and out-tangents.
            at:=uint(k)*multiplier*uint(count)+uint(t)
            if multiplier==3 {
                frame.tangents=true
                frame.in_slope.x,frame.out_slope.x=values[at],values[at+2*uint(count)]
                at+=uint(count)
            }
            frame.value.x=values[at]
        }
        append(tracks,asset.Animation_Track_Desc{target=importer.own(r,target),property=.Float,keys=keys})
    }
    return true
}

// The markers of a clip, from the extras of its glTF animation: {"markers": [{"name": "foot_l",
// "time": 0.27}]}, as a source writes the events of its timeline (notifies, footsteps). They are
// sorted by time; without the key there are none.
@(private="file")
gltf_markers :: proc(g:^Gltf,clip:string,extras:cg.extras_t,total:^int) -> (markers:[]asset.Animation_Marker_Desc,ok:bool) {
    r:=g.r
    if extras.data==nil {return nil,true}
    text:=string(cstring(extras.data))
    if !strings.contains(text,`"markers"`) {return nil,true}
    Extras :: struct {markers:[]struct {name:string,time:f32}}
    value:Extras
    if json.unmarshal_string(text,&value,allocator=context.temp_allocator)!=nil {
        return nil,importer.fail(r,.Malformed,"glTF animation %s has extras whose markers are not a list of {name, time}",clip)
    }
    if len(value.markers)>asset.ANIMATION_MAX_MARKERS-total^ {return nil,importer.fail(r,.Limit,"too many glTF animation markers")}
    total^+=len(value.markers)
    out:=make([]asset.Animation_Marker_Desc,len(value.markers),r.out)
    for m,i in value.markers {
        if m.time-m.time!=0 || m.time<0 {return nil,importer.fail(r,.Malformed,"glTF animation %s has a marker %s at a time that is not finite and nonnegative",clip,m.name)}
        if m.name=="" || len(m.name)>=asset.ANIMATION_NAME_CAPACITY {return nil,importer.fail(r,.Malformed,"glTF animation %s has a marker without a name or with one of %d bytes or more",clip,asset.ANIMATION_NAME_CAPACITY)}
        out[i]={m.time,importer.own(r,m.name)}
    }
    for i in 1..<len(out) {
        for j:=i;j>0 && out[j].time<out[j-1].time;j-=1 {out[j],out[j-1]=out[j-1],out[j]}
    }
    return out,true
}
