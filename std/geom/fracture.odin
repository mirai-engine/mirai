package geom

import "base:runtime"
import "core:slice"
import "mirai:std/base"

Site_Pattern :: enum {
    Uniform,   // spread evenly in the box
    Clustered, // gathered around a few centers spread in the box
    Radial,    // around a center, denser towards it: an impact
}

Site_Desc :: struct {
    pattern:       Site_Pattern,
    seed:          u64,
    lo,hi:         Vec3, // box of the mesh
    clusters:      int,  // Clustered: number of centers; 0 is one per eight sites
    cluster_radius:f32,  // Clustered: reach of a center; 0 is 15% of the diagonal of the box
    center:        Vec3, // Radial: the impact point
    radius:        f32,  // Radial: reach of the impact; 0 is half the diagonal of the box
}

// Fills `sites` with the sites of a Voronoi fracture. The sequence depends
// only on the description: the same seed gives the same sites everywhere.
sites_generate :: proc(sites:[]Vec3,desc:Site_Desc) {
    rng:=rng_make(desc.seed)
    size:=desc.hi-desc.lo
    diagonal:=f32(dlength(dvec(size)))
    inside :: proc(rng:^Rng,lo,size:Vec3) -> Vec3 {
        x:=rng_f32(rng);y:=rng_f32(rng);z:=rng_f32(rng)
        return lo+size*Vec3{x,y,z}
    }
    switch desc.pattern {
    case .Uniform:
        for &site in sites {site=inside(&rng,desc.lo,size)}
    case .Clustered:
        clusters:=desc.clusters if desc.clusters>0 else max(1,len(sites)/8)
        clusters=min(clusters,max(len(sites),1))
        reach:=desc.cluster_radius if desc.cluster_radius>0 else 0.15*diagonal
        // The first sites are the centers; the rest gather around them in turn.
        for &site,i in sites {
            if i<clusters {site=inside(&rng,desc.lo,size);continue}
            site=sites[i%clusters]+rng_ball(&rng)*reach
        }
    case .Radial:
        reach:=desc.radius if desc.radius>0 else 0.5*diagonal
        for &site in sites {
            direction:=fnormalize(rng_ball(&rng),{0,1,0})
            u:=rng_f32(&rng)
            site=desc.center+direction*(reach*u*u)
        }
    }
}

Fracture_Options :: struct {
    tolerance:        f32,  // as Slice_Options.tolerance
    interior_material:u32,  // material slot of the faces the fracture opens
    interior_uv_scale:f32,  // as Slice_Options.cap_uv_scale
    interior_color:   Vec4, // as Slice_Options.cap_color
    min_volume:       f32,  // pieces up to this volume are dropped
}

// One connected part of a Voronoi cell of the mesh: a cell that crosses a
// concave mesh more than once has a piece for each part. Pieces are ordered
// by site, then by chunk, and the pair is the identity of a piece: equal
// meshes and sites give equal pieces.
Fracture_Piece :: struct {
    site:        u32,
    chunk:       u32, // the parts of a cell in the order of their first triangle
    first_vertex:u32,
    vertex_count:u32,
    first_index: u32, // its indices are relative to first_vertex
    index_count: u32,
    volume:      f32,
    center:      Vec3, // center of mass
}

// Two pieces that touch across the plane between their sites, a<b.
Fracture_Connection :: struct {
    a,b: u32, // indices of pieces
    area:f32, // of the face they share; between parts of cells, the smaller of their faces
}

Fracture_Error :: enum {None,Invalid_Mesh,No_Sites}

// Result and reusable memory of mesh_fracture.
Fracture :: struct {
    mesh:       Mesh_Buffer, // every piece, one after another
    pieces:     [dynamic]Fracture_Piece,
    connections:[dynamic]Fracture_Connection, // ordered by a, then b

    slicer:     Slicer,
    work:       [2]Mesh_Buffer,
    tags:       [2][dynamic]u32, // per triangle of work: site across the face, NONE on the surface
    order:      [dynamic]Fracture_Order,
    neighbors:  [dynamic]u32,
    seen:       [dynamic]u32,
    area:       [dynamic]f64,
    bounds:     [dynamic][2]Vec3,   // per site: box of the face across it
    site_pieces:[dynamic][2]u32,    // per site: first piece and count
    piece_faces:[dynamic][2]u32,    // per piece: first face and count
    faces:      [dynamic]Fracture_Face,
    pairs:      Key_Map,
    remap:      [dynamic]u32,       // per vertex of a cell
    chunk_of:   [dynamic]u32,       // per triangle of a cell
}

@(private) Fracture_Order :: struct {distance:f64,site:u32}
@(private) Fracture_Face :: struct {piece,site:u32,area:f32,lo,hi:Vec3}

fracture_init :: proc(f:^Fracture,allocator:=context.allocator) {
    mesh_buffer_init(&f.mesh,allocator)
    f.pieces=make([dynamic]Fracture_Piece,allocator)
    f.connections=make([dynamic]Fracture_Connection,allocator)
    slicer_init(&f.slicer,allocator)
    for k in 0..<2 {
        mesh_buffer_init(&f.work[k],allocator)
        f.tags[k]=make([dynamic]u32,allocator)
    }
    f.order=make([dynamic]Fracture_Order,allocator)
    f.neighbors=make([dynamic]u32,allocator)
    f.seen=make([dynamic]u32,allocator)
    f.area=make([dynamic]f64,allocator)
    f.bounds=make([dynamic][2]Vec3,allocator)
    f.site_pieces=make([dynamic][2]u32,allocator)
    f.piece_faces=make([dynamic][2]u32,allocator)
    f.faces=make([dynamic]Fracture_Face,allocator)
    f.remap=make([dynamic]u32,allocator)
    f.chunk_of=make([dynamic]u32,allocator)
    key_map_init(&f.pairs,allocator)
}

fracture_destroy :: proc(f:^Fracture) {
    mesh_buffer_destroy(&f.mesh)
    delete(f.pieces);delete(f.connections)
    slicer_destroy(&f.slicer)
    for k in 0..<2 {mesh_buffer_destroy(&f.work[k]);delete(f.tags[k])}
    delete(f.order);delete(f.neighbors);delete(f.seen);delete(f.area);delete(f.bounds)
    delete(f.site_pieces);delete(f.piece_faces);delete(f.faces)
    delete(f.remap);delete(f.chunk_of)
    key_map_destroy(&f.pairs)
    f^={}
}

// The mesh of a piece, as views into Fracture.mesh.
fracture_piece_mesh :: proc(f:^Fracture,piece:int) -> Mesh {
    p:=f.pieces[piece]
    whole:=mesh_buffer_view(&f.mesh)
    out:=Mesh{positions=whole.positions[p.first_vertex:][:p.vertex_count],indices=whole.indices[p.first_index:][:p.index_count]}
    if len(whole.normals)>0 {out.normals=whole.normals[p.first_vertex:][:p.vertex_count]}
    if len(whole.uvs)>0 {out.uvs=whole.uvs[p.first_vertex:][:p.vertex_count]}
    if len(whole.colors)>0 {out.colors=whole.colors[p.first_vertex:][:p.vertex_count]}
    out.materials=whole.materials[p.first_index/3:][:p.index_count/3]
    return out
}

// Plane halfway between two sites, facing the second.
@(private="file") bisector :: proc "contextless" (a,b:Vec3) -> DPlane {
    n:=dvec(b)-dvec(a)
    l:=dlength(n)
    return {n/l,ddot(n,dvec(a)+dvec(b))*0.5/l}
}

@(private="file") Clip :: enum {Untouched,Cut,Empty}

// Cuts `source` with the plane and writes what is behind it to work[target].
// `previous` is the work buffer that holds source, or -1 for the input mesh.
@(private="file") fracture_clip :: proc(f:^Fracture,source:Mesh,previous,target:int,plane:DPlane,site:u32,options:Slice_Options) -> Clip #no_bounds_check {
    result:=slice_plane(&f.slicer,source,plane,nil,&f.work[target],options,false)
    if result.front.triangles==0 {return .Untouched}
    if result.back.triangles==0 {return .Empty}
    sources:=f.slicer.sources[1][:]
    resize(&f.tags[target],len(sources))
    for s,t in sources {
        f.tags[target][t]=site if s==SLICE_CAP else NONE if previous<0 else f.tags[previous][s]
    }
    return .Cut
}

// Voronoi fracture: the part of the mesh nearer to each site than to any
// other, cut with the slicer along the planes between sites, one piece per
// connected part of it. A closed mesh gives closed pieces whose volumes add
// up to its volume. Also builds the graph of the pieces that touch, with the
// area they share. Each cell cuts the whole mesh: the first cuts walk every
// triangle, which bounds the cost by sites times triangles.
mesh_fracture :: proc(f:^Fracture,mesh:Mesh,sites:[]Vec3,options:Fracture_Options={}) -> Fracture_Error #no_bounds_check {
    mesh_buffer_clear(&f.mesh)
    clear(&f.pieces);clear(&f.connections);clear(&f.faces);clear(&f.piece_faces)
    if !mesh_is_valid(mesh) {return .Invalid_Mesh}
    if len(sites)==0 {return .No_Sites}
    lo,hi:=mesh_bounds(mesh.positions)
    max_abs:=positions_max_abs(mesh.positions)
    tolerance:=max(options.tolerance,tolerance_noise(max_abs))
    cut:=Slice_Options{tolerance=tolerance,cap_material=options.interior_material,cap_uv_scale=options.interior_uv_scale,cap_color=options.interior_color}
    cell_cut:=Slice_Options{tolerance=tolerance}
    margin:=max(tolerance*16,1e-3*f32(dlength(dvec(hi)-dvec(lo))))
    box_lo,box_hi:=lo-margin,hi+margin

    resize(&f.seen,len(sites));resize(&f.area,len(sites));resize(&f.bounds,len(sites));resize(&f.site_pieces,len(sites))
    for i in 0..<len(sites) {f.seen[i]=NONE;f.area[i]=0;f.bounds[i]={max(f32),-max(f32)};f.site_pieces[i]={}}

    for site,i in sites {
        // The other sites from the nearest. A site at the place of an earlier
        // one has no cell.
        clear(&f.order)
        repeated:=false
        for other,j in sites {
            if j==i {continue}
            d:=dvec(other)-dvec(site)
            distance:=ddot(d,d)
            if distance==0 {
                if j<i {repeated=true;break}
                continue
            }
            append(&f.order,Fracture_Order{distance,u32(j)})
        }
        if repeated {continue}
        slice.sort_by(f.order[:],proc(a,b:Fracture_Order) -> bool {
            return a.distance<b.distance || (a.distance==b.distance && a.site<b.site)
        })

        // The cell of the site inside the box of the mesh tells which planes
        // bound it. Beyond twice the reach of the cell no site can cut it.
        cell:=&f.work[0]
        mesh_buffer_clear(cell)
        corners:=box_corners(box_lo,box_hi)
        append(&cell.positions,..corners[:])
        append(&cell.indices,0,2,1, 1,2,3, 4,5,6, 5,7,6, 0,1,4, 1,5,4, 2,6,3, 3,6,7, 0,4,2, 2,4,6, 1,3,5, 3,7,5)
        resize(&f.tags[0],12)
        for &tag in f.tags[0] {tag=NONE}
        current:=0
        empty:=false
        for entry in f.order {
            reach:f64
            for p in f.work[current].positions {
                d:=dvec(p)-dvec(site)
                reach=max(reach,ddot(d,d))
            }
            if entry.distance>4*reach {break}
            state:=fracture_clip(f,mesh_buffer_view(&f.work[current]),current,1-current,bisector(site,sites[entry.site]),entry.site,cell_cut)
            if state==.Empty {empty=true;break}
            if state==.Cut {current=1-current}
        }
        if empty {continue}
        clear(&f.neighbors)
        for tag in f.tags[current] {
            if tag!=NONE {f.seen[tag]=u32(i)}
        }
        for entry in f.order {
            if f.seen[entry.site]==u32(i) {append(&f.neighbors,entry.site)}
        }

        // The mesh, cut by those planes from the nearest.
        source:=mesh
        current=-1
        for neighbor in f.neighbors {
            target:=0 if current<0 else 1-current
            state:=fracture_clip(f,source,current,target,bisector(site,sites[neighbor]),neighbor,cut)
            if state==.Empty {empty=true;break}
            if state==.Cut {
                current=target
                source=mesh_buffer_view(&f.work[current])
            }
        }
        if empty || len(source.indices)==0 {continue}
        fracture_emit(f,source,f.tags[current][:] if current>=0 else nil,u32(i),options.min_volume)
    }

    // A face of one piece and a face of a piece of the site across it that
    // overlap on their plane are one connection, as wide as the smaller face.
    key_map_reset(&f.pairs,len(f.faces))
    reach:=tolerance*8
    for face in f.faces {
        own:=f.pieces[face.piece].site
        others:=f.site_pieces[face.site]
        for other in others[0]..<others[0]+others[1] {
            faces:=f.piece_faces[other]
            for back in f.faces[faces[0]:][:faces[1]] {
                if back.site!=own || !boxes_touch(face.lo,face.hi,back.lo,back.hi,reach) {continue}
                a,b:=min(face.piece,other),max(face.piece,other)
                if _,inserted:=key_map_entry(&f.pairs,pair_key(a,b),u32(len(f.connections)));inserted {
                    append(&f.connections,Fracture_Connection{a,b,min(face.area,back.area)})
                }
            }
        }
    }
    slice.sort_by(f.connections[:],proc(x,y:Fracture_Connection) -> bool {return x.a<y.a || (x.a==y.a && x.b<y.b)})
    return .None
}

@(private="file") boxes_touch :: proc "contextless" (lo,hi,other_lo,other_hi:Vec3,reach:f32) -> bool {
    return lo.x-reach<=other_hi.x && other_lo.x<=hi.x+reach && lo.y-reach<=other_hi.y && other_lo.y<=hi.y+reach && lo.z-reach<=other_hi.z && other_lo.z<=hi.z+reach
}

// Appends the cell of `site`, the mesh cut to it, as one piece per
// component (mesh_components). tags holds the site across each face the cuts
// opened; nil when no plane cut the mesh.
@(private="file")
fracture_emit :: proc(f:^Fracture,source:Mesh,tags:[]u32,site:u32,min_volume:f32) #no_bounds_check {
    triangles:=len(source.indices)/3
    resize(&f.chunk_of,triangles)
    chunks:=u32(mesh_components(source.positions,source.indices,f.chunk_of[:]))
    resize(&f.remap,len(source.positions))
    for &r in f.remap {r=NONE}

    has_normals,has_uvs,has_colors,has_materials:=len(source.normals)>0,len(source.uvs)>0,len(source.colors)>0,len(source.materials)>0
    f.site_pieces[site]={u32(len(f.pieces)),0}
    for chunk in 0..<chunks {
        first_vertex,first_index:=len(f.mesh.positions),len(f.mesh.indices)
        if chunks==1 {
            append(&f.mesh.positions,..source.positions)
            if has_normals {append(&f.mesh.normals,..source.normals)}
            if has_uvs {append(&f.mesh.uvs,..source.uvs)}
            if has_colors {append(&f.mesh.colors,..source.colors)}
            append(&f.mesh.indices,..source.indices)
            if has_materials {append(&f.mesh.materials,..source.materials)} else {
                for _ in 0..<triangles {append(&f.mesh.materials,0)}
            }
        } else {
            for t in 0..<triangles {
                if f.chunk_of[t]!=chunk {continue}
                for v in source.indices[t*3:][:3] {
                    if f.remap[v]==NONE {
                        f.remap[v]=u32(len(f.mesh.positions)-first_vertex)
                        append(&f.mesh.positions,source.positions[v])
                        if has_normals {append(&f.mesh.normals,source.normals[v])}
                        if has_uvs {append(&f.mesh.uvs,source.uvs[v])}
                        if has_colors {append(&f.mesh.colors,source.colors[v])}
                    }
                    append(&f.mesh.indices,f.remap[v])
                }
                append(&f.mesh.materials,source.materials[t] if has_materials else 0)
            }
        }
        positions,indices:=f.mesh.positions[first_vertex:],f.mesh.indices[first_index:]
        mass:=mesh_mass_properties(positions,indices)
        if !(mass.volume>max(min_volume,0)) {
            base.truncate(&f.mesh.positions,first_vertex)
            if has_normals {base.truncate(&f.mesh.normals,first_vertex)}
            if has_uvs {base.truncate(&f.mesh.uvs,first_vertex)}
            if has_colors {base.truncate(&f.mesh.colors,first_vertex)}
            base.truncate(&f.mesh.indices,first_index)
            base.truncate(&f.mesh.materials,first_index/3)
            continue
        }
        piece:=u32(len(f.pieces))
        first_face:=u32(len(f.faces))
        for tag,t in tags {
            if tag==NONE || f.chunk_of[t]!=chunk {continue}
            a,b,c:=source.positions[source.indices[t*3]],source.positions[source.indices[t*3+1]],source.positions[source.indices[t*3+2]]
            f.area[tag]+=0.5*dlength(dcross(dvec(b)-dvec(a),dvec(c)-dvec(a)))
            box:=&f.bounds[tag]
            for p in ([3]Vec3{a,b,c}) {
                box[0]={min(box[0].x,p.x),min(box[0].y,p.y),min(box[0].z,p.z)}
                box[1]={max(box[1].x,p.x),max(box[1].y,p.y),max(box[1].z,p.z)}
            }
        }
        if len(tags)>0 {
            for neighbor in f.neighbors {
                if f.area[neighbor]>0 {append(&f.faces,Fracture_Face{piece,neighbor,f32(f.area[neighbor]),f.bounds[neighbor][0],f.bounds[neighbor][1]})}
                f.area[neighbor]=0
                f.bounds[neighbor]={max(f32),-max(f32)}
            }
        }
        append(&f.piece_faces,[2]u32{first_face,u32(len(f.faces))-first_face})
        append(&f.pieces,Fracture_Piece{
            site=site,chunk=chunk,
            first_vertex=u32(first_vertex),vertex_count=u32(len(positions)),
            first_index=u32(first_index),index_count=u32(len(indices)),
            volume=mass.volume,center=mass.center,
        })
        f.site_pieces[site][1]+=1
    }
}

@(private) box_corners :: proc(lo,hi:Vec3) -> [8]Vec3 {
    return {{lo.x,lo.y,lo.z},{hi.x,lo.y,lo.z},{lo.x,hi.y,lo.z},{hi.x,hi.y,lo.z},{lo.x,lo.y,hi.z},{hi.x,lo.y,hi.z},{lo.x,hi.y,hi.z},{hi.x,hi.y,hi.z}}
}
