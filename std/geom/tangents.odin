/*
Native Odin port of MikkTSpace's tangent generation.

Copyright (C) 2011 by Morten S. Mikkelsen

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

The algorithm is described in M. Mikkelsen, Simulation of Wrinkled Surfaces
Revisited (2008), chapter 3. This file is an altered, triangle-only port.
*/
package geom

import "base:intrinsics"
import "core:math"
import "core:math/linalg"

// The tangents of the corners of an indexed triangle mesh, as MikkTSpace
// gives them: xyz the unit tangent along u, w the sign of the bitangent,
// sign * cross(normal, tangent), which points up the image. They are the
// tangents normal map bakers use, so a baked map shows no seams; one
// algorithm serves imports and meshes made at run time alike.
//
// Mirai's v grows downwards and MikkTSpace takes v upwards: it is given
// 1 - v. Without normals a corner takes the normal of its triangle; without
// uvs, or where the algorithm finds no direction, the tangent is one across
// the normal. out has one tangent per index. False without memory, when the
// streams do not match or when a position, normal or uv is not finite.
//
// Welding and adjacency use open-addressing tables over flat arrays and the
// vector math is inlined, so -o:minimal builds stay fast too.
corner_tangents :: proc(positions,normals:[]Vec3,uvs:[]Vec2,indices:[]u32,out:[]Vec4) -> bool #no_bounds_check {
    if len(out)!=len(indices) || len(indices)%3!=0 || !triangle_in_all(indices,len(positions)) {return false}
    if len(normals)!=0 && len(normals)!=len(positions) || len(uvs)!=0 && len(uvs)!=len(positions) {return false}
    if len(indices)>=int(TANGENT_TOMB) {return false}
    for &tangent in out {tangent={}}
    count:=len(indices)/3
    if count==0 {return true}
    for p in positions {if !finite3(p) {return false}}
    for n in normals {if !finite3(n) {return false}}
    for uv in uvs {if !finite2(uv) {return false}}
    scratch:=context.temp_allocator
    tris:[]Tangent_Tri
    weld_normals:[]Vec3
    weld_keys:[]Tangent_Key
    weld_table:[]u32
    edge_keys:[]u64
    edge_slots:[]u32
    groups:[dynamic]Tangent_Group
    group_tris:[dynamic]u32
    projected:[dynamic][2]Vec3
    subs:[dynamic]Tangent_Subgroup
    sub_tris:[dynamic]u32
    sub_spaces:[dynamic]Tangent_Space
    members:[dynamic]u32
    weld_space:[]Vec4
    defer {
        delete(weld_space,scratch)
        delete(members[:],scratch)
        delete(sub_spaces[:],scratch)
        delete(sub_tris[:],scratch)
        delete(subs[:],scratch)
        delete(projected[:],scratch)
        delete(group_tris[:],scratch)
        delete(groups[:],scratch)
        delete(edge_slots,scratch)
        delete(edge_keys,scratch)
        delete(weld_table,scratch)
        delete(weld_keys,scratch)
        delete(weld_normals,scratch)
        delete(tris,scratch)
    }

    tris=make([]Tangent_Tri,count,scratch)
    weld_normals=make([]Vec3,len(indices),scratch)
    weld_keys=make([]Tangent_Key,len(indices),scratch)
    weld_table=make([]u32,tangent_table_size(len(indices)),scratch)
    if tris==nil || weld_normals==nil || weld_keys==nil || weld_table==nil {return false}
    for &slot in weld_table {slot=NONE}
    weld_mask:=len(weld_table)-1
    weld_count:=0

    for ti in 0..<count {
        base:=ti*3
        i0,i1,i2:=indices[base],indices[base+1],indices[base+2]
        p0,p1,p2:=positions[i0],positions[i1],positions[i2]
        face:=tangent_normalize0(tangent_cross(p1-p0,p2-p0))
        tri:=&tris[ti]
        tri.p={p0,p1,p2}
        tri.adj={-1,-1,-1}
        tri.group={-1,-1,-1}
        uv:=[3]Vec2{{0,1},{0,1},{0,1}}
        if len(uvs)>0 {
            uv[0]={uvs[i0].x,1-uvs[i0].y}
            uv[1]={uvs[i1].x,1-uvs[i1].y}
            uv[2]={uvs[i2].x,1-uvs[i2].y}
        }
        for k in 0..<3 {
            vi:=indices[base+k]
            n:=face
            if len(normals)>0 {
                n=tangent_normalize0(normals[vi])
                if n==(Vec3{}) {n=face}
            }
            key:=tangent_key(positions[vi],n,uv[k])
            slot:=int(tangent_key_hash(key))&weld_mask
            for {
                id:=weld_table[slot]
                if id==NONE {
                    id=u32(weld_count)
                    weld_table[slot]=id
                    weld_keys[id]=key
                    weld_normals[id]=n
                    weld_count+=1
                    tri.weld[k]=id
                    break
                }
                if tangent_key_equal(weld_keys[id],key) {tri.weld[k]=id;break}
                slot=(slot+1)&weld_mask
            }
        }

        t21:=uv[1]-uv[0]
        t31:=uv[2]-uv[0]
        area2:=t21.x*t31.y-t21.y*t31.x
        tri.orient=area2>0
        tri.dead=p0==p1 || p0==p2 || p1==p2
        tri.any=true
        if tri.dead {continue}
        os:=(p1-p0)*t31.y-(p2-p0)*t21.y
        ot:=(p1-p0)*(-t31.x)+(p2-p0)*t21.x
        if area2!=0 {
            ls,lt:=tangent_length(os),tangent_length(ot)
            sign:f32=tri.orient?1:-1
            if ls>0 {tri.os=os*(sign/ls)}
            if lt>0 {tri.ot=ot*(sign/lt)}
            if ls>0 && lt>0 {tri.any=false}
        }
    }

    // Two triangles share an edge when they share its two welded vertices.
    // When every corner got its own welded vertex no edge can be shared.
    if weld_count!=len(indices) {
        edge_keys=make([]u64,tangent_table_size(len(indices)),scratch)
        edge_slots=make([]u32,len(edge_keys),scratch)
        if edge_keys==nil || edge_slots==nil {return false}
        for &slot in edge_slots {slot=NONE}
        edge_mask:=len(edge_slots)-1
        for ti in 0..<count {
            if tris[ti].dead {continue}
            for k in 0..<3 {
                a,b:=tris[ti].weld[k],tris[ti].weld[(k+1)%3]
                if a>b {a,b=b,a}
                key:=u64(a)<<32|u64(b)
                slot:=int(tangent_mix(key))&edge_mask
                for {
                    corner:=edge_slots[slot]
                    if corner==NONE {
                        edge_keys[slot]=key
                        edge_slots[slot]=u32(ti*3+k)
                        break
                    }
                    // A matched edge leaves a tombstone: a third triangle on
                    // it pairs with a fourth, as the map this replaces did.
                    if corner!=TANGENT_TOMB && edge_keys[slot]==key {
                        other,edge:=int(corner/3),int(corner%3)
                        tris[other].adj[edge]=i32(ti)
                        tris[ti].adj[k]=i32(other)
                        edge_slots[slot]=TANGENT_TOMB
                        break
                    }
                    slot=(slot+1)&edge_mask
                }
            }
        }
    }

    groups=make([dynamic]Tangent_Group,0,count*3,scratch)
    group_tris=make([dynamic]u32,0,count*3,scratch)
    if cap(groups)==0 || cap(group_tris)==0 {return false}
    for ti in 0..<count {
        if tris[ti].dead || tris[ti].any {continue}
        for c in 0..<3 {
            if tris[ti].group[c]!=-1 {continue}
            gi:=len(groups)
            append(&groups,Tangent_Group{rep=tris[ti].weld[c],orient=tris[ti].orient,first=len(group_tris)})
            tris[ti].group[c]=i32(gi)
            append(&group_tris,u32(ti))
            groups[gi].count+=1
            incident:=[2]int{c,(c+2)%3}
            for e in incident {
                nb:=tris[ti].adj[e]
                if nb>=0 {tangent_assign_group(tris,&group_tris,groups[:],gi,int(nb))}
            }
        }
    }

    projected=make([dynamic][2]Vec3,0,16,scratch)
    subs=make([dynamic]Tangent_Subgroup,0,16,scratch)
    sub_tris=make([dynamic]u32,0,16,scratch)
    sub_spaces=make([dynamic]Tangent_Space,0,16,scratch)
    members=make([dynamic]u32,0,16,scratch)
    if cap(projected)==0 || cap(subs)==0 || cap(sub_tris)==0 || cap(sub_spaces)==0 || cap(members)==0 {return false}
    for gi in 0..<len(groups) {
        g:=groups[gi]
        group:=group_tris[g.first:g.first+g.count]
        n:=weld_normals[int(g.rep)]
        // Members keep the order of the group, so each subgroup comes out sorted.
        tangent_sort_members(group)
        if non_zero_resize(&projected,g.count)!=nil || non_zero_resize(&members,g.count)!=nil {return false}
        for t,k in group {projected[k][0],projected[k][1]=tangent_project(tris[t].os,tris[t].ot,n)}
        // Members are positions in the group. Usually every pair of the group
        // agrees and one subgroup holds them all.
        whole:=true
        pairs: for m in 0..<g.count {
            if tris[group[m]].any {continue}
            for k in m+1..<g.count {
                if !tris[group[k]].any && !(tangent_dot(projected[m][0],projected[k][0])>-1 && tangent_dot(projected[m][1],projected[k][1])>-1) {
                    whole=false
                    break pairs
                }
            }
        }
        if whole {
            for &member,k in members {member=u32(k)}
            space:=tangent_eval(tris,group,members[:],projected[:],n,g.rep,g.orient)
            for t in group {
                c:=tangent_corner(tris[t],g.rep)
                if c>=0 {out[int(t)*3+c]=Vec4{space.t.x,space.t.y,space.t.z,space.sign}}
            }
            continue
        }
        clear(&subs);clear(&sub_tris);clear(&sub_spaces)
        for m in 0..<g.count {
            ti:=int(group[m])
            c:=tangent_corner(tris[ti],g.rep)
            if c<0 {continue}
            osf,otf:=projected[m][0],projected[m][1]
            held:=0
            for k in 0..<g.count {
                if tris[ti].any || tris[group[k]].any ||
                   (tangent_dot(osf,projected[k][0])>-1 && tangent_dot(otf,projected[k][1])>-1) {
                    members[held]=u32(k)
                    held+=1
                }
            }
            kept:=members[:held]
            found:=-1
            for s,si in subs {
                if tangent_members_equal(sub_tris[s.first:s.first+s.count],kept) {
                    found=si
                    break
                }
            }
            if found<0 {
                first:=len(sub_tris)
                append(&sub_tris,..kept)
                append(&subs,Tangent_Subgroup{first=first,count=held})
                append(&sub_spaces,tangent_eval(tris,group,kept,projected[:],n,g.rep,g.orient))
                found=len(subs)-1
            }
            space:=sub_spaces[found]
            out[ti*3+c]=Vec4{space.t.x,space.t.y,space.t.z,space.sign}
        }
    }

    weld_space=make([]Vec4,weld_count,scratch)
    if weld_space==nil {return false}
    for ti in 0..<count {
        for c in 0..<3 {
            tangent:=out[ti*3+c]
            if tangent_dot(tangent.xyz,tangent.xyz)<=0.25 {continue}
            id:=tris[ti].weld[c]
            if tangent_dot(weld_space[id].xyz,weld_space[id].xyz)<=0.25 {weld_space[id]=tangent}
        }
    }
    for ti in 0..<count {
        if !tris[ti].dead {continue}
        for c in 0..<3 {out[ti*3+c]=weld_space[tris[ti].weld[c]]}
    }

    tangent_sanitize(out,positions,normals,indices)
    return true
}

// A consumed slot of the edge table.
@(private="file")
TANGENT_TOMB :: NONE-1

// A power of two at least twice count, so the open-addressing tables stay at
// most half full.
@(private="file")
tangent_table_size :: proc "contextless" (count:int) -> int {
    size:=16
    for size<count*2 {size*=2}
    return size
}

@(private="file")
tangent_dot :: #force_inline proc "contextless" (a,b:Vec3) -> f32 {return a.x*b.x+a.y*b.y+a.z*b.z}

@(private="file")
tangent_cross :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {return a.yzx*b.zxy-b.yzx*a.zxy}

@(private="file")
tangent_length :: #force_inline proc "contextless" (v:Vec3) -> f32 {return intrinsics.sqrt(tangent_dot(v,v))}

@(private="file")
tangent_normalize0 :: #force_inline proc "contextless" (v:Vec3) -> Vec3 {
    m:=tangent_length(v)
    return 0 if m==0 else v/m
}

@(private="file")
tangent_sanitize :: proc(out:[]Vec4,positions:[]Vec3,normals:[]Vec3,indices:[]u32) #no_bounds_check {
    for &tangent,at in out {
        length2:=tangent_dot(tangent.xyz,tangent.xyz)
        if length2>0.25 && length2-length2==0 {
            tangent.w=-1 if tangent.w<0 else 1
            continue
        }
        base:=at-at%3
        a,b,c:=positions[indices[base]],positions[indices[base+1]],positions[indices[base+2]]
        normal:=tangent_normalize0(tangent_cross(b-a,c-a))
        if len(normals)>0 {
            given:=tangent_normalize0(normals[indices[at]])
            if given!=(Vec3{}) {normal=given}
        }
        across:=any_tangent(normal)
        tangent={across.x,across.y,across.z,1}
    }
}

@(private="file")
Tangent_Key :: [8]u32

@(private="file")
Tangent_Tri :: struct {
    weld:   [3]u32,
    p:      [3]Vec3,
    os, ot: Vec3,
    orient: bool,
    any:    bool,
    dead:   bool,
    adj:    [3]i32,
    group:  [3]i32,
}

@(private="file")
Tangent_Group :: struct {
    rep:    u32,
    orient: bool,
    first:  int,
    count:  int,
}

@(private="file")
Tangent_Subgroup :: struct {
    first: int,
    count: int,
}

@(private="file")
Tangent_Space :: struct {
    t:    Vec3,
    sign: f32,
}

@(private="file")
tangent_bits :: #force_inline proc "contextless" (x:f32) -> u32 {
    return transmute(u32)(x==0?f32(0):x)
}

// A 64-bit hash of a weld key.
@(private="file")
tangent_key_hash :: #force_inline proc "contextless" (key:Tangent_Key) -> u64 {
    hash:=tangent_mix(u64(key[0])|u64(key[1])<<32)
    hash=tangent_mix(hash~(u64(key[2])|u64(key[3])<<32))
    hash=tangent_mix(hash~(u64(key[4])|u64(key[5])<<32))
    return tangent_mix(hash~(u64(key[6])|u64(key[7])<<32))
}

// The splitmix64 finalizer.
@(private="file")
tangent_mix :: #force_inline proc "contextless" (x:u64) -> u64 {
    x:=x
    x=(x~(x>>30))*0xbf58476d1ce4e5b9
    x=(x~(x>>27))*0x94d049bb133111eb
    return x~(x>>31)
}
@(private="file")
tangent_key :: proc "contextless" (p,n:Vec3,uv:Vec2) -> Tangent_Key {
    return {
        tangent_bits(p.x),tangent_bits(p.y),tangent_bits(p.z),
        tangent_bits(n.x),tangent_bits(n.y),tangent_bits(n.z),
        tangent_bits(uv.x),tangent_bits(uv.y),
    }
}

@(private="file")
tangent_key_equal :: #force_inline proc "contextless" (a,b:Tangent_Key) -> bool {
    return a[0]==b[0] && a[1]==b[1] && a[2]==b[2] && a[3]==b[3] && a[4]==b[4] && a[5]==b[5] && a[6]==b[6] && a[7]==b[7]
}

@(private="file")
tangent_corner :: #force_inline proc "contextless" (tri:Tangent_Tri,rep:u32) -> int #no_bounds_check {
    for k in 0..<3 {if tri.weld[k]==rep {return k}}
    return -1
}

@(private="file")
tangent_project :: #force_inline proc "contextless" (os,ot,n:Vec3) -> (Vec3,Vec3) {
    projected_s:=tangent_normalize0(os-n*tangent_dot(n,os))
    projected_t:=tangent_normalize0(ot-n*tangent_dot(n,ot))
    return projected_s,projected_t
}

@(private="file")
tangent_sort_members :: proc (members:[]u32) #no_bounds_check {
    for i in 1..<len(members) {
        value:=members[i]
        j:=i
        for j>0 && members[j-1]>value {
            members[j]=members[j-1]
            j-=1
        }
        members[j]=value
    }
}

@(private="file")
tangent_members_equal :: proc "contextless" (a,b:[]u32) -> bool #no_bounds_check {
    if len(a)!=len(b) {return false}
    for x,i in a {if x!=b[i] {return false}}
    return true
}

@(private="file")
tangent_assign_group :: proc(tris:[]Tangent_Tri,group_tris:^[dynamic]u32,groups:[]Tangent_Group,gi,ti:int) #no_bounds_check {
    g:=&groups[gi]
    c:=tangent_corner(tris[ti],g.rep)
    if c<0 {return}
    if tris[ti].group[c]==i32(gi) {return}
    if tris[ti].group[c]!=-1 {return}
    if !tris[ti].any {
        if tris[ti].orient!=g.orient {return}
    } else if tris[ti].group[0]==-1 && tris[ti].group[1]==-1 && tris[ti].group[2]==-1 {
        tris[ti].orient=g.orient
    }
    tris[ti].group[c]=i32(gi)
    append(group_tris,u32(ti))
    g.count+=1
    incident:=[2]int{c,(c+2)%3}
    for e in incident {
        nb:=tris[ti].adj[e]
        if nb>=0 {tangent_assign_group(tris,group_tris,groups,gi,int(nb))}
    }
}

// The tangent of a subgroup: the projected tangents of its members, weighted
// by the angle of each member's corner. members index group and projected.
@(private="file")
tangent_eval :: proc(tris:[]Tangent_Tri,group,members:[]u32,projected:[][2]Vec3,n:Vec3,rep:u32,orient:bool) -> Tangent_Space #no_bounds_check {
    acc:Vec3
    for k in members {
        ti:=int(group[k])
        if tris[ti].any || tris[ti].dead {continue}
        c:=tangent_corner(tris[ti],rep)
        if c<0 {continue}
        i0,i2:=(c+2)%3,(c+1)%3
        v1:=tris[ti].p[i0]-tris[ti].p[c]
        v2:=tris[ti].p[i2]-tris[ti].p[c]
        v1=tangent_normalize0(v1-n*tangent_dot(n,v1))
        v2=tangent_normalize0(v2-n*tangent_dot(n,v2))
        cosine:=clamp(tangent_dot(v1,v2),f32(-1),f32(1))
        acc+=projected[k][0]*math.acos_f32(cosine)
    }
    sign:f32=orient?1:-1
    return {t=tangent_normalize0(acc),sign=sign}
}

// A unit vector across n: along x, unless n is, then along y.
@(private="file")
any_tangent :: proc "contextless" (n:Vec3) -> Vec3 {
    axis:=Vec3{1,0,0} if abs(n.x)<0.9 else Vec3{0,1,0}
    t:=axis-n*linalg.dot(n,axis)
    length:=linalg.length(t)
    return t/length if length>1e-6 else Vec3{1,0,0}
}

@(private="file")
triangle_in_all :: proc "contextless" (indices:[]u32,n:int) -> bool {
    for index in indices {if int(index)>=n {return false}}
    return true
}

// mesh with the tangents of its vertices: out holds it again with a vertex
// split wherever the corners that share it take different tangents (seams of
// its uvs, mirrored halves), and tangents one per vertex of out. False without
// memory or for a mesh that is not valid.
mesh_tangents :: proc(mesh:Mesh,out:^Mesh_Buffer,tangents:^[dynamic]Vec4,scratch:=context.temp_allocator) -> bool {
    if !mesh_is_valid(mesh) {return false}
    corners,no_corners:=make([]Vec4,len(mesh.indices),scratch)
    if no_corners!=nil {return false}
    defer delete(corners,scratch)
    if !corner_tangents(mesh.positions,mesh.normals,mesh.uvs,mesh.indices,corners) {return false}
    Key :: struct {vertex:u32,tangent:Vec4}
    known,no_known:=make(map[Key]u32,len(mesh.positions),scratch)
    defer delete(known)
    mesh_buffer_clear(out)
    clear(tangents)
    if no_known!=nil || reserve(&out.indices,len(mesh.indices))!=nil || reserve(&out.materials,len(mesh.materials))!=nil {return false}
    whole:=true
    for index,at in mesh.indices {
        key:=Key{index,corners[at]}
        vertex,seen:=known[key]
        if !seen {
            // A vertex the map has no memory for is written again: no index is left without one.
            vertex=u32(len(out.positions))
            known[key]=vertex
            _,no_position:=append(&out.positions,mesh.positions[index])
            whole&&=no_position==nil
            if len(mesh.normals)>0 {_,e:=append(&out.normals,mesh.normals[index]);whole&&=e==nil}
            if len(mesh.uvs)>0 {_,e:=append(&out.uvs,mesh.uvs[index]);whole&&=e==nil}
            if len(mesh.colors)>0 {_,e:=append(&out.colors,mesh.colors[index]);whole&&=e==nil}
            _,no_tangent:=append(tangents,corners[at])
            whole&&=no_tangent==nil
        }
        append(&out.indices,vertex)
    }
    append(&out.materials,..mesh.materials)
    if !whole {
        mesh_buffer_clear(out)
        clear(tangents)
    }
    return whole
}
