package importer

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"

// Which assets of a model are parts of its prefab (asset.Header.owner): what
// the content browser shows inside the model. Only what surely is of this
// model alone is a part; anything in doubt is of its own and shows.
//   - Its meshes and skeletons always are.
//   - A material, with its textures, is a part when one mesh of the model uses
//     it, no other import of the project has its textures (compared by their
//     bytes), its UVs fall inside 0..1 where its map places them, the islands
//     they draw over the texture leave room unused and none reaches from an
//     edge to the opposite one (an unwrapped atlas: this region is the handle,
//     that one the door), and its base color, or else its normal map, does not
//     tile at its edges (a repeatable image of which a model uses a corner).
//   - A material without textures, a texture no part uses and the clips are
//     of their own.
// The decision is taken when an asset is written the first time and kept
// after: a reimport does not take it again, so a part taken out of its owner
// stays out. Settings.parts forces it.

Parts :: enum u8 {
    Auto, // as above
    All,  // every material and texture of the model is a part
    None, // only its meshes and skeletons are
}

PARTS_GRID :: 512        // cells per side of the UV coverage of a material
PARTS_MIN_UNUSED :: 0.05 // of the texture its islands leave unused, at least
PARTS_UV_SLACK :: 0.01   // how far out of 0..1 a UV may fall: the bleed of an exporter that crops its atlas
PARTS_SAMPLE :: 512      // pixels per side, at most, the edges of an image are compared on
// An image tiles along an axis when its seam differs no more than this many
// steps between neighboring pixels of its interior...
PARTS_SEAM_STEPS :: 2
// ...and its edges vary along themselves at least this part of a step: a flat
// edge, the padding of an atlas, says nothing.
PARTS_EDGE_CONTENT :: 0.25

@(private)
Verdict :: struct {
    part:bool,
    reason:string,
}

// Whether material m of the model is surely of the model alone. pixels:
// RGBA8 rows of the image its base color shows, or else its normal map;
// shared: one of its textures is the one another import wrote.
@(private)
material_verdict :: proc(model:^Imported_Model,m:int,pixels:[]u8,width,height:int,shared:bool) -> Verdict {
    material:=&model.materials[m]
    textured:=false
    for row in material.images {if row>=0 {textured=true}}
    if !textured {return {false,"it has no textures"}}
    meshes:=0
    for &mesh in model.meshes {
        for slot in mesh.slots {
            if slot.material==m {meshes+=1;break}
        }
    }
    if meshes!=1 {return {false,fmt.tprintf("%d meshes use it",meshes)}}
    if shared {return {false,"another import has its textures"}}
    analyzed:=material_analyzed(material)
    info:=&material.info
    shown:=material_map(info,analyzed)^

    cells:=make([]u8,PARTS_GRID*PARTS_GRID,context.temp_allocator)
    corners:=make(map[[2]i32]i32,context.temp_allocator)
    parents:=make([dynamic]i32,context.temp_allocator)
    places:=make([dynamic][2]f32,context.temp_allocator)
    corner :: proc(corners:^map[[2]i32]i32,parents:^[dynamic]i32,places:^[dynamic][2]f32,uv:[2]f32) -> i32 {
        key:=[2]i32{i32(math.round(uv.x*65536)),i32(math.round(uv.y*65536))}
        if at,found:=corners[key];found {return at}
        at:=i32(len(parents))
        append(parents,at);append(places,uv)
        corners[key]=at
        return at
    }
    root :: proc(parents:[]i32,at:i32) -> i32 {
        at:=at
        for parents[at]!=at {parents[at]=parents[parents[at]];at=parents[at]}
        return at
    }
    for &mesh in model.meshes {
        for submesh in mesh.submeshes {
            if int(submesh.slot)>=len(mesh.slots) || mesh.slots[submesh.slot].material!=m {continue}
            for i:=int(submesh.first_index);i+2<int(submesh.first_index+submesh.index_count);i+=3 {
                uv:[3][2]f32
                at:[3]i32
                for k in 0..<3 {
                    vertex:=mesh.vertices[mesh.indices[i+k]]
                    uv[k]=map_uv(shown,vertex.uv1 if shown.uv_set==1 else vertex.uv)
                    for c in uv[k] {
                        if !(c>=-PARTS_UV_SLACK && c<=1+PARTS_UV_SLACK) {return {false,"its UVs leave 0..1"}}
                    }
                    at[k]=corner(&corners,&parents,&places,uv[k])
                }
                parents[root(parents[:],at[1])]=root(parents[:],at[0])
                parents[root(parents[:],at[2])]=root(parents[:],at[0])
                triangle_cover(cells,uv)
            }
        }
    }
    // An island is the triangles that share corners; one that reaches from an
    // edge to the opposite one wraps around the texture.
    low:=make([][2]f32,len(parents),context.temp_allocator)
    high:=make([][2]f32,len(parents),context.temp_allocator)
    for &l in low {l={2,2}}
    for &h in high {h={-1,-1}}
    for place,at in places {
        top:=root(parents[:],i32(at))
        low[top]=linalg.min(low[top],place)
        high[top]=linalg.max(high[top],place)
    }
    for _,at in places {
        if root(parents[:],i32(at))!=i32(at) {continue}
        across:=low[at].x<=PARTS_UV_SLACK && high[at].x>=1-PARTS_UV_SLACK || low[at].y<=PARTS_UV_SLACK && high[at].y>=1-PARTS_UV_SLACK
        if across {return {false,"an island of its UVs reaches across the texture"}}
    }
    covered:=0
    for cell in cells {covered+=int(cell)}
    unused:=1-f32(covered)/f32(PARTS_GRID*PARTS_GRID)
    if unused<PARTS_MIN_UNUSED {return {false,fmt.tprintf("its UVs cover %.0f%% of the texture",100*(1-unused))}}
    if pixels!=nil && image_tiles(pixels,width,height) {return {false,"its image tiles at its edges"}}
    return {true,fmt.tprintf("UVs inside 0..1, %.0f%% unused, edges do not tile",100*unused)}
}

// Where a UV of a mesh falls on the image of a map, as the renderer places it:
// rotation * (map scale * uv) + map offset.
@(private="file")
map_uv :: proc(shown:asset.Material_Map,uv:[2]f32) -> [2]f32 {
    sine,cosine:=math.sin(shown.rotation),math.cos(shown.rotation)
    p:=uv*shown.scale
    return {cosine*p.x-sine*p.y,sine*p.x+cosine*p.y}+shown.offset
}

// The map whose image tells whether the material repeats: its base color, else
// its normal map, else the first it has.
@(private)
material_analyzed :: proc(material:^Imported_Material) -> asset.Material_Map_Kind {
    if material.images[.Base_Color]>=0 {return .Base_Color}
    if material.images[.Normal]>=0 {return .Normal}
    for row,kind in material.images {if row>=0 {return kind}}
    return .Base_Color
}

// Marks the cells whose centers a triangle in UV space covers, and those of
// its corners: a sliver still takes room.
@(private="file")
triangle_cover :: proc(cells:[]u8,uv:[3][2]f32) {
    p:[3][2]f32
    for k in 0..<3 {
        p[k]=uv[k]*PARTS_GRID
        x,y:=clamp(int(p[k].x),0,PARTS_GRID-1),clamp(int(p[k].y),0,PARTS_GRID-1)
        cells[y*PARTS_GRID+x]=1
    }
    area:=(p[1].x-p[0].x)*(p[2].y-p[0].y)-(p[2].x-p[0].x)*(p[1].y-p[0].y)
    if area==0 {return}
    x0,x1:=max(int(math.floor(min(p[0].x,p[1].x,p[2].x))),0),min(int(math.ceil(max(p[0].x,p[1].x,p[2].x))),PARTS_GRID-1)
    y0,y1:=max(int(math.floor(min(p[0].y,p[1].y,p[2].y))),0),min(int(math.ceil(max(p[0].y,p[1].y,p[2].y))),PARTS_GRID-1)
    for y in y0..=y1 {
        for x in x0..=x1 {
            c:=[2]f32{f32(x)+0.5,f32(y)+0.5}
            w0:=(p[1].x-c.x)*(p[2].y-c.y)-(p[2].x-c.x)*(p[1].y-c.y)
            w1:=(p[2].x-c.x)*(p[0].y-c.y)-(p[0].x-c.x)*(p[2].y-c.y)
            w2:=(p[0].x-c.x)*(p[1].y-c.y)-(p[1].x-c.x)*(p[0].y-c.y)
            if area>0 ? (w0>=0 && w1>=0 && w2>=0) : (w0<=0 && w1<=0 && w2<=0) {cells[y*PARTS_GRID+x]=1}
        }
    }
}

// Whether an image continues across its opposite edges, along either axis: its
// seam differs from its other side no more than its interior does between
// neighbors, and its edges have content of their own. Sampled at most
// PARTS_SAMPLE times per side.
@(private)
image_tiles :: proc(pixels:[]u8,width,height:int) -> bool {
    if width<4 || height<4 || len(pixels)<width*height*4 {return false}
    step_x,step_y:=max(width/PARTS_SAMPLE,1),max(height/PARTS_SAMPLE,1)
    texel :: proc(pixels:[]u8,width,x,y:int) -> [3]f32 {
        at:=(y*width+x)*4
        return {f32(pixels[at]),f32(pixels[at+1]),f32(pixels[at+2])}
    }
    difference :: proc(a,b:[3]f32) -> f32 {return abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z)}
    // The step between neighbors of the interior, across and along each axis.
    across_x,across_y:f32
    count:int
    for y:=0;y+1<height;y+=step_y {
        for x:=0;x+1<width;x+=step_x {
            here:=texel(pixels,width,x,y)
            across_x+=difference(here,texel(pixels,width,x+1,y))
            across_y+=difference(here,texel(pixels,width,x,y+1))
            count+=1
        }
    }
    across_x/=f32(count);across_y/=f32(count)
    seam_x,along_x,seam_y,along_y:f32
    rows,columns:int
    for y:=0;y+1<height;y+=step_y {
        first,last:=texel(pixels,width,0,y),texel(pixels,width,width-1,y)
        seam_x+=difference(first,last)
        along_x+=(difference(first,texel(pixels,width,0,y+1))+difference(last,texel(pixels,width,width-1,y+1)))/2
        rows+=1
    }
    for x:=0;x+1<width;x+=step_x {
        first,last:=texel(pixels,width,x,0),texel(pixels,width,x,height-1)
        seam_y+=difference(first,last)
        along_y+=(difference(first,texel(pixels,width,x+1,0))+difference(last,texel(pixels,width,x+1,height-1)))/2
        columns+=1
    }
    seam_x/=f32(rows);along_x/=f32(rows);seam_y/=f32(columns);along_y/=f32(columns)
    tiles_x:=across_x>0 && along_x>=PARTS_EDGE_CONTENT*across_y && seam_x<=PARTS_SEAM_STEPS*across_x
    tiles_y:=across_y>0 && along_y>=PARTS_EDGE_CONTENT*across_x && seam_y<=PARTS_SEAM_STEPS*across_y
    return tiles_x || tiles_y
}

// The RGBA8 pixels of an image the verdict of a material reads: decoded
// once, and kept in the job for its texture to be built from. None of an
// image the format made with layers or more than 8 bits.
@(private)
job_pixels :: proc(job:^Texture_Job) -> (pixels:[]u8,width,height:int) {
    if job.made.width>0 {
        if job.made.format!=.RGBA8 || job.made.layers>1 {return nil,0,0}
        return job.bytes,job.made.width,job.made.height
    }
    if job.decoded.pixels==nil {
        image,error:=textures.image_decode(job.bytes,context.temp_allocator)
        if error!=.None {return nil,0,0}
        job.decoded=image
    }
    return job.decoded.pixels,job.decoded.width,job.decoded.height
}

// The owner of each part, before anything is written. An asset an earlier
// import wrote keeps the owner it has, unless settings.parts forces it. A new
// material whose textures all are of another import takes the material of the
// project that names those same textures, when its source gave that material
// what this one gives. What this import shares stops being a part of another
// import, with the materials of that import that name it. reasons: why each
// material is or is not a part.
@(private)
parts_own :: proc(w:^Writer,model:^Imported_Model,jobs:[]Texture_Job,parts:[]Part,first_material:int,reasons:[]string) {
    mode:=w.options.settings.parts
    row_part:=make([]int,len(model.images),context.temp_allocator)
    for &at in row_part {at=-1}
    for job,i in jobs {row_part[job.index]=i}
    image_ids:=make([]base.Asset_Id,len(model.images),context.temp_allocator)
    for job,i in jobs {image_ids[job.index]=parts[i].id}
    // Another import of the very file of an image is no other model.
    of_another_model :: proc(w:^Writer,p:^Part) -> bool {
        e:=&w.earlier[p.shared]
        return p.file=="" || !strings.equal_fold(base.text_get(e.info.source[:]),p.file)
    }

    for &material,m in model.materials {
        p:=&parts[first_material+m]
        if p.earlier>=0 {continue}
        ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
        for row in material.images {
            if row<0 {continue}
            at:=row_part[row]
            if at<0 || parts[at].shared<0 {clear(&ids);break}
            if !slice.contains(ids[:],parts[at].id) {append(&ids,parts[at].id)}
        }
        if len(ids)==0 {continue}
        given:=material_given(&material,image_ids)
        for &e,at in w.earlier {
            if e.taken || e.kind!=asset.KIND_MATERIAL || len(e.dependencies)!=len(ids) {continue}
            same:=true
            for id in ids {same&&=slice.contains(e.dependencies,id)}
            if !same || !material_gave(w,&e,given) {continue}
            p.shared,p.id=at,e.id
            break
        }
    }

    for &p in parts {
        switch {
        case p.shared>=0: p.owner=w.earlier[p.shared].owner
        case p.kind==asset.KIND_MESH || p.kind==asset.KIND_SKELETON: p.owner=p.earlier>=0?w.earlier[p.earlier].owner:w.owner
        case p.kind==asset.KIND_ANIMATION: p.owner=p.earlier>=0?w.earlier[p.earlier].owner:{}
        }
    }
    for &material,m in model.materials {
        p:=&parts[first_material+m]
        switch {
        case p.shared>=0:
            reasons[m]=fmt.tprintf("%s, of the project, has its textures",w.earlier[p.shared].path)
        case w.owner=={}:
            p.owner,reasons[m]={},"the model has no prefab"
        case mode==.All:
            p.owner,reasons[m]=w.owner,"the import makes every material a part"
        case mode==.None:
            p.owner,reasons[m]={},"the import makes no material a part"
        case p.earlier>=0:
            p.owner,reasons[m]=w.earlier[p.earlier].owner,"as decided when it was first imported"
        case:
            shared:=false
            for row in material.images {
                if row>=0 && row_part[row]>=0 && parts[row_part[row]].shared>=0 && of_another_model(w,&parts[row_part[row]]) {shared=true}
            }
            pixels:[]u8
            width,height:int
            if row:=material.images[material_analyzed(&material)];row>=0 && row_part[row]>=0 {
                pixels,width,height=job_pixels(&jobs[row_part[row]])
            }
            verdict:=material_verdict(model,m,pixels,width,height,shared)
            p.owner,reasons[m]=verdict.part?w.owner:{},verdict.reason
        }
    }
    for job,i in jobs {
        p:=&parts[i]
        switch {
        case p.shared>=0:
        case mode==.All: p.owner=w.owner
        case mode==.None: p.owner={}
        case p.earlier>=0: p.owner=w.earlier[p.earlier].owner
        case:
            users,owned:=0,0
            for material,m in model.materials {
                uses:=false
                for row in material.images {uses||=row==job.index}
                if !uses {continue}
                users+=1
                if q:=&parts[first_material+m];q.shared<0 && q.owner!={} && q.owner==w.owner {owned+=1}
            }
            p.owner=users>0 && owned==users?w.owner:{}
        }
    }

    for &p in parts {
        if p.shared<0 {continue}
        if e:=&w.earlier[p.shared];e.owner!={} && e.owner!=w.owner {earlier_unpart(w,e)}
    }
}

// Whether the material an earlier import wrote at e got from its source what
// this import gives: its imported layer.
@(private="file")
material_gave :: proc(w:^Writer,e:^Earlier,given:asset.Material_Info) -> bool {
    file:asset.Asset
    if asset.asset_load(&file,e.key,context.temp_allocator)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=asset.material_view(&file,&w.types)
    return error==.None && view.imported!=nil && view.imported^==given
}

// What two imports use is a part of neither: e leaves the asset that owns it,
// and so do the materials of that owner that name it, and the textures that
// then no part of it names.
@(private="file")
earlier_unpart :: proc(w:^Writer,e:^Earlier) {
    owner:=e.owner
    if asset.file_owner_set(e.key,{})!=.None {
        writer_warn(w,"%s is shared with %s but it could not be taken out of the asset it is a part of",e.path,w.named)
        return
    }
    e.owner={}
    append(&w.report.others,strings.clone(e.path,w.allocator))
    writer_warn(w,"%s is shared with %s: it is no longer a part of another import",e.path,w.named)
    for &other in w.earlier {
        if other.owner!=owner {continue}
        switch {
        case e.kind==asset.KIND_TEXTURE && other.kind==asset.KIND_MATERIAL && slice.contains(other.dependencies,e.id):
            earlier_unpart(w,&other)
        case e.kind==asset.KIND_MATERIAL && other.kind==asset.KIND_TEXTURE && slice.contains(e.dependencies,other.id):
            named:=false
            for &material in w.earlier {
                if material.kind==asset.KIND_MATERIAL && material.owner==owner && slice.contains(material.dependencies,other.id) {named=true}
            }
            if !named {earlier_unpart(w,&other)}
        }
    }
}
