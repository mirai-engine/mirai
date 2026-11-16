package importer

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// The masked cards of a model cut to the outlines of their masks once it is
// read (outline.odin): leaves drawn opaque instead of alpha tested.
//
// A card is a small island (levels.odin) of a submesh of islands of a static
// mesh whose material is masked: no program, its base color image read by a
// map that keeps the card inside it, every corner of the card opaque in its
// color, and its triangles laid on that image without folding over each
// other. The texels the mask keeps are those of the rectangle the card
// covers whose alpha, times the opacity of the material, reaches its cutoff;
// cards that cover the same rectangle of the same image share their outlines.
//
// A card of a leaf (Outline_Ladder.leaf) is drawn as the finest outline of
// its ladder in level 0, and its coarser outlines go to Mesh_Outlines, which the levels
// take as their error allows. A card of a cluster of leaves keeps its mask on
// its convex outline. An outline is laid on the card through its triangles:
// the triangles that share one affine map from the image to the mesh (a flat
// quad) are one facet, the outline is cut by each facet and each of its
// corners takes the attributes the card has there, so a bent card stays bent.
// A card whose rectangle keeps no texel draws nothing and is dropped.
//
// A material whose triangles are all cut to outlines becomes opaque; one
// that also keeps masked triangles stays as it is, and the outlines take an
// opaque copy of it in a slot of their own. Either way what the outlines draw
// is a sheet seen from both sides (two_sided), and the base color image of an
// opaque one fills what the mask left empty (Build_Options.alpha_fill), so the
// edge of an outline shows the color of the leaf.

// The triangles of level 0 of a mesh that are cards drawn as outlines, and
// the coarser outlines of each that its levels take in their place.
Mesh_Outlines :: struct {
    cards:[]Outline_Card,
    rungs:[]Outline_Rung,     // OUTLINE_RUNGS-1 of each card, after the outline level 0 draws, the finest first
    vertices:[]asset.Vertex,  // of the rungs
    indices:[]u32,            // of the rungs, into vertices
}

Outline_Card :: struct {
    first_triangle,triangle_count:u32, // of level 0: the outline it draws, one island
    error:f32, // of that outline, in the units of the mesh
}

Outline_Rung :: struct {
    first_index,index_count:u32,
    error:f32, // in the units of the mesh: how far it draws past what the mask keeps
}

// The slot of the outlines of a slot whose material also keeps masked triangles.
CUTOUT_SLOT :: u32(1)<<31

@(private="file")
Cutout_Material :: struct {
    eligible:bool,
    image:int,
    threshold:f32, // of the alpha of the image
    linear:[4]f32,  // the map of the image: linear·uv + offset
    offset:[2]f32,
    uv_set:u32,
    outlined,masked:int, // triangles cut to outlines, and those that keep the mask
    cut:bool,            // some card of it was cut
    opaque:int,          // the row of the material outlines are drawn with
}

@(private="file")
Cutout_Alpha :: struct {
    alpha:[]f32,
    width,height:int,
    state:enum u8 {Unread,Read,Failed},
}

@(private="file")
Cutout_Shape :: struct {
    image:int,
    threshold:f32,
    rect:[4]int, // x0,y0,x1,y1 in texels
}

// A corner of a placed outline: the triangle of the card it lies on and its weights there.
@(private="file")
Cutout_Point :: struct {
    triangle:u32,
    weights:[3]f32,
}

@(private="file")
Cutout_Placed :: struct {
    points:[]Cutout_Point,
    indices:[]u32,
}

// The triangles of a card on the rectangle of its shape, its facets and its outlines laid on them.
@(private="file")
Cutout_Layout :: struct {
    shape:int,
    corners:[][3]geom.Vec2, // of each triangle, in texels of the rectangle
    facets:[]u32,           // of each triangle
    flip:bool,              // its triangles turn the other way on the image than in the mesh
    valid:bool,
    rungs:[OUTLINE_RUNGS]Cutout_Placed, // of a leaf
    hull:Cutout_Placed,
}

@(private="file")
Cutout_Card :: struct {
    mesh,submesh:int,
    triangles:[]u32, // of the mesh
    layout:int,      // -1: it keeps no texel, and is dropped
    leaf:bool,
    scale:f32,       // the most a texel of the image spans on the card, in the units of the mesh
}

@(private="file")
Cutout :: struct {
    r:^Reader,
    materials:[]Cutout_Material,
    alphas:[]Cutout_Alpha,
    shapes:map[Cutout_Shape]int,
    ladders:[dynamic]Outline_Ladder,
    layout_keys:map[u64]int,
    layouts:[dynamic]Cutout_Layout,
    cards:[dynamic]Cutout_Card,
}

// Cuts the masked cards of the meshes of r to their outlines (see above).
@(private)
model_cutouts :: proc(r:^Reader) {
    c:=Cutout{r=r}
    c.materials=make([]Cutout_Material,len(r.materials),context.temp_allocator)
    any:=false
    for &m,i in r.materials {
        info:=&m.info
        image:=m.images[.Base_Color]
        mapping:=info.maps.base_color
        if info.alpha_mode!=.Mask || info.program[0]!=0 || image<0 || !(info.opacity>0) || len(m.parameters)>0 {continue}
        threshold:=info.alpha_cutoff/info.opacity
        if !(threshold>0 && threshold<=1) {continue}
        sine,cosine:=math.sin(mapping.rotation),math.cos(mapping.rotation)
        c.materials[i]={
            eligible=true,image=image,threshold=threshold,uv_set=mapping.uv_set,offset=mapping.offset,opaque=i,
            linear={cosine*mapping.scale.x,-sine*mapping.scale.y,sine*mapping.scale.x,cosine*mapping.scale.y},
        }
        any=true
    }
    if !any {return}
    c.alphas=make([]Cutout_Alpha,len(r.images),context.temp_allocator)
    c.shapes.allocator=context.temp_allocator
    c.ladders.allocator=context.temp_allocator
    c.layout_keys.allocator=context.temp_allocator
    c.layouts.allocator=context.temp_allocator
    c.cards.allocator=context.temp_allocator
    for &mesh,at in r.meshes {cutout_mesh(&c,&mesh,at)}
    if len(c.cards)==0 {return}
    // A material whose triangles all became outlines is opaque; one that keeps masked ones lends a copy.
    for &m,i in c.materials {
        if !m.cut {continue}
        r.materials[i].info.two_sided=true
        if m.outlined==0 {continue}
        if m.masked==0 {
            r.materials[i].info.alpha_mode=.Opaque
        } else {
            copy:=r.materials[i]
            copy.info.alpha_mode=.Opaque
            m.opaque=material_add(r,fmt.tprintf("%s outline",copy.name),len(r.materials),copy.info,copy.images)
            r.materials[m.opaque].parameters=copy.parameters
            r.materials[m.opaque].parameter_images=copy.parameter_images
        }
        image:=&r.images[m.image]
        if image.alpha_fill==0 || m.threshold<image.alpha_fill {image.alpha_fill=m.threshold}
    }
    for &mesh,at in r.meshes {cutout_rebuild(&c,&mesh,at)}
}

// The cards of a mesh, appended to c.cards, and what of each material it cuts and keeps masked.
@(private="file")
cutout_mesh :: proc(c:^Cutout,mesh:^Imported_Mesh,mesh_index:int) {
    static:=len(mesh.skin)==0 && len(mesh.morphs)==0
    positions:=make([]geom.Vec3,len(mesh.vertices),context.temp_allocator)
    for v,i in mesh.vertices {positions[i]=v.position}
    for sub,s in mesh.submeshes {
        if int(sub.slot)>=len(mesh.slots) {continue}
        material:=mesh.slots[sub.slot].material
        if material<0 || material>=len(c.materials) || !c.materials[material].eligible {continue}
        m:=&c.materials[material]
        triangles:=int(sub.index_count/3)
        indices:=mesh.indices[sub.first_index:][:sub.index_count]
        labels:=make([]u32,triangles,context.temp_allocator)
        count:=geom.mesh_components(positions,indices,labels) if static else 0
        sizes:=make([]u32,count,context.temp_allocator)
        for l in labels {if int(l)<count {sizes[l]+=1}}
        small:=0
        for size in sizes {if island_small(size,u32(triangles)) {small+=1}}
        if small<ISLANDS_MIN {
            m.masked+=triangles
            continue
        }
        // The triangles of each small island, in the order of their first.
        first:=make([]u32,count+1,context.temp_allocator)
        for l in labels {if int(l)<count {first[l+1]+=1}}
        for k in 1..=count {first[k]+=first[k-1]}
        order:=make([]u32,first[count],context.temp_allocator)
        fill:=make([]u32,count,context.temp_allocator)
        for l,t in labels {
            if int(l)>=count {continue}
            order[first[l]+fill[l]]=sub.first_index/3+u32(t)
            fill[l]+=1
        }
        seen:=make([]bool,count,context.temp_allocator)
        kept:=triangles
        for l in labels {
            if int(l)>=count || seen[l] || !island_small(sizes[l],u32(triangles)) {continue}
            seen[l]=true
            card,ok:=cutout_card(c,mesh,m,order[first[l]:first[l+1]])
            if !ok {continue}
            card.mesh,card.submesh=mesh_index,s
            append(&c.cards,card)
            kept-=len(card.triangles)
            m.cut=true
            if card.leaf && card.layout>=0 {m.outlined+=len(card.triangles)}
        }
        m.masked+=kept
        // A cluster card keeps its mask on its convex outline.
        for card in c.cards {
            if card.mesh==mesh_index && card.submesh==s && !card.leaf && card.layout>=0 {m.masked+=len(card.triangles)}
        }
    }
}

// The card of an island of a mesh with the masked material m, if it is one.
@(private="file")
cutout_card :: proc(c:^Cutout,mesh:^Imported_Mesh,m:^Cutout_Material,triangles:[]u32) -> (card:Cutout_Card,ok:bool) {
    alpha:=cutout_alpha(c,m.image) or_return
    w,h:=f32(alpha.width),f32(alpha.height)
    count:=len(triangles)
    corners:=make([][3]geom.Vec2,count,context.temp_allocator)
    low,high:=geom.Vec2{max(f32),max(f32)},geom.Vec2{-max(f32),-max(f32)}
    sign:f64
    for triangle,t in triangles {
        for k in 0..<3 {
            v:=mesh.vertices[mesh.indices[triangle*3+u32(k)]]
            if v.color>>24!=255 {return}
            uv:=v.uv1 if m.uv_set==1 else v.uv
            mapped:=geom.Vec2{m.linear.x*uv.x+m.linear.y*uv.y+m.offset.x,m.linear.z*uv.x+m.linear.w*uv.y+m.offset.y}
            if !(mapped.x>=-1e-3 && mapped.x<=1+1e-3 && mapped.y>=-1e-3 && mapped.y<=1+1e-3) {return}
            p:=geom.Vec2{mapped.x*w,mapped.y*h}
            corners[t][k]=p
            low,high={min(low.x,p.x),min(low.y,p.y)},{max(high.x,p.x),max(high.y,p.y)}
        }
        area:=orient(corners[t][0],corners[t][1],corners[t][2])
        if !(abs(area)>1e-9) || sign!=0 && (area>0)!=(sign>0) {return}
        sign=area
    }
    rect:=[4]int{
        clamp(int(math.floor(low.x)),0,alpha.width),clamp(int(math.floor(low.y)),0,alpha.height),
        clamp(int(math.ceil(high.x)),0,alpha.width),clamp(int(math.ceil(high.y)),0,alpha.height),
    }
    if rect[2]<=rect[0] || rect[3]<=rect[1] {return}
    for &tri in corners {
        for &p in tri {p-={f32(rect[0]),f32(rect[1])}}
    }
    // The most a texel spans on the card, and the triangles that share one map from the image.
    for triangle,t in triangles {
        e1,e2:=corners[t][1]-corners[t][0],corners[t][2]-corners[t][0]
        p0:=mesh.vertices[mesh.indices[triangle*3]].position
        f1:=mesh.vertices[mesh.indices[triangle*3+1]].position-p0
        f2:=mesh.vertices[mesh.indices[triangle*3+2]].position-p0
        det:=f64(e1.x)*f64(e2.y)-f64(e1.y)*f64(e2.x)
        // The columns of the map from texels to the mesh: along x and along y.
        jx:=([3]f64{f64(f1.x),f64(f1.y),f64(f1.z)}*f64(e2.y)-[3]f64{f64(f2.x),f64(f2.y),f64(f2.z)}*f64(e1.y))/det
        jy:=([3]f64{f64(f2.x),f64(f2.y),f64(f2.z)}*f64(e1.x)-[3]f64{f64(f1.x),f64(f1.y),f64(f1.z)}*f64(e2.x))/det
        a,b,d:=jx.x*jx.x+jx.y*jx.y+jx.z*jx.z,jx.x*jy.x+jx.y*jy.y+jx.z*jy.z,jy.x*jy.x+jy.y*jy.y+jy.z*jy.z
        card.scale=max(card.scale,f32(math.sqrt(0.5*(a+d)+math.sqrt(0.25*(a-d)*(a-d)+b*b))))
    }
    facets:=cutout_facets(mesh,triangles,corners)
    shape:=Cutout_Shape{m.image,m.threshold,rect}
    ladder,found:=c.shapes[shape]
    if !found {
        rw,rh:=rect[2]-rect[0],rect[3]-rect[1]
        covered:=make([]bool,rw*rh,context.temp_allocator)
        for y in 0..<rh {
            for x in 0..<rw {covered[y*rw+x]=alpha.alpha[(rect[1]+y)*alpha.width+rect[0]+x]>=m.threshold}
        }
        made,made_ok:=outline_ladder({covered,rw,rh},context.temp_allocator)
        ladder=-1
        if made_ok {
            ladder=len(c.ladders)
            append(&c.ladders,made)
        }
        c.shapes[shape]=ladder
    }
    card.triangles=triangles
    card.layout=-1
    if ladder<0 {return card,true}
    card.leaf=c.ladders[ladder].leaf
    card.layout=cutout_layout(c,ladder,corners,facets,sign<0)
    return card,c.layouts[card.layout].valid
}

// The alpha of image, read once; false where it cannot be.
@(private="file")
cutout_alpha :: proc(c:^Cutout,image:int) -> (alpha:^Cutout_Alpha,ok:bool) {
    alpha=&c.alphas[image]
    switch alpha.state {
    case .Read: return alpha,true
    case .Failed: return alpha,false
    case .Unread:
    }
    alpha.state=.Failed
    from:=c.r.images[image]
    bytes,made,read:=image_bytes(from)
    if !read {return alpha,false}
    source:textures.Source
    switch {
    case from.make!=nil:
        source=from.make(bytes,context.temp_allocator) or_return
    case made.width>0:
        source=made
    case:
        error:textures.Error
        source,error=textures.source_decode(bytes,context.temp_allocator)
        if error!=.None {return alpha,false}
    }
    cells:=source.width*source.height
    if cells<=0 || len(source.texels)<textures.source_bytes(source) {return alpha,false}
    alpha.alpha=make([]f32,cells,context.temp_allocator)
    linear:=textures.transfer_make(false)
    for &a,at in alpha.alpha {a=textures.texel_read(source.texels,source.format,at,&linear).a}
    alpha.width,alpha.height,alpha.state=source.width,source.height,.Read
    return alpha,true
}

// The facet of each triangle of a card: those that share an edge and one
// affine map from the image to the mesh are one.
@(private="file")
cutout_facets :: proc(mesh:^Imported_Mesh,triangles:[]u32,corners:[][3]geom.Vec2) -> []u32 {
    count:=len(triangles)
    parent:=make([]u32,count,context.temp_allocator)
    for &p,i in parent {p=u32(i)}
    find :: proc(parent:[]u32,i:u32) -> u32 {
        i:=i
        for parent[i]!=i {i=parent[i]}
        return i
    }
    extent:f32
    for triangle in triangles {
        p0:=mesh.vertices[mesh.indices[triangle*3]].position
        for k in 1..<3 {
            d:=mesh.vertices[mesh.indices[triangle*3+u32(k)]].position-p0
            extent=max(extent,math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z))
        }
    }
    for a in 0..<count {
        for b in a+1..<count {
            // An edge of both, the same two points of the image, and the corner of b off it.
            shared,other:=0,-1
            for k in 0..<3 {
                hit:=false
                for j in 0..<3 {if corners[b][k]==corners[a][j] {hit=true}}
                if hit {shared+=1} else {other=k}
            }
            if shared!=2 || other<0 {continue}
            // Where the map of a puts the corner of b, against where it is.
            w:=barycentric(corners[a],corners[b][other])
            predicted:geom.Vec3
            for k in 0..<3 {predicted+=mesh.vertices[mesh.indices[triangles[a]*3+u32(k)]].position*w[k]}
            d:=predicted-mesh.vertices[mesh.indices[triangles[b]*3+u32(other)]].position
            if math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)>1e-4*extent {continue}
            parent[find(parent,u32(b))]=find(parent,u32(a))
        }
    }
    facets:=make([]u32,count,context.temp_allocator)
    for &f,i in facets {f=find(parent,u32(i))}
    return facets
}

// The weights of p in a triangle, which add up to one; outside it, some are negative.
@(private="file")
barycentric :: proc "contextless" (t:[3]geom.Vec2,p:geom.Vec2) -> (w:[3]f32) {
    area:=orient(t[0],t[1],t[2])
    if area==0 {return {1,0,0}}
    w={f32(orient(t[1],t[2],p)/area),f32(orient(t[2],t[0],p)/area),0}
    w[2]=1-w[0]-w[1]
    return
}

// The layout of a card on a shape, made once for cards that lie alike.
@(private="file")
cutout_layout :: proc(c:^Cutout,ladder:int,corners:[][3]geom.Vec2,facets:[]u32,flip:bool) -> int {
    key:=base.hash_combine(u64(ladder),base.hash64(mem.slice_to_bytes(corners)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(facets)))
    if at,found:=c.layout_keys[key];found {
        l:=c.layouts[at]
        if slice.equal(l.corners,corners) && slice.equal(l.facets,facets) {return at}
    }
    layout:=Cutout_Layout{shape=ladder,corners=corners,facets=facets,flip=flip}
    // The polygon of each facet: the union of its triangles, each added beside those before.
    facet_sets:=make([dynamic]geom.Polygon_Set,context.temp_allocator)
    facet_of:=make([dynamic]u32,context.temp_allocator)
    total,covered:f64
    for &tri in corners {total+=abs(orient(tri[0],tri[1],tri[2]))*0.5}
    layout.valid=true
    for f,first in facets {
        if u32(first)!=f {continue}
        set:geom.Polygon_Set
        geom.polygon_set_init(&set,context.temp_allocator)
        added:=make([]bool,len(corners),context.temp_allocator)
        for {
            grew:=false
            for g,t in facets {
                if g!=f || added[t] {continue}
                tri:=corners[t]
                if orient(tri[0],tri[1],tri[2])<0 {tri[1],tri[2]=tri[2],tri[1]}
                if len(set.points)==0 {
                    append(&set.points,..tri[:])
                    append(&set.loop_sizes,3)
                    append(&set.polygon_loops,1)
                } else {
                    joined:=false
                    for p in tri {
                        for q in set.points {if p==q {joined=true}}
                    }
                    if !joined {continue}
                    out:geom.Polygon_Set
                    geom.polygon_set_init(&out,context.temp_allocator)
                    if geom.polygon_boolean(set.points[:],set.loop_sizes[:],tri[:],{3},.Union,&out)!=.None || len(out.polygon_loops)!=1 {
                        layout.valid=false
                        break
                    }
                    set=out
                }
                added[t]=true
                grew=true
            }
            if !grew || !layout.valid {break}
        }
        for a,t in added {if !a && facets[t]==f {layout.valid=false}}
        if !layout.valid {break}
        for size,k in set.loop_sizes {
            first_point:=0
            for s in set.loop_sizes[:k] {first_point+=s}
            covered+=loop_area(set.points[first_point:][:size])
        }
        append(&facet_sets,set)
        append(&facet_of,f)
    }
    // Triangles that fold over each other cover less than they add up to.
    if layout.valid && abs(covered-total)>1e-3*total {layout.valid=false}
    if layout.valid {
        // Its facets apart, the card covers what its triangles add up to only if they do not overlap.
        all:geom.Polygon_Set
        geom.polygon_set_init(&all,context.temp_allocator)
        for a,i in facet_sets {
            for b in facet_sets[i+1:] {
                if geom.polygon_boolean(a.points[:],a.loop_sizes[:],b.points[:],b.loop_sizes[:],.Intersection,&all)!=.None {layout.valid=false}
                area:f64
                at:=0
                for size in all.loop_sizes {area+=loop_area(all.points[at:][:size]);at+=size}
                if area>1e-3*total {layout.valid=false}
            }
        }
    }
    if layout.valid {
        outlines:=&c.ladders[ladder]
        if outlines.leaf {
            for &rung,k in outlines.rungs {
                if k>0 && rung.triangles==outlines.rungs[k-1].triangles && rung.area==outlines.rungs[k-1].area && rung.error==outlines.rungs[k-1].error {
                    layout.rungs[k]=layout.rungs[k-1]
                    continue
                }
                layout.rungs[k]=cutout_place(rung.set,corners,facets,facet_sets[:],facet_of[:])
            }
        } else {
            layout.hull=cutout_place(outlines.hull.set,corners,facets,facet_sets[:],facet_of[:])
        }
    }
    append(&c.layouts,layout)
    c.layout_keys[key]=len(c.layouts)-1
    return len(c.layouts)-1
}

// An outline cut by each facet of a card and triangulated, each corner on
// the triangle of the facet it lies in.
@(private="file")
cutout_place :: proc(outline:geom.Polygon_Set,corners:[][3]geom.Vec2,facets:[]u32,facet_sets:[]geom.Polygon_Set,facet_of:[]u32) -> (placed:Cutout_Placed) {
    points:=make([dynamic]Cutout_Point,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    lookup:=make(map[[2]u32]u32,context.temp_allocator)
    cut:geom.Polygon_Set
    geom.polygon_set_init(&cut,context.temp_allocator)
    triangulated:=make([dynamic]u32,context.temp_allocator)
    for facet_set,f in facet_sets {
        first,loop:=0,0
        for loops in outline.polygon_loops {
            count:=0
            for size in outline.loop_sizes[loop:][:loops] {count+=size}
            if geom.polygon_boolean(outline.points[first:][:count],outline.loop_sizes[loop:][:loops],facet_set.points[:],facet_set.loop_sizes[:],.Intersection,&cut)==.None {
                cut_first,cut_loop:=0,0
                for cut_loops in cut.polygon_loops {
                    cut_count:=0
                    for size in cut.loop_sizes[cut_loop:][:cut_loops] {cut_count+=size}
                    ring:=cut.points[cut_first:][:cut_count]
                    clear(&triangulated)
                    geom.polygon_triangulate(ring,cut.loop_sizes[cut_loop:][:cut_loops],&triangulated)
                    for corner in triangulated {
                        p:=ring[corner]
                        key:=[2]u32{transmute(u32)p.x,transmute(u32)p.y}
                        at,found:=lookup[key]
                        if !found {
                            // The triangle of the facet that holds the point most inside.
                            best,best_t:=f32(-max(f32)),0
                            weights:[3]f32
                            for g,t in facets {
                                if g!=facet_of[f] {continue}
                                w:=barycentric(corners[t],p)
                                if inside:=min(w[0],w[1],w[2]);inside>best {best,best_t,weights=inside,t,w}
                            }
                            for &w in weights {w=clamp(w,0,1)}
                            sum:=weights[0]+weights[1]+weights[2]
                            at=u32(len(points))
                            append(&points,Cutout_Point{u32(best_t),weights/max(sum,1e-12)})
                            lookup[key]=at
                        }
                        append(&indices,at)
                    }
                    cut_first+=cut_count
                    cut_loop+=cut_loops
                }
            }
            first+=count
            loop+=loops
        }
    }
    return {points[:],indices[:]}
}

// The vertex of a card at a point: what its triangle has there.
@(private="file")
cutout_vertex :: proc(mesh:^Imported_Mesh,triangle:u32,w:[3]f32,slot:u32) -> (v:asset.Vertex) {
    corners:[3]asset.Vertex
    for k in 0..<3 {corners[k]=mesh.vertices[mesh.indices[triangle*3+u32(k)]]}
    normal,tangent:mm.Vec3
    color:mm.Vec4
    for k in 0..<3 {
        v.position+=corners[k].position*w[k]
        v.uv+=corners[k].uv*w[k]
        v.uv1+=corners[k].uv1*w[k]
        normal+=mm.normal_unpack(corners[k].normal)*w[k]
        t,_:=mm.tangent_unpack(corners[k].tangent)
        tangent+=t*w[k]
        color+=mm.rgba8_unpack(corners[k].color)*w[k]
    }
    unit :: proc "contextless" (v,fallback:mm.Vec3) -> mm.Vec3 {
        l:=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
        return v/l if l>1e-12 else fallback
    }
    _,sign:=mm.tangent_unpack(corners[0].tangent)
    v.normal=mm.normal_pack(unit(normal,mm.normal_unpack(corners[0].normal)))
    first_tangent,_:=mm.tangent_unpack(corners[0].tangent)
    v.tangent=mm.tangent_pack(unit(tangent,first_tangent),sign)
    v.color=mm.rgba8_pack(color)
    v.material=slot
    return
}

// The mesh with its cards cut: level 0 with the outline or the convex outline
// of each, and the coarser outlines of those of leaves.
@(private="file")
cutout_rebuild :: proc(c:^Cutout,mesh:^Imported_Mesh,mesh_index:int) {
    r:=c.r
    // The card of each triangle of the mesh, -1 for none.
    card_of:=make([]i32,len(mesh.indices)/3,context.temp_allocator)
    for &k in card_of {k=-1}
    cards:=0
    for card,k in c.cards {
        if card.mesh!=mesh_index {continue}
        for t in card.triangles {card_of[t]=i32(k)}
        cards+=1
    }
    if cards==0 {return}
    slots:=make([dynamic]Imported_Slot,0,len(mesh.slots)+1,r.out)
    append(&slots,..mesh.slots)
    vertices:=make([dynamic]asset.Vertex,0,len(mesh.vertices),r.out)
    indices:=make([dynamic]u32,0,len(mesh.indices),r.out)
    submeshes:=make([dynamic]Submesh,0,len(mesh.submeshes)+1,r.out)
    outline_cards:=make([dynamic]Outline_Card,r.out)
    rungs:=make([dynamic]Outline_Rung,r.out)
    rung_vertices:=make([dynamic]asset.Vertex,r.out)
    rung_indices:=make([dynamic]u32,r.out)
    remap:=make([]u32,len(mesh.vertices),context.temp_allocator)
    for &v in remap {v=max(u32)}
    for sub in mesh.submeshes {
        material:=mesh.slots[sub.slot].material
        m:=c.materials[material] if material>=0 && material<len(c.materials) else Cutout_Material{}
        // The slot the outlines of this submesh take: its own, or one of the opaque copy.
        outline_slot:=sub.slot
        if m.opaque!=material && m.outlined>0 {
            outline_slot=u32(len(slots))
            for s,at in slots {if s.material==m.opaque && s.id==mesh.slots[sub.slot].id|CUTOUT_SLOT {outline_slot=u32(at)}}
            if outline_slot==u32(len(slots)) {append(&slots,Imported_Slot{id=mesh.slots[sub.slot].id|CUTOUT_SLOT,label=mesh.slots[sub.slot].label,material=m.opaque})}
        }
        // The masked part: its triangles as they were and the convex outlines of clusters.
        masked:=Submesh{first_index=u32(len(indices)),slot=sub.slot}
        first_triangle:=sub.first_index/3
        done:=make(map[i32]bool,context.temp_allocator)
        for t in first_triangle..<first_triangle+sub.index_count/3 {
            k:=card_of[t]
            if k<0 {
                for corner in mesh.indices[t*3:][:3] {
                    if remap[corner]==max(u32) {
                        remap[corner]=u32(len(vertices))
                        append(&vertices,mesh.vertices[corner])
                    }
                    append(&indices,remap[corner])
                }
                continue
            }
            card:=c.cards[k]
            if card.leaf || card.layout<0 || done[k] {continue}
            done[k]=true
            cutout_emit(mesh,card,c.layouts[card.layout].hull,c.layouts[card.layout].flip,sub.slot,&vertices,&indices)
        }
        masked.index_count=u32(len(indices))-masked.first_index
        // The outlines of leaves, each one island.
        opaque:=Submesh{first_index=u32(len(indices)),slot=outline_slot}
        for t in first_triangle..<first_triangle+sub.index_count/3 {
            k:=card_of[t]
            if k<0 || done[k] {continue}
            done[k]=true
            card:=c.cards[k]
            if !card.leaf || card.layout<0 {continue}
            layout:=&c.layouts[card.layout]
            ladder:=&c.ladders[layout.shape]
            first:=u32(len(indices))
            cutout_emit(mesh,card,layout.rungs[0],layout.flip,outline_slot,&vertices,&indices)
            append(&outline_cards,Outline_Card{first/3,(u32(len(indices))-first)/3,ladder.rungs[0].error*card.scale})
            for k in 1..<OUTLINE_RUNGS {
                rung:=Outline_Rung{first_index=u32(len(rung_indices)),error=ladder.rungs[k].error*card.scale}
                if k>1 && raw_data(layout.rungs[k].indices)==raw_data(layout.rungs[k-1].indices) && raw_data(layout.rungs[k].indices)!=nil {
                    previous:=rungs[len(rungs)-1]
                    rung.first_index,rung.index_count=previous.first_index,previous.index_count
                } else {
                    cutout_emit(mesh,card,layout.rungs[k],layout.flip,outline_slot,&rung_vertices,&rung_indices)
                    rung.index_count=u32(len(rung_indices))-rung.first_index
                }
                append(&rungs,rung)
            }
        }
        opaque.index_count=u32(len(indices))-opaque.first_index
        if opaque.slot==masked.slot {
            masked.index_count+=opaque.index_count
            opaque.index_count=0
        }
        for part in ([2]^Submesh{&masked,&opaque}) {
            if part.index_count==0 {continue}
            part.bounds_min,part.bounds_max=vertices[indices[part.first_index]].position,vertices[indices[part.first_index]].position
            for index in indices[part.first_index:][:part.index_count] {
                p:=vertices[index].position
                part.bounds_min={min(part.bounds_min.x,p.x),min(part.bounds_min.y,p.y),min(part.bounds_min.z,p.z)}
                part.bounds_max={max(part.bounds_max.x,p.x),max(part.bounds_max.y,p.y),max(part.bounds_max.z,p.z)}
            }
            append(&submeshes,part^)
        }
    }
    mesh.vertices,mesh.indices,mesh.submeshes,mesh.slots=vertices[:],indices[:],submeshes[:],slots[:]
    mesh.outlines={outline_cards[:],rungs[:],rung_vertices[:],rung_indices[:]}
    if len(vertices)>0 {
        mesh.bounds_min,mesh.bounds_max=vertices[0].position,vertices[0].position
        for v in vertices {
            mesh.bounds_min={min(mesh.bounds_min.x,v.position.x),min(mesh.bounds_min.y,v.position.y),min(mesh.bounds_min.z,v.position.z)}
            mesh.bounds_max={max(mesh.bounds_max.x,v.position.x),max(mesh.bounds_max.y,v.position.y),max(mesh.bounds_max.z,v.position.z)}
        }
    }
}

// Appends an outline placed on a card: its vertices, of slot, and its
// triangles, turned as the card turns in the mesh.
@(private="file")
cutout_emit :: proc(mesh:^Imported_Mesh,card:Cutout_Card,placed:Cutout_Placed,flip:bool,slot:u32,vertices:^[dynamic]asset.Vertex,indices:^[dynamic]u32) {
    first:=u32(len(vertices))
    for p in placed.points {append(vertices,cutout_vertex(mesh,card.triangles[p.triangle],p.weights,slot))}
    for t:=0;t+2<len(placed.indices);t+=3 {
        a,b,c:=placed.indices[t],placed.indices[t+1],placed.indices[t+2]
        if flip {b,c=c,b}
        append(indices,first+a,first+b,first+c)
    }
}
