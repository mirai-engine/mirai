package asset

import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// The far mesh of a section (its HLOD): the static meshes of a scene, each
// cut from its own DAG at an error and placed in the space of the scene,
// joined in one mesh of one slot that goes through the same constructor of
// the DAG (geom.cluster_dag_build). Its cut draws the section from afar and
// its coarse cuts are the BLAS rays trace there. It has no textures: each
// cluster keeps the mean color, roughness, metallic and emission of what it
// covers in its vertices (Surface_Vertex), as one slot lets the simplifier
// join what different materials covered.

FAR_TEXTURE_SIZE :: 64 // texels a side of the level of a texture a far mesh reads its material from, at most
// What the simplifier weighs of a vertex of a far mesh against its place: the
// normal (x, y, z), then the base color (r, g, b).
FAR_SIMPLIFY_WEIGHTS :: [6]f32{0.5,0.5,0.5,0.5,0.5,0.5}

// A level of a texture as a far mesh reads it: linear when the texture is sRGB.
Far_Texture :: struct {
    width,height:int,
    texels:[][4]f32,
}

// A map of a material, placed: uv' = linear * uv + offset, as the renderer
// composes the transform of the material and that of the map.
Far_Map :: struct {
    texture:^Far_Texture, // nil: none
    linear:[4]f32,
    offset:[2]f32,
    uv_set:u32,
}

// A material as a far mesh keeps it.
Far_Material :: struct {
    base_color:[4]f32, // linear, and its opacity
    masked:bool,       // its alpha covers: what it does not cover counts less in the mean
    cutoff:f32,        // masked: a triangle whose points cover less on average is left out (leaves of a card)
    roughness,metallic:f32,
    emission:[3]f32,   // nits
    base_map,metallic_roughness_map,emission_map:Far_Map,
}

// A mesh of a section: its geometry as its file holds it, where it is in the
// section, and the material of each of its slots.
Far_Part :: struct {
    geometry:Mesh_Geometry,
    placement:matrix[4,4]f32,
    materials:[MESH_MAX_SLOTS]Far_Material,
}

// The level of a texture whose larger side is FAR_TEXTURE_SIZE at most,
// decoded. In allocator; false for a level that does not decode.
far_texture :: proc(view:Texture_View,allocator:=context.allocator) -> (texture:Far_Texture,ok:bool) {
    info:=view.info
    level:=0
    width,height:=int(info.width),int(info.height)
    for level+1<len(view.mips) && max(width,height)>FAR_TEXTURE_SIZE {
        level+=1
        width,height=max(width/2,1),max(height/2,1)
    }
    texels,error:=make([][4]f32,width*height,allocator)
    if error!=nil {return}
    if !texture_level_linear(info.format,info.flags,texture_layer(view,level,0),width,height,texels) {
        delete(texels,allocator)
        return
    }
    return {width,height,texels},true
}

far_texture_destroy :: proc(texture:^Far_Texture,allocator:=context.allocator) {
    delete(texture.texels,allocator)
    texture^={}
}

// A material as a far mesh keeps it, its maps reading the textures given
// (nil for one that is not there). A relative emission is left out: it is
// an exposed value, not a light the section gives.
far_material :: proc(info:Material_Info,base,metallic_roughness,emission:^Far_Texture) -> Far_Material {
    placed :: proc(m:Material_Map,texture:^Far_Texture) -> Far_Map {
        if texture==nil {return {}}
        sine,cosine:=math.sin(m.rotation),math.cos(m.rotation)
        return {
            texture=texture,
            linear={cosine*m.scale.x,-sine*m.scale.y,sine*m.scale.x,cosine*m.scale.y},
            offset=m.offset,
            uv_set=m.uv_set,
        }
    }
    out:=Far_Material{
        base_color={info.base_color.r,info.base_color.g,info.base_color.b,info.opacity},
        masked=info.alpha_mode!=.Opaque,
        cutoff=info.alpha_cutoff if info.alpha_mode==.Mask else 0,
        roughness=info.roughness,metallic=info.metallic,
    }
    if info.emission_mode==.Physical {out.emission=info.emission}
    out.base_map=placed(info.maps.base_color,base)
    out.metallic_roughness_map=placed(info.maps.metallic_roughness,metallic_roughness)
    out.emission_map=placed(info.maps.emission,emission)
    return out
}

// The texture parameter of a material program that holds its base color,
// by its name (base color, albedo, diffuse, color), as the CPU cannot run
// the program: none when no parameter says so.
far_base_parameter :: proc(parameters:[]Material_Parameter) -> base.Asset_Id {
    NAMES :: [?]string{"basecolor","base_color","albedo","diffuse","dif","color","col"}
    best,rank:=base.Asset_Id{},len(NAMES)
    for &p in parameters {
        if p.kind!=.Texture || p.texture=={} {continue}
        name:=strings.to_lower(base.text_get(p.name[:]),context.temp_allocator)
        for word,at in NAMES {
            if at<rank && strings.contains(name,word) {best,rank=p.texture,at}
        }
    }
    return best
}

// What a far mesh keeps of a point of a material.
@(private="file")
Far_Value :: struct {
    color:[4]f32, // linear base color, and the coverage it is weighed by
    roughness,metallic:f32,
    emission:[3]f32,
}

@(private="file")
far_sample :: proc "contextless" (m:Far_Map,uv,uv1:[2]f32) -> [4]f32 {
    t:=m.texture
    if t==nil || t.width<=0 || t.height<=0 {return {1,1,1,1}}
    at:=uv1 if m.uv_set==1 else uv
    p:=[2]f32{m.linear.x*at.x+m.linear.y*at.y,m.linear.z*at.x+m.linear.w*at.y}+m.offset
    p-={math.floor(p.x),math.floor(p.y)}
    if !(p.x>=0 && p.y>=0) {p={}}
    x:=clamp(int(p.x*f32(t.width)),0,t.width-1)
    y:=clamp(int(p.y*f32(t.height)),0,t.height-1)
    return t.texels[y*t.width+x]
}

@(private="file")
far_value :: proc "contextless" (m:Far_Material,v:Vertex) -> Far_Value {
    base:=m.base_color*far_sample(m.base_map,v.uv,v.uv1)*mm.rgba8_unpack(v.color)
    orm:=far_sample(m.metallic_roughness_map,v.uv,v.uv1)
    emission:=m.emission*far_sample(m.emission_map,v.uv,v.uv1).rgb
    out:=Far_Value{roughness=clamp(m.roughness*orm.g,0,1),metallic=clamp(m.metallic*orm.b,0,1),emission=emission}
    out.color={base.r,base.g,base.b,clamp(base.a,0,1) if m.masked else 1}
    return out
}

// The largest factor a placement scales a length by.
@(private="file")
placement_scale :: proc "contextless" (m:matrix[4,4]f32) -> f32 {
    x:=linalg.length([3]f32{m[0,0],m[1,0],m[2,0]})
    y:=linalg.length([3]f32{m[0,1],m[1,1],m[2,1]})
    z:=linalg.length([3]f32{m[0,2],m[1,2],m[2,2]})
    return max(x,y,z)
}

// Builds the far mesh of parts into out (in allocator): of each part, the
// cut of its levels at error (in the space of the section: a part scaled up
// takes a finer cut), placed in the section, all of slot 0. Its errors are
// those of its DAG plus error, so a view asks for its first level no closer
// than the parts allow. The vertices of each cluster carry the mean, by
// area and coverage, of the color, roughness, metallic and emission of the
// points of its triangles; a triangle of a masked material whose points
// cover less than its cutoff on average is left out. When its root is not
// every page it carries the blocks of its pages (mesh_pages_pack), and the
// renderer streams it as a mesh of a file. False without parts, for a part
// that is not a mesh or without memory.
mesh_build_far :: proc(parts:[]Far_Part,error:f32,out:^Mesh_Geometry,allocator:=context.allocator) -> bool {
    if len(parts)==0 || !(error>=0) || !finite(error) {return false}
    scratch:=context.temp_allocator
    vertices:=make([dynamic]Vertex,scratch)
    values:=make([dynamic]Far_Value,scratch)
    indices:=make([dynamic]u32,scratch)
    // A vertex shared by clusters of a part decodes alike in each: it is one again.
    Weld :: struct {place:[3]i32,normal:u32,slot:u32}
    welded:=make(map[Weld]u32,scratch)
    for part in parts {
        g:=part.geometry
        if len(g.clusters)==0 || len(g.levels)==0 {return false}
        scale:=placement_scale(part.placement)
        if !(scale>0) || !finite(scale) {return false}
        local:=error/scale
        normal_matrix:=linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(part.placement)))
        mirrored:=linalg.determinant(linalg.matrix3_from_matrix4(part.placement))<0
        clear(&welded)
        for c in g.clusters {
            if !(c.error<=local && c.parent_error>local) {continue}
            slot:=cluster_slot(c)
            material:=part.materials[slot] if slot<MESH_MAX_SLOTS else Far_Material{}
            corners:[CLUSTER_VERTICES]u32
            for k in 0..<cluster_vertex_count(c) {
                at:=c.vertex_first+k
                packed:=g.vertices[at]
                key:=Weld{c.position+{i32(packed.xy&0xffff),i32(packed.xy>>16),i32(packed.z_u&0xffff)},packed.normal,slot}
                if found,seen:=welded[key];seen {
                    corners[k]=found
                    continue
                }
                v:=cluster_vertex(g,c,k)
                value:=far_value(material,v)
                p:=part.placement*[4]f32{v.position.x,v.position.y,v.position.z,1}
                n:=normal_matrix*mm.normal_unpack(v.normal)
                length:=linalg.length(n)
                n=n/length if length>1e-20 else {0,1,0}
                packed_normal:=mm.normal_pack(n)
                _,along,_:=mm.tangent_axes(packed_normal)
                placed:=Vertex{position=p.xyz,normal=packed_normal,tangent=mm.tangent_pack(along,1),color=0xffffffff}
                corners[k]=u32(len(vertices))
                welded[key]=corners[k]
                append(&vertices,placed)
                append(&values,value)
            }
            for t in 0..<cluster_triangle_count(c) {
                tri:=cluster_triangle(g.triangles,c,t)
                a,b,d:=corners[tri[0]],corners[tri[1]],corners[tri[2]]
                if material.masked && (values[a].color.a+values[b].color.a+values[d].color.a)/3<material.cutoff {continue}
                if mirrored {b,d=d,b}
                append(&indices,a,b,d)
            }
        }
    }
    if len(indices)==0 {return false}

    // The DAG of all of them, the simplifier weighing their normals and colors.
    WEIGHTS :: len(FAR_SIMPLIFY_WEIGHTS)
    positions:=make([]geom.Vec3,len(vertices),scratch)
    attributes:=make([]f32,len(vertices)*WEIGHTS,scratch)
    for v,at in vertices {
        positions[at]=v.position
        n:=mm.normal_unpack(v.normal)
        c:=values[at].color
        copy(attributes[at*WEIGHTS:],[]f32{n.x,n.y,n.z,c.r,c.g,c.b})
    }
    weights:=FAR_SIMPLIFY_WEIGHTS
    dag:geom.Cluster_Dag
    defer geom.cluster_dag_destroy(&dag)
    ranges:=[1]geom.Cluster_Range{{0,u32(len(indices)),0}}
    built:=geom.cluster_dag_build(&dag,{positions=positions,indices=indices[:],ranges=ranges[:],attributes=attributes,attribute_weights=weights[:]},scratch)
    if built!=.None || dag.levels>MESH_MAX_LEVELS {return false}

    // Each cluster of its own vertices, which take the mean of what it covers.
    clusters:=make([dynamic]Cluster_Source,0,len(dag.clusters),scratch)
    cluster_indices:=make([dynamic]u32,0,len(indices),scratch)
    copies:=make([dynamic]Vertex,0,len(vertices),scratch)
    surfaces:=make([dynamic]Surface_Vertex,0,len(vertices),scratch)
    for level in 0..<u32(max(dag.levels,1)) {
        for c in dag.clusters {
            if c.level!=level {continue}
            corners:=dag.triangles[c.first_triangle*3:][:c.triangle_count*3]
            mean:Far_Value
            weight,area_total:f32
            area_mean:Far_Value
            for t in 0..<int(c.triangle_count) {
                k:=[3]u32{dag.vertices[c.first_vertex+u32(corners[t*3])],dag.vertices[c.first_vertex+u32(corners[t*3+1])],dag.vertices[c.first_vertex+u32(corners[t*3+2])]}
                area:=0.5*linalg.length(linalg.cross(positions[k[1]]-positions[k[0]],positions[k[2]]-positions[k[0]]))
                for corner in k {
                    value:=values[corner]
                    covered:=area*value.color.a/3
                    mean_add(&mean,value,covered)
                    mean_add(&area_mean,value,area/3)
                    weight+=covered
                    area_total+=area/3
                }
            }
            // Where nothing covers, what is there counts by its area alone.
            if !(weight>0) {mean,weight=area_mean,area_total}
            if !(weight>0) {
                mean,weight={},1
                for i in 0..<int(c.vertex_count) {mean_add(&mean,values[dag.vertices[c.first_vertex+u32(i)]],1)}
                weight=f32(c.vertex_count)
            }
            mean.color/=weight;mean.roughness/=weight;mean.metallic/=weight;mean.emission/=weight
            color:=mm.rgba8_pack({mean.color.r,mean.color.g,mean.color.b,1})
            surface:=Surface_Vertex{
                material=u32(mm.unorm8_pack(mean.roughness))|u32(mm.unorm8_pack(mean.metallic))<<8,
                emission=mm.rgb9e5_pack(mean.emission),
            }
            source:=Cluster_Source{first_index=u32(len(cluster_indices)),index_count=c.triangle_count*3,level=level,group=c.group,generator=c.generator}
            source.lod={c.own.center.x,c.own.center.y,c.own.center.z,c.own.radius}
            source.parent={c.parent.center.x,c.parent.center.y,c.parent.center.z,c.parent.radius}
            source.error=c.own.error+error
            source.parent_error=c.parent.error if c.parent.error==CLUSTER_ROOT else c.parent.error+error
            first:=u32(len(copies))
            for i in 0..<c.vertex_count {
                v:=vertices[dag.vertices[c.first_vertex+i]]
                v.color=color
                append(&copies,v)
                append(&surfaces,surface)
            }
            for corner in corners {append(&cluster_indices,first+u32(corner))}
            append(&clusters,source)
        }
    }
    source:=Mesh_Source{vertices=copies[:],surfaces=surfaces[:],flags={.Has_Colors}}
    if !mesh_encode(source,clusters[:],cluster_indices[:],out,allocator) {return false}
    mesh_ray_errors(out)
    if out.root_page>0 && !mesh_pages_pack(out,allocator) {
        mesh_geometry_delete(out,allocator)
        return false
    }
    return true
}

@(private="file")
mean_add :: proc "contextless" (mean:^Far_Value,value:Far_Value,weight:f32) {
    mean.color+=value.color*weight
    mean.roughness+=value.roughness*weight
    mean.metallic+=value.metallic*weight
    mean.emission+=value.emission*weight
}
