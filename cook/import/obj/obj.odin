package obj

import "core:math"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"
import mm "mirai:std/math"

// OBJ with its MTL files: vertices, normals, texture coordinates, objects and
// groups, polygons of any size, vertex colors, and the materials faces use.
// The file says nothing of its units or axes: meters and +Y up, as Blender
// writes it, with v from the bottom of the image.

FORMAT :: importer.Format{
    name="OBJ",
    extensions={0=".obj"},
    version=0,
    space={meters_per_unit=1,axes=importer.FACING_PLUS_Z,v_origin=.Bottom},
    sniff=sniff,
    read=read,
}

// Nothing starts an OBJ: a file named .obj is read as one.
sniff :: proc(head:[]u8) -> importer.Sniff {return .Extension}

@(private="file")
Obj_Material :: struct {
    info:asset.Material_Info,
    paths:[asset.Material_Map_Kind]string,
    row:int,
}

@(private="file")
split_fields :: proc(line:string,out:^[dynamic]string) {
    clear(out)
    s:=line
    for {
        i:=0
        for i<len(s) && (s[i]==' ' || s[i]=='\t' || s[i]=='\r') {i+=1}
        if i==len(s) {return}
        j:=i
        for j<len(s) && !(s[j]==' ' || s[j]=='\t' || s[j]=='\r') {j+=1}
        append(out,s[i:j])
        s=s[j:]
    }
}

// What follows a statement keyword, trimmed: names may hold spaces.
@(private="file")
rest_of :: proc(line,keyword:string) -> string {
    return strings.trim_space(strings.trim_prefix(strings.trim_space(line),keyword))
}

// The image of a map statement: what follows its options (-bm 1, -s 1 1 1...),
// as a path next to the MTL file. bump is the value of -bm, 1 without it.
@(private="file")
obj_map :: proc(fields:[]string) -> (name:string,bump:f32) {
    bump=1
    i:=1
    for i<len(fields) && strings.has_prefix(fields[i],"-") {
        option:=fields[i]
        i+=1
        arguments:=1
        switch option {
        case "-s","-o","-t": arguments=3
        case "-mm": arguments=2
        }
        for _ in 0..<arguments {
            if i>=len(fields) {break}
            value,is_number:=strconv.parse_f32(fields[i])
            if arguments>1 && !is_number {break}
            if option=="-bm" && is_number {bump=value}
            i+=1
        }
    }
    if i>=len(fields) {return "",bump}
    return strings.join(fields[i:]," ",context.temp_allocator),bump
}

@(private="file")
read_mtl :: proc(r:^importer.Reader,path:string,materials:^map[string]Obj_Material) {
    if importer.unsafe_path(path) {importer.warn(r,"the material library %s is a device, not a file",path);return}
    bytes,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {importer.warn(r,"the material library %s could not be read",path);return}
    current:string
    explicit_roughness:=false
    fields:[dynamic]string
    fields.allocator=context.temp_allocator
    text:=string(bytes)
    for line in strings.split_lines_iterator(&text) {
        split_fields(line,&fields)
        if len(fields)==0 || strings.has_prefix(fields[0],"#") {continue}
        if fields[0]=="newmtl" && len(fields)>=2 {
            current=strings.clone(rest_of(line,"newmtl"),context.temp_allocator)
            info:=asset.MATERIAL_DEFAULTS
            info.base_color={0.8,0.8,0.8}
            materials[current]=Obj_Material{info=info,row=-1}
            explicit_roughness=false
            continue
        }
        if current=="" || len(fields)<2 {continue}
        m:=materials[current]
        switch fields[0] {
        case "Kd","Ke":
            if len(fields)<4 {continue}
            x,ox:=strconv.parse_f32(fields[1]);y,oy:=strconv.parse_f32(fields[2]);z,oz:=strconv.parse_f32(fields[3])
            if !ox || !oy || !oz || !importer.finite3({x,y,z}) {continue}
            if fields[0]=="Kd" {m.info.base_color={clamp(x,0,1),clamp(y,0,1),clamp(z,0,1)}} else {m.info.emission={max(x,0),max(y,0),max(z,0)}}
        case "Pr","Pm":
            n,ok:=strconv.parse_f32(fields[1])
            if !ok || n-n!=0 {continue}
            if fields[0]=="Pr" {m.info.roughness=clamp(n,0,1);explicit_roughness=true} else {m.info.metallic=clamp(n,0,1)}
        case "d","Tr":
            n,ok:=strconv.parse_f32(fields[1])
            if !ok || n-n!=0 {continue}
            m.info.opacity=clamp(n if fields[0]=="d" else 1-n,0,1)
            if m.info.opacity<1 {m.info.alpha_mode=.Blend}
        case "Ns":
            // Blender writes Ns = 1000 * (1 - roughness)^2 for the materials it exports without Pr.
            n,ok:=strconv.parse_f32(fields[1])
            if ok && n-n==0 && !explicit_roughness {m.info.roughness=1-math.sqrt(clamp(n/1000,0,1))}
        case "map_Kd":
            name,_:=obj_map(fields[:])
            m.paths[.Base_Color]=strings.clone(name,context.temp_allocator)
        case "map_Ke":
            name,_:=obj_map(fields[:])
            m.paths[.Emission]=strings.clone(name,context.temp_allocator)
        case "norm","map_Bump","map_bump","bump":
            name,bump:=obj_map(fields[:])
            m.paths[.Normal]=strings.clone(name,context.temp_allocator)
            m.info.normal_scale=clamp(bump,-16,16)
        }
        materials[current]=m
    }
}

@(private="file")
obj_material_row :: proc(r:^importer.Reader,materials:^map[string]Obj_Material,name,directory:string) -> int {
    m,known:=materials[name]
    if !known {return -1}
    if m.row>=0 {return m.row}
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    for path,slot in m.paths {
        if path=="" {continue}
        joined,_:=filepath.join({directory,path},context.temp_allocator)
        images[slot]=importer.image_file(r,joined,slot==.Base_Color || slot==.Emission,slot==.Normal)
    }
    m.row=importer.material_add(r,name,len(r.materials),m.info,images)
    materials[name]=m
    return m.row
}

@(private="file")
Obj_State :: struct {
    points:[dynamic][3]f32,
    colors:[dynamic]u32,
    uvs:[dynamic][2]f32,
    normals:[dynamic][3]f32,
    corners_point:[dynamic]int,
    corners_uv:[dynamic]int,
    corners_normal:[dynamic]int,
    polygon:[dynamic][3]f32,
    triangles:[dynamic][3]int,
    scratch2:[dynamic][2]f32,
    result:[dynamic]u32,
    fields:[dynamic]string,
    slot_of:map[string]int,
}

read :: proc(r:^importer.Reader,bytes:[]u8) -> bool {
    s:Obj_State
    s.points.allocator=context.temp_allocator;s.colors.allocator=context.temp_allocator;s.uvs.allocator=context.temp_allocator;s.normals.allocator=context.temp_allocator
    s.corners_point.allocator=context.temp_allocator;s.corners_uv.allocator=context.temp_allocator;s.corners_normal.allocator=context.temp_allocator
    s.polygon.allocator=context.temp_allocator;s.triangles.allocator=context.temp_allocator;s.scratch2.allocator=context.temp_allocator;s.result.allocator=context.temp_allocator
    s.fields.allocator=context.temp_allocator;s.slot_of.allocator=context.temp_allocator
    materials:=make(map[string]Obj_Material,context.temp_allocator)
    name:=r.stem
    current:string
    builder:importer.Mesh_Builder
    importer.builder_init(&builder,r)
    flush :: proc(r:^importer.Reader,builder:^importer.Mesh_Builder,name:string,s:^Obj_State) {
        if importer.builder_triangles(builder)>0 {
            mesh:=importer.builder_finish(builder,name)
            row:=importer.mesh_add(r,mesh)
            append(&r.nodes,importer.Imported_Node{name=r.meshes[row].name,parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=row,visible=true})
        }
        importer.builder_init(builder,r)
        clear(&s.slot_of)
    }
    // An OBJ index counts from 1, or back from the end when negative.
    resolve :: proc(r:^importer.Reader,text:string,count:int,what:string,line:int) -> (index:int,ok:bool) {
        value,parsed:=strconv.parse_i64(text)
        if !parsed || value==0 {return -1,importer.fail(r,.Malformed,"OBJ line %d: invalid %s index",line,what)}
        index=int(value)-1 if value>0 else count+int(value)
        if index<0 || index>=count {return -1,importer.fail(r,.Malformed,"OBJ line %d: %s index outside its array",line,what)}
        return index,true
    }
    text:=string(bytes)
    line_number:=0
    for line in strings.split_lines_iterator(&text) {
        line_number+=1
        split_fields(line,&s.fields)
        fields:=s.fields[:]
        if len(fields)==0 || strings.has_prefix(fields[0],"#") {continue}
        switch fields[0] {
        case "v":
            if len(fields)<4 {return importer.fail(r,.Malformed,"OBJ line %d: a vertex needs x, y and z",line_number)}
            x,ox:=strconv.parse_f32(fields[1]);y,oy:=strconv.parse_f32(fields[2]);z,oz:=strconv.parse_f32(fields[3])
            if !ox || !oy || !oz || !importer.finite3({x,y,z}) {return importer.fail(r,.Malformed,"OBJ line %d: invalid vertex number",line_number)}
            append(&s.points,[3]f32{x,y,z})
            color:=importer.WHITE
            if len(fields)>=7 {
                cr,ro:=strconv.parse_f32(fields[4]);cg,go:=strconv.parse_f32(fields[5]);cb,bo:=strconv.parse_f32(fields[6])
                if ro && go && bo {color=importer.pack_color({cr,cg,cb,1})}
            }
            append(&s.colors,color)
        case "vt":
            if len(fields)<3 {return importer.fail(r,.Malformed,"OBJ line %d: a texture coordinate needs u and v",line_number)}
            u,ou:=strconv.parse_f32(fields[1]);v,ov:=strconv.parse_f32(fields[2])
            if !ou || !ov || u-u!=0 || v-v!=0 {return importer.fail(r,.Malformed,"OBJ line %d: invalid texture coordinate",line_number)}
            append(&s.uvs,[2]f32{u,v})
        case "vn":
            if len(fields)<4 {return importer.fail(r,.Malformed,"OBJ line %d: a normal needs x, y and z",line_number)}
            x,ox:=strconv.parse_f32(fields[1]);y,oy:=strconv.parse_f32(fields[2]);z,oz:=strconv.parse_f32(fields[3])
            if !ox || !oy || !oz || !importer.finite3({x,y,z}) {return importer.fail(r,.Malformed,"OBJ line %d: invalid normal",line_number)}
            append(&s.normals,[3]f32{x,y,z})
        case "o","g":
            if len(fields)>1 {
                if importer.builder_triangles(&builder)>0 {flush(r,&builder,name,&s)}
                name=strings.clone(rest_of(line,fields[0]),context.temp_allocator)
            }
        case "mtllib":
            for file in fields[1:] {
                path,_:=filepath.join({r.directory,file},context.temp_allocator)
                read_mtl(r,path,&materials)
            }
        case "usemtl":
            current=strings.clone(rest_of(line,"usemtl"),context.temp_allocator)
        case "f":
            clear(&s.corners_point);clear(&s.corners_uv);clear(&s.corners_normal);clear(&s.polygon)
            for field in fields[1:] {
                if strings.has_prefix(field,"#") {break}
                first:=strings.index_byte(field,'/')
                head:=field if first<0 else field[:first]
                tail:=""
                if first>=0 {tail=field[first+1:]}
                index,ok:=resolve(r,head,len(s.points),"vertex",line_number)
                if !ok {return false}
                uv_index,normal_index:=-1,-1
                if tail!="" {
                    second:=strings.index_byte(tail,'/')
                    uv_text:=tail if second<0 else tail[:second]
                    if uv_text!="" {
                        uv_index,ok=resolve(r,uv_text,len(s.uvs),"texture coordinate",line_number)
                        if !ok {return false}
                    }
                    if second>=0 && tail[second+1:]!="" {
                        normal_index,ok=resolve(r,tail[second+1:],len(s.normals),"normal",line_number)
                        if !ok {return false}
                    }
                }
                append(&s.corners_point,index);append(&s.corners_uv,uv_index);append(&s.corners_normal,normal_index)
                append(&s.polygon,s.points[index])
            }
            if len(s.polygon)<3 {return importer.fail(r,.Malformed,"OBJ line %d: a face has fewer than three vertices",line_number)}
            clear(&s.triangles)
            if !importer.polygon_triangulate(r,s.polygon[:],&s.triangles,&s.scratch2,&s.result) {
                r.degenerate+=1
                continue
            }
            row:=obj_material_row(r,&materials,current,r.directory)
            slot,slot_known:=s.slot_of[current]
            if !slot_known {
                ok:bool
                slot,ok=importer.builder_slot(&builder,u32(len(builder.slots)+1),current,row)
                if !ok {return false}
                s.slot_of[current]=slot
            }
            for triangle in s.triangles {
                corners:[3]importer.Corner
                flat:=importer.face_normal(s.polygon[triangle[0]],s.polygon[triangle[1]],s.polygon[triangle[2]],importer.polygon_normal(s.polygon[:]))
                for corner,k in triangle {
                    normal:=flat
                    if n:=s.corners_normal[corner];n>=0 {normal=importer.normal_of(s.normals[n],flat)}
                    corners[k]={position=s.polygon[corner],normal=normal,color=s.colors[s.corners_point[corner]]}
                    if u:=s.corners_uv[corner];u>=0 {corners[k].uv,corners[k].has_uv=s.uvs[u],true}
                }
                importer.builder_triangle(&builder,slot,corners)
            }
        }
    }
    flush(r,&builder,name,&s)
    if r.degenerate>0 {importer.warn(r,"%d faces without area were skipped",r.degenerate)}
    return true
}
