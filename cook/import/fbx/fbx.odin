package fbx

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import mm "mirai:std/math"
import ufbx "mirai:third_party/ufbx"

// FBX 7 (2010 and later), binary and ASCII, through ufbx: the node hierarchy
// with its pivots, meshes with their geometry transform, materials, skinned
// meshes with their rig, blend shapes and the clip of each animation stack.
// Each file states its units and axes; ufbx converts neither, the import does.

FORMAT :: importer.Format{
    name="FBX",
    extensions={0=".fbx"},
    version=1,
    space={meters_per_unit=0.01,axes=importer.FACING_PLUS_Z,v_origin=.Bottom}, // what FBX means when a file does not say
    sniff=sniff,
    read=read,
}

// The FBX 6 of earlier exporters are refused: ufbx reads them, the importer does not promise to.
MIN_VERSION :: 7000

BINARY_MAGIC :: "Kaydara FBX Binary  \x00"

// A binary FBX by its magic; an ASCII one by its header near the start.
sniff :: proc(head:[]u8) -> importer.Sniff {
    if len(head)>=len(BINARY_MAGIC) && string(head[:len(BINARY_MAGIC)])==BINARY_MAGIC {return .Content}
    if strings.contains(string(head),"FBXHeaderExtension") {return .Content}
    return .Extension
}

@(private="file")
Fbx :: struct {
    r:^importer.Reader,
    scene:^ufbx.Scene,
    labels:[]string,       // by typed id of node: its name in the model
    paths:[]string,        // by typed id of node: the path of names from the root, "" for the root
    rows:[]int,            // by typed id of node: its row of nodes, -1 for the root
    skeletons:[]int,       // by typed id of node: the skeleton of the bones under it, -1 for none
    bone_rows:[]int,       // by typed id of node: its bone in its skeleton, -1 for none
    meshes:[dynamic]Built_Mesh,
    materials:map[^ufbx.Material]int,
    lights,curves,cameras:int,
    unweighted,influences:int,
}

// A mesh as one node shows it: nodes that share it with the same materials
// and geometry transform share its row.
@(private="file")
Built_Mesh :: struct {
    mesh:^ufbx.Mesh,
    materials:[]^ufbx.Material,
    geometry:ufbx.Matrix,
    row:int,
}

read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {
    opts:=ufbx.Load_Opts{
        filename=r.path,
        file_format=.FBX,
        no_format_from_extension=true,
        index_error_handling=.ABORT_LOADING,
        node_depth_limit=importer.MAX_DEPTH,
        geometry_transform_handling=.PRESERVE,
        inherit_mode_handling=.PRESERVE,
        pivot_handling=.RETAIN,
        use_blender_pbr_material=true,
    }
    error:ufbx.Error
    scene:=ufbx.load_memory(raw_data(bytes),uint(len(bytes)),&opts,&error)
    if scene==nil {return fbx_fail(r,&error)}
    defer ufbx.free_scene(scene)
    if scene.metadata.version<MIN_VERSION {
        return importer.fail(r,.Unsupported,"FBX %d.%d is older than FBX 7; export it again as FBX 2011 or later",scene.metadata.version/1000,scene.metadata.version%1000/100)
    }
    fbx_space(r,scene) or_return
    f:=Fbx{r=r,scene=scene}
    f.meshes.allocator=context.temp_allocator
    f.materials.allocator=context.temp_allocator
    count:=len(scene.nodes)
    f.labels=make([]string,count,context.temp_allocator)
    f.paths=make([]string,count,context.temp_allocator)
    f.rows=make([]int,count,context.temp_allocator)
    f.skeletons=make([]int,count,context.temp_allocator)
    f.bone_rows=make([]int,count,context.temp_allocator)
    for i in 0..<count {f.rows[i],f.skeletons[i],f.bone_rows[i]=-1,-1,-1}
    fbx_paths(&f) or_return
    fbx_skeletons(&f) or_return
    for child in scene.root_node.children {fbx_node(&f,child,-1) or_return}
    if r.degenerate>0 {importer.warn(r,"%d faces without area were skipped",r.degenerate)}
    if f.lights>0 {importer.warn(r,"%d FBX lights are empty nodes: FBX gives light no physical unit",f.lights)}
    if f.cameras>0 {importer.warn(r,"%d FBX cameras are empty nodes",f.cameras)}
    if f.curves>0 {importer.warn(r,"%d FBX curves are empty nodes: curves are not drawn",f.curves)}
    if f.influences>0 {importer.warn(r,"%d skinned vertices had more than eight influences and keep the eight largest",f.influences)}
    if f.unweighted>0 {importer.warn(r,"%d skinned vertices had no influence and follow the first joint of their skin",f.unweighted)}
    return fbx_animations(&f)
}

@(private="file")
fbx_fail :: proc(r:^importer.Reader,error:^ufbx.Error) -> bool {
    code:importer.Error_Code
    #partial switch error.type {
    case .OUT_OF_MEMORY,.MEMORY_LIMIT,.ALLOCATION_LIMIT,.NODE_DEPTH_LIMIT: code=.Limit
    case .UNRECOGNIZED_FILE_FORMAT,.UNSUPPORTED_VERSION,.FEATURE_DISABLED: code=.Unsupported
    case: code=.Malformed
    }
    info:=string(error.info[:min(int(error.info_length),len(error.info))])
    if info!="" {return importer.fail(r,code,"FBX could not be read: %s (%s)",error.description,info)}
    return importer.fail(r,code,"FBX could not be read: %s",error.description)
}

// The units and axes the file states; those FBX means by default where it does not.
@(private="file")
fbx_space :: proc(r:^importer.Reader,scene:^ufbx.Scene) -> bool {
    AXES :: [ufbx.Coordinate_Axis]importer.Axis{.POSITIVE_X=.X,.NEGATIVE_X=.Negative_X,.POSITIVE_Y=.Y,.NEGATIVE_Y=.Negative_Y,.POSITIVE_Z=.Z,.NEGATIVE_Z=.Negative_Z,.UNKNOWN=.X}
    space:=FORMAT.space
    settings:=scene.settings
    if settings.unit_meters>0 && settings.unit_meters-settings.unit_meters==0 {space.meters_per_unit=f32(settings.unit_meters)}
    axes:=[3]ufbx.Coordinate_Axis{settings.axes.right,settings.axes.up,settings.axes.front}
    known:=true
    for axis in axes {known&&=axis>=.POSITIVE_X && axis<.UNKNOWN}
    if known {
        table:=AXES
        for axis,i in axes {space.axes[i]=table[axis]}
        // What FBX calls front looks at who sees the model: the engine's -Z, and its right turns with it.
        space.axes[0],space.axes[2]=importer.axis_opposite(space.axes[0]),importer.axis_opposite(space.axes[2])
    }
    return importer.source_space(r,space)
}

@(private="file")
node_label :: #force_inline proc(f:^Fbx,node:^ufbx.Node) -> string {return f.labels[node.typed_id]}

// The name of a node without its namespace: Maya and Mixamo write "ns:name",
// and the name alone is what a bone is called.
@(private="file")
plain_label :: proc(node:^ufbx.Node) -> string {
    name:=node.name
    if colon:=strings.last_index_byte(name,':');colon>=0 {name=name[colon+1:]}
    if name!="" {return name}
    if node.mesh!=nil {return "Mesh"}
    if node.bone!=nil {return "Skeleton"}
    return "Node"
}

// The name and the path of every node: the names from the root, escaped,
// unique. A name keeps its namespace where its sibling has the same without.
@(private="file")
fbx_paths :: proc(f:^Fbx) -> bool {
    used:=make(map[string]bool,context.temp_allocator)
    fill :: proc(f:^Fbx,node:^ufbx.Node,prefix:string,used:^map[string]bool) -> bool {
        for child in node.children {
            label:=plain_label(child)
            path:=fmt.tprintf("%s%s",prefix,importer.target_segment(label))
            if used[path] && child.name!=label {
                label=child.name
                path=fmt.tprintf("%s%s",prefix,importer.target_segment(label))
            }
            if len(path)>=asset.NODE_PATH_CAPACITY {return importer.fail(f.r,.Limit,"FBX node path %s exceeds %d bytes",path,asset.NODE_PATH_CAPACITY-1)}
            if used[path] {return importer.fail(f.r,.Malformed,"FBX nodes share the path %s; give siblings distinct names before export",path)}
            used[path]=true
            f.labels[child.typed_id]=label
            f.paths[child.typed_id]=importer.own(f.r,path)
            fill(f,child,fmt.tprintf("%s/",path),used) or_return
        }
        return true
    }
    return fill(f,f.scene.root_node,"",&used)
}

// The node under the root that holds this one.
@(private="file")
top_of :: proc(node:^ufbx.Node) -> ^ufbx.Node {
    node:=node
    for node.parent!=nil && !node.parent.is_root {node=node.parent}
    return node
}

// The skeletons of the skins: one for the bones under each node of the root,
// with the ancestors they need, so that the skins of one character share it.
@(private="file")
fbx_skeletons :: proc(f:^Fbx) -> bool {
    r:=f.r
    needed:=make([]bool,len(f.scene.nodes),context.temp_allocator)
    tops:=make([dynamic]^ufbx.Node,context.temp_allocator)
    for skin in f.scene.skin_deformers {
        top:^ufbx.Node
        for cluster in skin.clusters {
            if cluster.bone_node==nil {continue}
            bone_top:=top_of(cluster.bone_node)
            if top==nil {top=bone_top}
            if bone_top!=top {return importer.fail(r,.Unsupported,"FBX skin %s has bones under %s and under %s; put the skeleton of a skin under one node",skin.name,node_label(f,top),node_label(f,bone_top))}
            for node:=cluster.bone_node;node!=nil && !node.is_root;node=node.parent {needed[node.typed_id]=true}
        }
        if top!=nil && !slice.contains(tops[:],top) {append(&tops,top)}
    }
    emit :: proc(f:^Fbx,node:^ufbx.Node,parent:i32,skeleton:int,needed:[]bool,bones:^[dynamic]asset.Skeleton_Bone) -> bool {
        transform:=node_transform(f,node) or_return
        row:=asset.Skeleton_Bone{parent=parent,target=base.name_hash(f.paths[node.typed_id]),translation=transform.position,rotation=transform.rotation,scale=transform.scale}
        asset.text_set(row.name[:],node_label(f,node))
        asset.text_set(row.path[:],f.paths[node.typed_id])
        f.skeletons[node.typed_id]=skeleton
        f.bone_rows[node.typed_id]=len(bones)
        append(bones,row)
        at:=i32(len(bones)-1)
        for child in node.children {
            if needed[child.typed_id] {emit(f,child,at,skeleton,needed,bones) or_return}
        }
        return true
    }
    for top in tops {
        bones:=make([dynamic]asset.Skeleton_Bone,context.temp_allocator)
        emit(f,top,-1,len(r.skeletons),needed,&bones) or_return
        append(&r.skeletons,importer.Imported_Skeleton{name=importer.own(r,node_label(f,top)),bones=importer.own_slice(r,bones[:])})
    }
    return true
}

@(private="file")
node_transform :: proc(f:^Fbx,node:^ufbx.Node) -> (transform:mm.Transform,ok:bool) {
    r:=f.r
    t:=node.local_transform
    transform={position=vec3(t.translation),rotation=quat(t.rotation),scale=vec3(t.scale)}
    if !importer.transform_finite(transform) {return transform,importer.fail(r,.Malformed,"FBX node %s: its transform has a number that is not finite",node_label(f,node))}
    for axis in transform.scale {
        if abs(axis)<1e-8 {return transform,importer.fail(r,.Unsupported,"FBX node %s: a scale of zero cannot be edited as a transform",node_label(f,node))}
    }
    if ignores_parent_scale(node) {transform.scale/=vec3(node.parent.local_transform.scale)}
    return transform,true
}

// A node that does not inherit the scale of its parent: Maya's segment scale
// compensate, the Rrs of MotionBuilder. The engine multiplies scales axis by
// axis and moves a child by the scale of its parent, as FBX does here, so its
// scale is its own over the parent's. RrSs is the engine's own composition.
@(private="file")
ignores_parent_scale :: #force_inline proc(node:^ufbx.Node) -> bool {
    return node.inherit_mode==.IGNORE_PARENT_SCALE && node.parent!=nil && !node.parent.is_root
}

@(private="file")
vec2 :: #force_inline proc(v:ufbx.Vec2) -> [2]f32 {return {f32(v.x),f32(v.y)}}
@(private="file")
vec3 :: #force_inline proc(v:ufbx.Vec3) -> [3]f32 {return {f32(v.x),f32(v.y),f32(v.z)}}
@(private="file")
vec4 :: #force_inline proc(v:ufbx.Vec4) -> [4]f32 {return {f32(v.x),f32(v.y),f32(v.z),f32(v.w)}}
@(private="file")
quat :: #force_inline proc(q:ufbx.Quat) -> quaternion128 {return quaternion(x=f32(q.x),y=f32(q.y),z=f32(q.z),w=f32(q.w))}

@(private="file")
mat4 :: proc(m:ufbx.Matrix) -> (out:mm.Mat4) {
    for column in 0..<4 {
        for row in 0..<3 {out[row,column]=f32(m.cols[column].v[row])}
    }
    out[3,3]=1
    return
}

@(private="file")
fbx_node :: proc(f:^Fbx,node:^ufbx.Node,parent:int) -> bool {
    r:=f.r
    #partial switch node.attrib_type {
    case .NURBS_SURFACE,.NURBS_TRIM_SURFACE,.PROCEDURAL_GEOMETRY:
        return importer.fail(r,.Unsupported,"FBX node %s is a NURBS or procedural surface; convert it to polygons before export",node_label(f,node))
    case .LIGHT: f.lights+=1
    case .CAMERA,.STEREO_CAMERA: f.cameras+=1
    case .LINE_CURVE,.NURBS_CURVE: f.curves+=1
    }
    transform:=node_transform(f,node) or_return
    path:=f.paths[node.typed_id]
    row:=len(r.nodes)
    f.rows[node.typed_id]=row
    append(&r.nodes,importer.Imported_Node{name=importer.own(r,node_label(f,node)),path=path,target=base.name_hash(path),parent=parent,transform=transform,mesh=-1,visible=node.visible})
    if node.mesh!=nil {
        mesh_row:=fbx_mesh(f,node,node.mesh) or_return
        r.nodes[row].mesh=mesh_row
    }
    for child in node.children {fbx_node(f,child,row) or_return}
    return true
}

// The material of slot index of a mesh as this node shows it: FBX gives each instance its materials.
@(private="file")
slot_material :: proc(node:^ufbx.Node,mesh:^ufbx.Mesh,index:int) -> ^ufbx.Material {
    if index<len(node.materials) {return node.materials[index]}
    if index<len(mesh.materials) {return mesh.materials[index]}
    return nil
}

@(private="file")
fbx_mesh :: proc(f:^Fbx,node:^ufbx.Node,mesh:^ufbx.Mesh) -> (row:int,ok:bool) {
    r:=f.r
    skinned:=len(mesh.skin_deformers)>0
    if len(mesh.skin_deformers)>1 {return 0,importer.fail(r,.Unsupported,"FBX mesh %s has %d skins; the engine binds a mesh to one",mesh.name,len(mesh.skin_deformers))}
    // A skin binds the geometry as it is: geometry_to_bone starts where the geometry transform does.
    geometry:=node.geometry_to_node if node.has_geometry_transform && !skinned else ufbx.Matrix{}
    if !skinned {
        for built in f.meshes {
            if built.mesh==mesh && slice.equal(built.materials,node.materials) && built.geometry.v==geometry.v {return built.row,true}
        }
    }
    name:=mesh.name
    if name=="" {name=node_label(f,node)}
    builder:importer.Mesh_Builder
    importer.builder_init(&builder,r,skinned)
    joints:[]asset.Rig_Joint
    skeleton:=-1
    skins:[]asset.Skin_Vertex
    if skinned {joints,skeleton,skins=fbx_skin(f,mesh,name) or_return}
    channels:=make([dynamic]^ufbx.Blend_Channel,context.temp_allocator)
    for deformer in mesh.blend_deformers {append(&channels,..deformer.channels[:])}
    if len(channels)>asset.MESH_MAX_MORPHS {return 0,importer.fail(r,.Limit,"FBX mesh %s has %d blend shapes; the engine keeps up to %d",name,len(channels),asset.MESH_MAX_MORPHS)}
    fbx_faces(f,&builder,node,mesh,geometry,skins,len(channels)>0) or_return
    imported:=importer.builder_finish(&builder,name)
    if len(channels)>0 {fbx_morphs(f,&builder,&imported,mesh,channels[:],geometry,name) or_return}
    if skinned {imported.joints,imported.skeleton=joints,skeleton}
    row=importer.mesh_add(r,imported)
    if !skinned {append(&f.meshes,Built_Mesh{mesh=mesh,materials=node.materials,geometry=geometry,row=row})}
    return row,true
}

// The rig of a skinned mesh and the influences of each of its vertices, the
// eight largest of each normalized when it has more.
@(private="file")
fbx_skin :: proc(f:^Fbx,mesh:^ufbx.Mesh,name:string) -> (joints:[]asset.Rig_Joint,skeleton:int,skins:[]asset.Skin_Vertex,ok:bool) {
    r:=f.r
    skin:=mesh.skin_deformers[0]
    if len(skin.clusters)==0 {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s has a skin without bones",name)}
    if len(skin.clusters)>1<<16 {return nil,-1,nil,importer.fail(r,.Limit,"FBX mesh %s has a skin of more than 65536 bones",name)}
    joints=make([]asset.Rig_Joint,len(skin.clusters),r.out)
    skeleton=-1
    for cluster,i in skin.clusters {
        bone:=cluster.bone_node
        if bone==nil || f.skeletons[bone.typed_id]<0 {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s has a skin bone that is not in the scene",name)}
        skeleton=f.skeletons[bone.typed_id]
        inverse_bind:=mat4(cluster.geometry_to_bone)
        for column in 0..<4 {
            for row in 0..<4 {
                v:=inverse_bind[row,column]
                if v-v!=0 {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: the bind matrix of bone %s is not finite",name,node_label(f,bone))}
            }
        }
        if abs(linalg.determinant(inverse_bind))<1e-12 {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: the bind matrix of bone %s is singular",name,node_label(f,bone))}
        joints[i]={node=u32(f.bone_rows[bone.typed_id]),inverse_bind=inverse_bind}
    }
    if len(skin.vertices)!=int(mesh.num_vertices) {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: its skin does not cover its vertices",name)}
    skins=make([]asset.Skin_Vertex,len(skin.vertices),context.temp_allocator)
    for vertex,v in skin.vertices {
        if int(vertex.weight_begin)+int(vertex.num_weights)>len(skin.weights) {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: a skin vertex has weights outside its skin",name)}
        influences:=skin.weights[vertex.weight_begin:][:vertex.num_weights]
        kept:[8]ufbx.Skin_Weight
        count:=0
        for weight in influences {
            if weight.weight-weight.weight!=0 || weight.weight<0 {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: a skin weight is negative or not finite",name)}
            if weight.weight==0 {continue}
            if int(weight.cluster_index)>=len(joints) {return nil,-1,nil,importer.fail(r,.Malformed,"FBX mesh %s: a skin weight names a bone outside its skin",name)}
            // The smallest of the kept is replaced: the eight largest stay, in the order of the file.
            if count<len(kept) {kept[count]=weight;count+=1;continue}
            smallest:=0
            for k in 1..<len(kept) {if kept[k].weight<kept[smallest].weight {smallest=k}}
            if weight.weight>kept[smallest].weight {copy(kept[smallest:],kept[smallest+1:]);kept[len(kept)-1]=weight}
        }
        if count==len(kept) && int(vertex.num_weights)>len(kept) {f.influences+=1}
        if count==0 {
            f.unweighted+=1
            skins[v].weights[0]=255
            continue
        }
        weights:[8]f32
        for k in 0..<count {weights[k]=f32(kept[k].weight)}
        skins[v].weights=asset.skin_weights_quantize(weights)
        for k in 0..<count {
            if skins[v].weights[k]>0 {skins[v].joints[k]=u16(kept[k].cluster_index)}
        }
    }
    return joints,skeleton,skins,true
}

// The faces of a mesh as triangles of its slots: one slot per material index,
// whose id is the index plus one.
@(private="file")
fbx_faces :: proc(f:^Fbx,builder:^importer.Mesh_Builder,node:^ufbx.Node,mesh:^ufbx.Mesh,geometry:ufbx.Matrix,skins:[]asset.Skin_Vertex,morphs:bool) -> bool {
    r:=f.r
    transformed:=geometry.v!={}
    to_node,normal_to_node:mm.Mat4
    turned:=false
    if transformed {
        to_node=mat4(geometry)
        linear:=linalg.matrix3_from_matrix4(to_node)
        if abs(linalg.determinant(linear))<1e-12 {return importer.fail(r,.Unsupported,"FBX node %s has a geometry transform with a scale of zero",node_label(f,node))}
        normal_to_node=linalg.matrix4_from_matrix3(linalg.transpose(linalg.inverse(linear)))
        turned=linalg.determinant(linear)<0
    }
    position:=mesh.vertex_position
    normal:=mesh.vertex_normal
    uv0:=mesh.uv_sets[0].vertex_uv if len(mesh.uv_sets)>0 else ufbx.Vertex_Vec2{}
    uv1:=mesh.uv_sets[1].vertex_uv if len(mesh.uv_sets)>1 else ufbx.Vertex_Vec2{}
    if len(mesh.uv_sets)>2 {importer.warn(r,"FBX mesh %s has %d UV sets; the engine reads the first two",mesh.name,len(mesh.uv_sets))}
    tangent,bitangent:ufbx.Vertex_Vec3
    if len(mesh.uv_sets)>0 {tangent,bitangent=mesh.uv_sets[0].vertex_tangent,mesh.uv_sets[0].vertex_bitangent}
    stated:=tangent.exists && bitangent.exists && normal.exists
    color:=mesh.vertex_color
    if uv1.exists {builder.has_uv1=true}
    if !position.exists {return importer.fail(r,.Malformed,"FBX mesh %s has no vertex positions",mesh.name)}
    points:=make([dynamic][3]f32,context.temp_allocator)
    corners_of:=make([dynamic]u32,context.temp_allocator)
    triangles:=make([dynamic][3]int,context.temp_allocator)
    scratch:=make([dynamic][2]f32,context.temp_allocator)
    result:=make([dynamic]u32,context.temp_allocator)
    skipped:=0
    point_of :: proc(v:ufbx.Vec3,transformed:bool,m:mm.Mat4) -> [3]f32 {
        p:=vec3(v)
        if transformed {p=(m*[4]f32{p.x,p.y,p.z,1}).xyz}
        return p
    }
    direction_of :: proc(v:ufbx.Vec3,transformed:bool,m:mm.Mat4) -> [3]f32 {
        d:=vec3(v)
        if transformed {d=(m*[4]f32{d.x,d.y,d.z,0}).xyz}
        return d
    }
    for face,face_index in mesh.faces {
        if face.num_indices<3 {skipped+=1;continue}
        material_index:=int(mesh.face_material[face_index]) if len(mesh.face_material)>face_index else 0
        material:=slot_material(node,mesh,material_index)
        material_row:=fbx_material(f,material,mesh) or_return
        label:=material.name if material!=nil else ""
        slot:=importer.builder_slot(builder,u32(material_index+1),label,material_row) or_return
        if material_row>=0 {
            for image,kind in r.materials[material_row].images {
                if image<0 {continue}
                uv_set:=importer.material_map(&r.materials[material_row].info,kind).uv_set
                if uv_set==0 && !uv0.exists || uv_set==1 && !uv1.exists {return importer.fail(r,.Malformed,"FBX material %s maps a texture by a UV set mesh %s does not have",material.name,mesh.name)}
            }
        }
        clear(&points);clear(&corners_of);clear(&triangles)
        for k in 0..<face.num_indices {
            ix:=face.index_begin+k
            if int(ix)>=len(position.indices) {return importer.fail(r,.Malformed,"FBX mesh %s: a face is outside its indices",mesh.name)}
            p:=point_of(position.values[position.indices[ix]],transformed,to_node)
            if !importer.finite3(p) {return importer.fail(r,.Malformed,"FBX mesh %s has a vertex position that is not finite",mesh.name)}
            append(&points,p)
            append(&corners_of,ix)
        }
        if !importer.polygon_triangulate(r,points[:],&triangles,&scratch,&result) {
            r.degenerate+=1
            continue
        }
        for triangle in triangles {
            at:=triangle
            if turned {at[1],at[2]=at[2],at[1]}
            a,b,c:=points[at[0]],points[at[1]],points[at[2]]
            if linalg.length(linalg.cross(b-a,c-a))<1e-12 {continue}
            flat:=importer.face_normal(a,b,c,{0,0,1})
            corners:[3]importer.Corner
            corner_skin:[3]asset.Skin_Vertex
            for k in 0..<3 {
                ix:=corners_of[at[k]]
                vertex:=mesh.vertex_indices[ix]
                corner:=importer.Corner{position=points[at[k]],normal=flat,color=importer.WHITE,flat=!normal.exists}
                if normal.exists {corner.normal=importer.normal_of(direction_of(normal.values[normal.indices[ix]],transformed,normal_to_node),flat)}
                if uv0.exists {corner.uv,corner.has_uv=vec2(uv0.values[uv0.indices[ix]]),true}
                if uv1.exists {corner.uv1,corner.has_uv1=vec2(uv1.values[uv1.indices[ix]]),true}
                if color.exists {corner.color=importer.pack_color(vec4(color.values[color.indices[ix]]))}
                if stated {
                    along:=linalg.normalize0(direction_of(tangent.values[tangent.indices[ix]],transformed,to_node))
                    side:=direction_of(bitangent.values[bitangent.indices[ix]],transformed,to_node)
                    if linalg.length(along)>0 {
                        sign:f32=1 if linalg.dot(linalg.cross(corner.normal,along),side)>=0 else -1
                        corner.tangent,corner.has_tangent=[4]f32{along.x,along.y,along.z,sign},true
                    }
                }
                if morphs {corner.morph=vertex+1}
                if len(skins)>0 {corner_skin[k]=skins[vertex]}
                corners[k]=corner
            }
            importer.builder_triangle(builder,slot,corners,corner_skin)
        }
    }
    if skipped>0 {importer.warn(r,"FBX mesh %s: %d faces of fewer than three corners (points and lines) were skipped",mesh.name,skipped)}
    return true
}

// The blend shapes of a mesh as its morph targets: the shape of each channel
// at full weight, in the order of its deformers.
@(private="file")
fbx_morphs :: proc(f:^Fbx,builder:^importer.Mesh_Builder,imported:^importer.Imported_Mesh,mesh:^ufbx.Mesh,channels:[]^ufbx.Blend_Channel,geometry:ufbx.Matrix,name:string) -> bool {
    r:=f.r
    transformed:=geometry.v!={}
    to_node:=mat4(geometry)
    count:=int(mesh.num_vertices)
    positions:=make([][3]f32,count,context.temp_allocator)
    normals:=make([][3]f32,count,context.temp_allocator)
    names:=make(map[string]bool,context.temp_allocator)
    inbetween:=0
    for channel,index in channels {
        shape:=channel.target_shape
        if len(channel.keyframes)>1 {inbetween+=1}
        morph:=importer.Morph_Shape{name=importer.unique_name(r,&names,channel_name(channel,index),index),weight=f32(channel.weight),positions=positions}
        for &value in positions {value={}}
        if shape!=nil {
            if len(shape.position_offsets)!=len(shape.offset_vertices) || len(shape.normal_offsets)!=0 && len(shape.normal_offsets)!=len(shape.offset_vertices) {
                return importer.fail(r,.Malformed,"FBX mesh %s: blend shape %s has offsets that do not match its vertices",name,morph.name)
            }
            with_normals:=len(shape.normal_offsets)>0 && mesh.vertex_normal.exists
            if with_normals {
                for &value in normals {value={}}
                morph.normals=normals
            }
            for vertex,i in shape.offset_vertices {
                if int(vertex)>=count {return importer.fail(r,.Malformed,"FBX mesh %s: blend shape %s moves a vertex the mesh does not have",name,morph.name)}
                delta:=vec3(shape.position_offsets[i])
                if transformed {delta=(to_node*[4]f32{delta.x,delta.y,delta.z,0}).xyz}
                if !importer.finite3(delta) {return importer.fail(r,.Malformed,"FBX mesh %s: blend shape %s has an offset that is not finite",name,morph.name)}
                positions[vertex]=delta
                if with_normals {normals[vertex]=vec3(shape.normal_offsets[i])}
            }
        }
        importer.builder_morph(builder,imported,morph) or_return
    }
    if inbetween>0 {importer.warn(r,"FBX mesh %s: %d blend shapes have in-between shapes; each is imported at full weight alone",name,inbetween)}
    return true
}

@(private="file")
channel_name :: proc(channel:^ufbx.Blend_Channel,index:int) -> string {
    if channel.name!="" {return channel.name}
    return fmt.tprintf("Morph %d",index+1)
}

@(private="file")
unit3 :: proc(v:[3]f32) -> [3]f32 {return {clamp(v[0],0,1),clamp(v[1],0,1),clamp(v[2],0,1)}}

// The shaders whose roughness ufbx derives from a shininess: their textures are of the shininess.
@(private="file")
shininess_shader :: proc(material:^ufbx.Material) -> bool {
    return material.shader_type==.FBX_LAMBERT || material.shader_type==.FBX_PHONG || material.shader_type==.BLENDER_PHONG
}

@(private="file")
fbx_material :: proc(f:^Fbx,material:^ufbx.Material,mesh:^ufbx.Mesh) -> (row:int,ok:bool) {
    r:=f.r
    if material==nil {return -1,true}
    if known,found:=f.materials[material];found {return known,true}
    name:=material.name if material.name!="" else fmt.tprintf("material %d",material.typed_id)
    info:=asset.MATERIAL_DEFAULTS
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    // FBX gives emission no unit: as in glTF, 1 is the white of the display.
    info.emission_mode=.Relative
    pbr:=&material.pbr
    legacy:=material.shader_type==.FBX_LAMBERT || material.shader_type==.FBX_PHONG
    base:=[3]f32{1,1,1}
    if pbr.base_color.has_value {base=vec3(pbr.base_color.value_vec3)}
    if pbr.base_factor.has_value {base*=f32(pbr.base_factor.value_real)}
    info.base_color=unit3(base)
    fbx_map(f,&info,&images,.Base_Color,&pbr.base_color,mesh,true,false,name) or_return
    if pbr.metalness.has_value {info.metallic=clamp(f32(pbr.metalness.value_real),0,1)}
    if pbr.roughness.has_value {
        roughness:=f32(pbr.roughness.value_real)
        if material.features.roughness_as_glossiness.enabled {roughness=1-roughness}
        info.roughness=clamp(roughness,0,1)
    }
    fbx_metal_rough(f,&info,&images,material,mesh,name) or_return
    if pbr.normal_map.texture!=nil {
        fbx_map(f,&info,&images,.Normal,&pbr.normal_map,mesh,false,true,name) or_return
    } else if material.fbx.bump.texture!=nil {
        importer.warn(r,"FBX material %s: its bump map is not imported; export a normal map",name)
    }
    fbx_map(f,&info,&images,.Occlusion,&pbr.ambient_occlusion,mesh,false,false,name) or_return
    emission:=[3]f32{}
    if pbr.emission_color.has_value {emission=vec3(pbr.emission_color.value_vec3)}
    if pbr.emission_factor.has_value {emission*=f32(pbr.emission_factor.value_real)}
    info.emission={max(emission.x,0),max(emission.y,0),max(emission.z,0)}
    if info.emission!={} || pbr.emission_color.texture!=nil {fbx_map(f,&info,&images,.Emission,&pbr.emission_color,mesh,true,false,name) or_return}
    // The transparency of Lambert and Phong is a cover: the opacity of the FBX SDK is one minus it.
    opacity:=f32(1)
    cover:^ufbx.Material_Map
    if legacy {
        factor:=f32(pbr.transmission_factor.value_real) if pbr.transmission_factor.has_value else 1
        tint:=vec3(pbr.transmission_color.value_vec3) if pbr.transmission_color.has_value else [3]f32{}
        opacity=1-factor*(tint.x+tint.y+tint.z)/3
        cover=&pbr.transmission_color if pbr.transmission_color.texture!=nil else &pbr.transmission_factor
    } else {
        if pbr.opacity.has_value {opacity=(f32(pbr.opacity.value_vec3.x)+f32(pbr.opacity.value_vec3.y)+f32(pbr.opacity.value_vec3.z))/3}
        cover=&pbr.opacity
        if pbr.transmission_factor.has_value {info.transmission=clamp(f32(pbr.transmission_factor.value_real),0,1)}
        if pbr.specular_factor.has_value {info.specular_factor=clamp(f32(pbr.specular_factor.value_real),0,1)}
        if pbr.specular_color.has_value {info.specular_color=unit3(vec3(pbr.specular_color.value_vec3))}
        if pbr.specular_ior.has_value && importer.ior_valid(f32(pbr.specular_ior.value_real)) {info.ior=f32(pbr.specular_ior.value_real)}
        if pbr.coat_factor.has_value && pbr.coat_factor.value_real>0 {
            info.coat.weight=clamp(f32(pbr.coat_factor.value_real),0,1)
            if pbr.coat_roughness.has_value {info.coat.roughness=clamp(f32(pbr.coat_roughness.value_real),0,1)}
            info.coat.ior=f32(pbr.coat_ior.value_real) if pbr.coat_ior.has_value && importer.ior_valid(f32(pbr.coat_ior.value_real)) else info.ior
        }
        if pbr.sheen_factor.has_value && pbr.sheen_factor.value_real>0 {importer.warn(r,"FBX material %s: its sheen is not imported",name)}
        if pbr.subsurface_factor.has_value && pbr.subsurface_factor.value_real>0 {importer.warn(r,"FBX material %s: its subsurface scattering is not imported",name)}
        for map_ in ([?]^ufbx.Material_Map{&pbr.transmission_factor,&pbr.specular_factor,&pbr.specular_color,&pbr.coat_factor,&pbr.coat_roughness,&pbr.coat_normal}) {
            if map_.texture!=nil && map_.texture_enabled {importer.warn(r,"FBX material %s: its textures of specular, coat and transmission are not imported; their values are",name);break}
        }
    }
    info.opacity=clamp(opacity,0,1)
    if cover.texture!=nil && cover.texture_enabled {
        base_texture:=pbr.base_color.texture
        if images[.Base_Color]>=0 && base_texture!=nil && (cover.texture==base_texture || cover.texture.filename!="" && cover.texture.filename==base_texture.filename) {
            info.alpha_mode=.Blend
        } else {
            importer.warn(r,"FBX material %s: its opacity texture is not imported; give the base color texture its alpha",name)
        }
    }
    if info.opacity<1 {info.alpha_mode=.Blend}
    row=importer.material_add(r,name,int(material.typed_id),info,images)
    f.materials[material]=row
    return row,true
}

// The texture of an FBX file texture, or the first file of a layered one.
@(private="file")
file_texture :: proc(f:^Fbx,texture:^ufbx.Texture,name:string) -> ^ufbx.Texture {
    if texture.type==.FILE {return texture}
    if len(texture.file_textures)>0 {
        importer.warn(f.r,"FBX material %s: a layered or procedural texture is imported as its first file",name)
        return texture.file_textures[0]
    }
    importer.warn(f.r,"FBX material %s: a procedural texture is not imported",name)
    return nil
}

// Where the image of a file texture is: its bytes when the file embeds them,
// else the file where the model names it, where it was saved, or by its name
// next to the model. stem names the image.
@(private="file")
texture_source :: proc(f:^Fbx,texture:^ufbx.Texture) -> (bytes:[]u8,path,stem:string) {
    label,_:=strings.replace_all(texture.relative_filename if texture.relative_filename!="" else texture.filename,"\\","/",context.temp_allocator)
    stem=filepath.stem(label) if label!="" else texture.name
    if stem=="" {stem=fmt.tprintf("texture %d",texture.typed_id)}
    if len(texture.content)>0 {return texture.content,"",stem}
    candidates:=[3]string{texture.filename,texture.absolute_filename,""}
    if label!="" {candidates[2]=importer.resolve_path(f.r,filepath.base(label))}
    for candidate in candidates {
        if candidate!="" && !importer.unsafe_path(candidate) && os.is_file(candidate) {return nil,candidate,stem}
    }
    return nil,texture.filename,stem
}

// The image of a file texture, -1 for one that names no file.
@(private="file")
fbx_image :: proc(f:^Fbx,texture:^ufbx.Texture,srgb,normal_map:bool) -> int {
    bytes,path,stem:=texture_source(f,texture)
    if len(bytes)>0 {return importer.image_embedded(f.r,fmt.tprintf("%s#%d",f.r.path,texture.file_index),stem,bytes,srgb,normal_map)}
    if path=="" {return -1}
    return importer.image_file(f.r,path,srgb,normal_map)
}

// The mapping of a texture: the UV set it names among those of the mesh, and
// the scale and offset of its transform.
@(private="file")
fbx_mapping :: proc(f:^Fbx,texture:^ufbx.Texture,mesh:^ufbx.Mesh,name:string) -> (mapping:asset.Material_Map,ok:bool) {
    mapping=asset.MATERIAL_MAP_DEFAULT
    if texture.uv_set!="" {
        for set,i in mesh.uv_sets {
            if set.name!=texture.uv_set {continue}
            if i>1 {return mapping,importer.fail(f.r,.Unsupported,"FBX material %s maps a texture by UV set %s, the %d-th of mesh %s; the engine reads two",name,texture.uv_set,i+1,mesh.name)}
            mapping.uv_set=u32(i)
        }
    }
    if texture.has_uv_transform {
        m:=texture.uv_to_texture
        if abs(m.m10)>1e-6 || abs(m.m01)>1e-6 {
            importer.warn(f.r,"FBX material %s: a texture is rotated, which is not imported",name)
        } else {
            mapping.scale={f32(m.m00),f32(m.m11)}
            mapping.offset={f32(m.m03),f32(m.m13)}
        }
    }
    return mapping,true
}

@(private="file")
fbx_map :: proc(f:^Fbx,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,kind:asset.Material_Map_Kind,map_:^ufbx.Material_Map,mesh:^ufbx.Mesh,srgb,normal_map:bool,name:string) -> bool {
    if map_.texture==nil || !map_.texture_enabled {return true}
    texture:=file_texture(f,map_.texture,name)
    if texture==nil {return true}
    importer.material_map(info,kind)^=fbx_mapping(f,texture,mesh,name) or_return
    images[kind]=fbx_image(f,texture,srgb,normal_map)
    return true
}

// The roughness and metalness textures in the green and blue channels of one
// image, as the engine reads them, from the red channel of each: FBX gives
// them as images of one channel each.
@(private="file")
fbx_metal_rough :: proc(f:^Fbx,info:^asset.Material_Info,images:^[asset.Material_Map_Kind]int,material:^ufbx.Material,mesh:^ufbx.Mesh,name:string) -> bool {
    r:=f.r
    maps:=[2]^ufbx.Material_Map{&material.pbr.roughness,&material.pbr.metalness}
    present:[2]bool
    sources:[2]^ufbx.Texture
    for map_,i in maps {
        if map_.texture==nil || !map_.texture_enabled {continue}
        if i==0 && shininess_shader(material) {
            importer.warn(r,"FBX material %s: its shininess texture is not imported; its value is, as a roughness",name)
            continue
        }
        sources[i]=file_texture(f,map_.texture,name)
        present[i]=sources[i]!=nil
    }
    if !present[0] && !present[1] {return true}
    mappings:[2]asset.Material_Map
    decoded:[2]textures.Image
    width,height:=0,0
    for i in 0..<2 {
        if !present[i] {continue}
        mappings[i]=fbx_mapping(f,sources[i],mesh,name) or_return
        image,read:=texture_pixels(f,sources[i])
        if !read {
            importer.warn(r,"FBX material %s: its roughness or metalness texture cannot be read; their values are imported",name)
            return true
        }
        decoded[i]=image
        width,height=max(width,image.width),max(height,image.height)
    }
    if present[0] && present[1] && mappings[0]!=mappings[1] {
        importer.warn(r,"FBX material %s: its roughness and metalness textures differ in UV set or transform; their values are imported",name)
        return true
    }
    red :: proc(image:textures.Image,x,y,width,height:int) -> u8 {
        sx,sy:=min(x*image.width/width,image.width-1),min(y*image.height/height,image.height-1)
        return image.pixels[(sy*image.width+sx)*4]
    }
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    for y in 0..<height {
        for x in 0..<width {
            at:=(y*width+x)*4
            pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=255,255,255,255
            if present[0] {pixels[at+1]=red(decoded[0],x,y,width,height)}
            if present[1] {pixels[at+2]=red(decoded[1],x,y,width,height)}
        }
    }
    key:=fmt.tprintf("%s#metal-rough%d",r.path,material.typed_id)
    images[.Metallic_Roughness]=importer.image_pixels(r,key,fmt.tprintf("%s metallic roughness",name),textures.rgba8(pixels,width,height),false,false)
    importer.material_map(info,.Metallic_Roughness)^=mappings[0] if present[0] else mappings[1]
    return true
}

@(private="file")
texture_pixels :: proc(f:^Fbx,texture:^ufbx.Texture) -> (image:textures.Image,ok:bool) {
    bytes,path,_:=texture_source(f,texture)
    if len(bytes)==0 {
        if path=="" || importer.unsafe_path(path) {return}
        data,error:=os.read_entire_file_from_path(path,context.temp_allocator)
        if error!=nil {return}
        bytes=data
    }
    decoded,error:=textures.image_decode(bytes,context.temp_allocator)
    return decoded,error==.None
}

// What ufbx resamples at where the scene gives no frame rate.
DEFAULT_RATE :: 30
// The most samples between two keys and the most a key drifts from its curve:
// ufbx bakes and reduces with them, and so does the compensated scale.
SEGMENT_SAMPLES :: 32
KEY_TOLERANCE :: 1e-6

// A clip of each animation stack, sampled by ufbx at the rate of the scene:
// FBX interpolates Euler angles, which no curve of quaternions repeats.
@(private="file")
fbx_animations :: proc(f:^Fbx) -> bool {
    r:=f.r
    scene:=f.scene
    rate:=scene.settings.frames_per_second
    if !(rate>0) || rate-rate!=0 {rate=DEFAULT_RATE}
    if len(scene.anim_stacks)>asset.ANIMATION_MAX_CLIPS {return importer.fail(r,.Limit,"too many FBX animation stacks")}
    names:=make(map[string]bool,context.temp_allocator)
    total_tracks,total_keys:=0,0
    for stack,clip_index in scene.anim_stacks {
        name:=stack.name if stack.name!="" else fmt.tprintf("Animation %d",clip_index)
        name=importer.unique_name(r,&names,name,clip_index)
        if len(name)>=asset.ANIMATION_NAME_CAPACITY {return importer.fail(r,.Limit,"FBX animation name %s is too long",name)}
        opts:=ufbx.Bake_Opts{trim_start_time=true,resample_rate=rate,max_keyframe_segments=SEGMENT_SAMPLES,step_handling=.IDENTICAL_TIME,key_reduction_enabled=true,key_reduction_threshold=KEY_TOLERANCE}
        error:ufbx.Error
        baked:=ufbx.bake_anim(scene,stack.anim,&opts,&error)
        if baked==nil {return fbx_fail(r,&error)}
        defer ufbx.free_baked_anim(baked)
        tracks:=make([dynamic]asset.Animation_Track_Desc,r.out)
        end:=f32(baked.playback_duration)
        baked_rows:=make([]int,len(scene.nodes),context.temp_allocator)
        slice.fill(baked_rows,-1)
        for node,i in baked.nodes {
            if int(node.typed_id)<len(scene.nodes) {baked_rows[node.typed_id]=i}
        }
        for &node in baked.nodes {
            if int(node.typed_id)>=len(scene.nodes) || scene.nodes[node.typed_id].is_root {continue}
            source:=scene.nodes[node.typed_id]
            target:=f.paths[node.typed_id]
            position:=vec3_keys(r,node.translation_keys[:],name,end,&total_keys) or_return
            rotation:=quat_keys(r,node.rotation_keys[:],name,end,&total_keys) or_return
            scale_keys:=vec3_all(r,node.scale_keys[:],name) or_return
            if ignores_parent_scale(source) {
                parent:=raw_scale(r,baked,baked_rows,source.parent,name) or_return
                scale_keys=compensated_scale(f,source,scale_keys[:],parent[:],rate,name) or_return
            }
            scale:=keys_window(r,scale_keys,end,false,&total_keys) or_return
            append(&tracks,asset.Animation_Track_Desc{target=target,property=.Position,keys=position})
            append(&tracks,asset.Animation_Track_Desc{target=target,property=.Rotation,keys=rotation})
            append(&tracks,asset.Animation_Track_Desc{target=target,property=.Scale,keys=scale})
        }
        // A node without curves that does not inherit the scale its parent animates gets a track that undoes it.
        for source in scene.nodes {
            if !ignores_parent_scale(source) || baked_rows[source.typed_id]>=0 || baked_rows[source.parent.typed_id]<0 {continue}
            parent:=raw_scale(r,baked,baked_rows,source.parent,name) or_return
            rest:=vec3(source.parent.local_transform.scale)
            still:=true
            for key in parent {still&&=linalg.length(key.value.xyz-rest)<=KEY_TOLERANCE}
            if still {continue}
            own:=raw_scale(r,baked,baked_rows,source,name) or_return
            scale_keys:=compensated_scale(f,source,own[:],parent[:],rate,name) or_return
            scale:=keys_window(r,scale_keys,end,false,&total_keys) or_return
            append(&tracks,asset.Animation_Track_Desc{target=f.paths[source.typed_id],property=.Scale,keys=scale})
        }
        for &element in baked.elements {
            if int(element.element_id)>=len(scene.elements) || scene.elements[element.element_id].type!=.BLEND_CHANNEL {continue}
            channel:=(^ufbx.Blend_Channel)(rawptr(scene.elements[element.element_id]))
            for &prop in element.props {
                if prop.name!="DeformPercent" {continue}
                keys:=vec3_keys(r,prop.keys[:],name,end,&total_keys) or_return
                // DeformPercent is a percentage; a morph weight is one at full shape.
                for &key in keys {key.value.x/=100;key.value.yzw={}}
                fbx_weight_tracks(f,channel,keys,&tracks) or_return
            }
        }
        // A number property a user added to a node and the stack animates (a custom attribute)
        // is a Float curve of its name: animation tools export the curves of faces so.
        curves:=make(map[string]bool,context.temp_allocator)
        for &element in baked.elements {
            if int(element.element_id)>=len(scene.elements) || scene.elements[element.element_id].type!=.NODE {continue}
            owner:=scene.elements[element.element_id]
            for &prop in element.props {
                found:=ufbx.find_prop_len(&owner.props,cstring(raw_data(prop.name)),uint(len(prop.name)))
                if found==nil || found.flags&ufbx.PROP_FLAG_USER_DEFINED==0 || found.type!=.NUMBER && found.type!=.INTEGER && found.type!=.BOOLEAN {continue}
                if prop.name=="" || len(prop.name)>=asset.NODE_PATH_CAPACITY {importer.warn(r,"FBX curve %s has a name longer than %d bytes and is left out",prop.name,asset.NODE_PATH_CAPACITY-1);continue}
                if prop.name in curves {importer.warn(r,"FBX animation %s animates curve %s on two nodes; the first is kept",name,prop.name);continue}
                curves[prop.name]=true
                keys:=vec3_keys(r,prop.keys[:],name,end,&total_keys) or_return
                for &key in keys {key.value.yzw={}}
                append(&tracks,asset.Animation_Track_Desc{target=importer.own(r,prop.name),property=.Float,keys=keys})
            }
        }
        // A stack without curves, as the Take 001 of Mixamo, is no clip.
        if len(tracks)==0 {continue}
        total_tracks+=len(tracks)
        if total_tracks>asset.ANIMATION_MAX_TRACKS {return importer.fail(r,.Limit,"too many FBX animation tracks")}
        append(&r.animations,asset.Animation_Clip_Desc{name=name,tracks=tracks[:]})
    }
    return true
}

// The track of the weight of a blend shape on every node that shows a mesh of its channel.
@(private="file")
fbx_weight_tracks :: proc(f:^Fbx,channel:^ufbx.Blend_Channel,keys:[]anim.Keyframe,tracks:^[dynamic]asset.Animation_Track_Desc) -> bool {
    for mesh in f.scene.meshes {
        index:=0
        found:=-1
        for deformer in mesh.blend_deformers {
            for candidate in deformer.channels {
                if candidate==channel {found=index}
                index+=1
            }
        }
        if found<0 {continue}
        for node in mesh.instances {
            if f.rows[node.typed_id]<0 {continue}
            mesh_row:=f.r.nodes[f.rows[node.typed_id]].mesh
            if mesh_row<0 || found>=len(f.r.meshes[mesh_row].morphs) {continue}
            morph:=base.text_get(f.r.meshes[mesh_row].morphs[found].name[:])
            target:=fmt.tprintf("%s%s%s",f.paths[node.typed_id],asset.ANIMATION_MORPH_PATH,morph)
            if len(target)>=asset.NODE_PATH_CAPACITY {return importer.fail(f.r,.Limit,"the morph track %s is longer than %d bytes",target,asset.NODE_PATH_CAPACITY-1)}
            append(tracks,asset.Animation_Track_Desc{target=importer.own(f.r,target),property=.Float,keys=keys})
        }
    }
    return true
}

// Linear keys; a step, which ufbx gives as two keys at one time, is the
// second of them reached by a step, and the first is the value the keys reach
// before it.
@(private="file")
key_times :: proc(r:^importer.Reader,times:[]f64,flags:[]ufbx.Baked_Key_Flags,values:[]mm.Vec4,clip:string) -> (keys:[dynamic]anim.Keyframe,ok:bool) {
    keys=make([dynamic]anim.Keyframe,0,len(times),context.temp_allocator)
    step:=false
    for time,i in times {
        if f32(time)-f32(time)!=0 {return keys,importer.fail(r,.Malformed,"FBX animation %s has a time that is not finite",clip)}
        if i+1<len(times) && flags[i]&ufbx.BAKED_KEY_STEP_LEFT!=0 && f32(times[i+1])==f32(time) {
            step=true
            before_step(&keys,f32(time),values[i])
            continue
        }
        frame:=anim.Keyframe{time=f32(time),value=values[i],interpolation=.Step if step else .Linear}
        step=false
        if len(keys)>0 && frame.time<=keys[len(keys)-1].time {
            // The right side of a step that starts at a key replaces that key.
            if flags[i]&ufbx.BAKED_KEY_STEP_RIGHT==0 {return keys,importer.fail(r,.Malformed,"FBX animation %s has keys closer than a float tells apart",clip)}
            pop(&keys)
            frame.interpolation=.Step
        }
        append(&keys,frame)
    }
    if len(keys)==0 {return keys,importer.fail(r,.Malformed,"FBX animation %s has a track without keys",clip)}
    return keys,true
}

// The value keys reach just before a step at time: the last key holds it, or
// a key a float earlier ends the line to it. A step only holds the value
// before it, and one channel of a key may step while another moves.
@(private="file")
before_step :: proc(keys:^[dynamic]anim.Keyframe,time:f32,value:mm.Vec4) {
    if len(keys)==0 || linalg.length(value-keys[len(keys)-1].value)<=KEY_TOLERANCE {return}
    just_before:=math.nextafter(time,math.inf_f32(-1))
    if just_before>keys[len(keys)-1].time {append(keys,anim.Keyframe{time=just_before,value=value})}
}

// The keys inside the range of the stack, from 0 to end (none: to the last
// key), with a key at each edge they cross that has the value the keys give
// there; the range of the stack is the clip.
@(private="file")
keys_window :: proc(r:^importer.Reader,keys:[dynamic]anim.Keyframe,end:f32,rotation:bool,total_keys:^int) -> (window:[]anim.Keyframe,ok:bool) {
    at :: proc(keys:[]anim.Keyframe,time:f32,rotation:bool) -> anim.Keyframe {
        after:=0
        for after<len(keys) && keys[after].time<time {after+=1}
        frame:=anim.Keyframe{time=time,interpolation=.Linear}
        switch {
        case after==0: frame.value=keys[0].value
        case after==len(keys): frame.value=keys[len(keys)-1].value
        case keys[after].interpolation==.Step: frame.value=keys[after-1].value
        case:
            a,b:=keys[after-1],keys[after]
            frame.value=a.value+(b.value-a.value)*((time-a.time)/(b.time-a.time))
            if rotation {frame.value=linalg.normalize0(frame.value)}
        }
        return frame
    }
    out:=make([dynamic]anim.Keyframe,0,len(keys)+2,r.out)
    last:=keys[len(keys)-1].time
    end:=end
    if !(end>0) || end>last {end=last}
    if keys[0].time<0 {append(&out,at(keys[:],0,rotation))}
    for key in keys {
        if key.time<0 || key.time>end {continue}
        if len(out)>0 && key.time<=out[len(out)-1].time {continue}
        append(&out,key)
    }
    if len(out)==0 || out[len(out)-1].time<end {append(&out,at(keys[:],end,rotation))}
    if len(out)>asset.ANIMATION_MAX_KEYS-total_keys^ {return nil,importer.fail(r,.Limit,"too many FBX animation keys")}
    total_keys^+=len(out)
    return out[:],true
}

@(private="file")
vec3_keys :: proc(r:^importer.Reader,source:[]ufbx.Baked_Vec3,clip:string,end:f32,total_keys:^int) -> (keys:[]anim.Keyframe,ok:bool) {
    all:=vec3_all(r,source,clip) or_return
    return keys_window(r,all,end,false,total_keys)
}

// Every key of a baked curve, before the range of the stack cuts them.
@(private="file")
vec3_all :: proc(r:^importer.Reader,source:[]ufbx.Baked_Vec3,clip:string) -> (all:[dynamic]anim.Keyframe,ok:bool) {
    times:=make([]f64,len(source),context.temp_allocator)
    flags:=make([]ufbx.Baked_Key_Flags,len(source),context.temp_allocator)
    values:=make([]mm.Vec4,len(source),context.temp_allocator)
    for key,i in source {
        v:=vec3(key.value)
        if !importer.finite3(v) {return all,importer.fail(r,.Malformed,"FBX animation %s has a value that is not finite",clip)}
        times[i],flags[i],values[i]=key.time,key.flags,{v.x,v.y,v.z,0}
    }
    return key_times(r,times,flags,values,clip)
}

// The scale of a node over a clip as the file gives it: its keys, or its own
// scale where it has none.
@(private="file")
raw_scale :: proc(r:^importer.Reader,baked:^ufbx.Baked_Anim,baked_rows:[]int,node:^ufbx.Node,clip:string) -> (keys:[dynamic]anim.Keyframe,ok:bool) {
    if row:=baked_rows[node.typed_id];row>=0 {return vec3_all(r,baked.nodes[row].scale_keys[:],clip)}
    keys=make([dynamic]anim.Keyframe,0,1,context.temp_allocator)
    scale:=vec3(node.local_transform.scale)
    append(&keys,anim.Keyframe{value={scale.x,scale.y,scale.z,0}})
    return keys,true
}

// The scale keys of a node that does not inherit the scale of its parent: its
// own over the parent's at each key of either. Where the parent's scale
// changes the quotient is no line, so there it is sampled as ufbx samples a
// curve, and then reduced to the keys that lines do not repeat.
@(private="file")
compensated_scale :: proc(f:^Fbx,node:^ufbx.Node,own,parent:[]anim.Keyframe,rate:f64,clip:string) -> (keys:[dynamic]anim.Keyframe,ok:bool) {
    r:=f.r
    times:=make([dynamic]f32,0,len(own)+len(parent),context.temp_allocator)
    for key in own {append(&times,key.time)}
    for key in parent {append(&times,key.time)}
    for i in 1..<len(parent) {
        a,b:=parent[i-1],parent[i]
        if b.interpolation==.Step || a.value==b.value {continue}
        // On frames half a frame away from the keys; on long spans every second, fourth... frame.
        frames:=(f64(b.time)-f64(a.time))*rate
        if frames-frames!=0 {return keys,importer.fail(r,.Malformed,"FBX animation %s has more frames than a number holds",clip)}
        factor:=1.0
        for frames/factor>=SEGMENT_SAMPLES {factor*=2}
        padding:=0.5/rate
        start:=math.ceil((f64(a.time)+padding)*rate/factor)*factor
        for sample in 0..<SEGMENT_SAMPLES {
            time:=(start+f64(sample)*factor)/rate
            if time>=f64(b.time)-padding {break}
            append(&times,f32(time))
        }
    }
    slice.sort(times[:])
    // The value of keys at a time and the one they hold just before it, which differs at a step.
    held :: proc(keys:[]anim.Keyframe,cursor:^int,time:f32) -> (before,at:[3]f32) {
        for cursor^<len(keys) && keys[cursor^].time<time {cursor^+=1}
        at=anim.track_evaluate(keys,.Scale,time).xyz
        before=at
        if cursor^>0 && cursor^<len(keys) && keys[cursor^].time==time && keys[cursor^].interpolation==.Step {before=keys[cursor^-1].value.xyz}
        return
    }
    samples:=make([dynamic]anim.Keyframe,0,len(times)+len(parent),context.temp_allocator)
    own_cursor,parent_cursor:=0,0
    for time,i in times {
        if i>0 && time==times[i-1] {continue}
        own_before,own_at:=held(own,&own_cursor,time)
        parent_before,parent_at:=held(parent,&parent_cursor,time)
        for axis in 0..<3 {
            if abs(parent_before[axis])<1e-8 || abs(parent_at[axis])<1e-8 {return keys,importer.fail(r,.Unsupported,"FBX node %s does not inherit the scale of its parent, which is zero in animation %s; the engine passes the scale of a parent to its children",node_label(f,node),clip)}
        }
        before,at:=own_before/parent_before,own_at/parent_at
        if !importer.finite3(before) || !importer.finite3(at) {return keys,importer.fail(r,.Malformed,"FBX animation %s has a value that is not finite",clip)}
        frame:=anim.Keyframe{time=time,value={at.x,at.y,at.z,0}}
        // A step of either is a step of the quotient.
        if before!=at && len(samples)>0 {
            before_step(&samples,time,{before.x,before.y,before.z,0})
            frame.interpolation=.Step
        }
        append(&samples,frame)
    }
    return keys_reduce(samples[:]),true
}

// The keys without those that the line from the last kept key to the next one
// repeats on each axis within KEY_TOLERANCE, with every key dropped between
// them. The slopes from the kept key that pass by every dropped key narrow to
// an interval, so a key costs the same however many were dropped. Steps stay.
@(private="file")
keys_reduce :: proc(keys:[]anim.Keyframe) -> [dynamic]anim.Keyframe {
    out:=make([dynamic]anim.Keyframe,0,len(keys),context.temp_allocator)
    if len(keys)==0 {return out}
    append(&out,keys[0])
    anchor:=keys[0]
    open_low,open_high:=[3]f32{math.inf_f32(-1),math.inf_f32(-1),math.inf_f32(-1)},[3]f32{math.inf_f32(1),math.inf_f32(1),math.inf_f32(1)}
    low,high:=open_low,open_high
    for i in 1..<len(keys)-1 {
        key,next:=keys[i],keys[i+1]
        span:=key.time-anchor.time
        narrow_low:=linalg.max(low,(key.value.xyz-KEY_TOLERANCE-anchor.value.xyz)/span)
        narrow_high:=linalg.min(high,(key.value.xyz+KEY_TOLERANCE-anchor.value.xyz)/span)
        // A step holds the value before it: the line to it is flat.
        slope:=[3]f32{}
        if next.interpolation!=.Step {slope=(next.value.xyz-anchor.value.xyz)/(next.time-anchor.time)}
        if key.interpolation==.Linear && span>0 && slope.x>=narrow_low.x && slope.x<=narrow_high.x && slope.y>=narrow_low.y && slope.y<=narrow_high.y && slope.z>=narrow_low.z && slope.z<=narrow_high.z {
            low,high=narrow_low,narrow_high
            continue
        }
        append(&out,key)
        anchor=key
        low,high=open_low,open_high
    }
    if len(keys)>1 {append(&out,keys[len(keys)-1])}
    return out
}

@(private="file")
quat_keys :: proc(r:^importer.Reader,source:[]ufbx.Baked_Quat,clip:string,end:f32,total_keys:^int) -> (keys:[]anim.Keyframe,ok:bool) {
    times:=make([]f64,len(source),context.temp_allocator)
    flags:=make([]ufbx.Baked_Key_Flags,len(source),context.temp_allocator)
    values:=make([]mm.Vec4,len(source),context.temp_allocator)
    for key,i in source {
        v:=mm.Vec4{f32(key.value.x),f32(key.value.y),f32(key.value.z),f32(key.value.w)}
        length:=linalg.length(v)
        if !(length>1e-8) || length-length!=0 {return nil,importer.fail(r,.Malformed,"FBX animation %s has a rotation without length",clip)}
        times[i],flags[i],values[i]=key.time,key.flags,v/length
    }
    all:=key_times(r,times,flags,values,clip) or_return
    return keys_window(r,all,end,true,total_keys)
}
