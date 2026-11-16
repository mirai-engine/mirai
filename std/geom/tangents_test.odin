package geom

import "core:math/linalg"
import "core:testing"

@(private="file")
tangent_close :: proc(a,b:Vec3,tolerance:f32) -> bool {
    return linalg.length(a-b)<=tolerance
}

@(test)
tangents_of_a_quad_point_along_u_and_up_the_image :: proc(t:^testing.T) {
    positions:=[4]Vec3{{0,0,0},{1,0,0},{1,1,0},{0,1,0}}
    normals:=[4]Vec3{{0,0,1},{0,0,1},{0,0,1},{0,0,1}}
    uvs:=[4]Vec2{{0,0},{1,0},{1,1},{0,1}}
    indices:=[6]u32{0,1,2,0,2,3}
    tangents:[6]Vec4
    testing.expect(t,corner_tangents(positions[:],normals[:],uvs[:],indices[:],tangents[:]))
    for tangent in tangents {
        testing.expectf(t,tangent_close(tangent.xyz,{1,0,0},1e-5),"tangent %v",tangent.xyz)
        // Mirai v grows downwards: after the 1-v reparametrization the
        // triangle is clockwise in MikkTSpace and the sign is negative.
        testing.expect(t,tangent.w<0)
        bitangent:=tangent.w*linalg.cross(Vec3{0,0,1},tangent.xyz)
        testing.expectf(t,tangent_close(bitangent,{0,-1,0},1e-5),"bitangent %v",bitangent)
    }
}

// Two halves of a quad share their uvs mirrored across x=0, as a baker lays
// out a symmetric model. The tangent turns around on the mirrored half and the
// bitangent keeps pointing up the image.
@(test)
mirrored_uvs_turn_the_tangent_and_keep_the_bitangent :: proc(t:^testing.T) {
    positions:=[6]Vec3{{-1,0,0},{0,0,0},{0,1,0},{-1,1,0},{1,0,0},{1,1,0}}
    normals:=[6]Vec3{{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,0,1}}
    uvs:=[6]Vec2{{0,0},{1,0},{1,1},{0,1},{0,0},{0,1}}
    indices:=[12]u32{0,1,2,0,2,3,1,4,5,1,5,2}
    tangents:[12]Vec4
    testing.expect(t,corner_tangents(positions[:],normals[:],uvs[:],indices[:],tangents[:]))
    for tangent,at in tangents {
        triangle:=at/3
        a,b,c:=indices[triangle*3],indices[triangle*3+1],indices[triangle*3+2]
        side:=f32(1) if positions[a].x+positions[b].x+positions[c].x>0 else f32(-1)
        testing.expectf(t,tangent_close(tangent.xyz,{-side,0,0},1e-5),"triangle %d tangent %v",triangle,tangent.xyz)
        testing.expectf(t,tangent.w==side,"triangle %d sign %v",triangle,tangent.w)
        bitangent:=tangent.w*linalg.cross(Vec3{0,0,1},tangent.xyz)
        testing.expectf(t,tangent_close(bitangent,{0,-1,0},1e-5),"triangle %d bitangent %v",triangle,bitangent)
    }
}

@(test)
tangents_do_not_depend_on_triangle_order :: proc(t:^testing.T) {
    positions:=[6]Vec3{
        {0,0,0},{1,0,0},{1,1,0},{0,1,0},{2,0.2,0.3},{2,1.3,0.1},
    }
    normals:=[6]Vec3{
        {0,0,1},{0.1,0,1},{0,0.1,1},{0,0,1},{0,0,1},{0.1,0.2,1},
    }
    uvs:=[6]Vec2{{0,0},{1,0},{1,1},{0,1},{2,0.1},{2.2,1.1}}
    order:=[4][3]u32{{0,1,2},{0,2,3},{1,4,5},{1,5,2}}
    first:[12]u32
    for triangle,i in order {
        first[i*3],first[i*3+1],first[i*3+2]=triangle[0],triangle[1],triangle[2]
    }
    permutation:=[4]int{2,0,3,1}
    second:[12]u32
    for triangle,i in permutation {
        source:=order[triangle]
        second[i*3],second[i*3+1],second[i*3+2]=source[0],source[1],source[2]
    }
    a,b:[12]Vec4
    testing.expect(t,corner_tangents(positions[:],normals[:],uvs[:],first[:],a[:]))
    testing.expect(t,corner_tangents(positions[:],normals[:],uvs[:],second[:],b[:]))
    for triangle,new in permutation {
        for corner in 0..<3 {
            old_at:=triangle*3+corner
            new_at:=new*3+corner
            testing.expectf(t,tangent_close(a[old_at].xyz,b[new_at].xyz,1e-5),
                "triangle %d corner %d: %v and %v",triangle,corner,a[old_at].xyz,b[new_at].xyz)
            testing.expectf(t,abs(a[old_at].w-b[new_at].w)<1e-6,
                "triangle %d corner %d sign: %v and %v",triangle,corner,a[old_at].w,b[new_at].w)
        }
    }
}

@(test)
tangents_of_missing_streams_and_degenerates_are_defined :: proc(t:^testing.T) {
    positions:=[5]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,0},{2,0,0}}
    indices:=[9]u32{0,1,2,3,1,2,0,4,1}
    tangents:[9]Vec4
    testing.expect(t,corner_tangents(positions[:],nil,nil,indices[:],tangents[:]))
    for tangent in tangents {
        length:=linalg.length(tangent.xyz)
        testing.expectf(t,length>0.5 && length<1.5,"tangent length %v",length)
        testing.expect(t,abs(tangent.w)==1)
        testing.expect(t,!math_is_bad(tangent.x) && !math_is_bad(tangent.y) && !math_is_bad(tangent.z))
    }
}

@(private="file")
math_is_bad :: proc(value:f32) -> bool {
    return value!=value || abs(value)>max(f32)
}

// The grid has smooth normals and a sheared uv map, so every vertex group
// and split is exercised. Each vertex keeps one tangent, the one mikktspace.c
// gives it.
@(test)
tangents_of_a_curved_grid_match_the_reference :: proc(t:^testing.T) {
    NX,NY :: 5,5
    TRI :: (NX-1)*(NY-1)*2
    reference:=[NX*NY]Vec4{
        {0.936576,0.168962,-0.307046,1},{0.979901,0.143479,-0.138589,1},
        {0.988084,0.142909,0.057164,1},{0.959215,0.137646,0.246901,1},
        {0.907334,0.108253,0.406235,1},{0.927156,0.159753,-0.338912,1},
        {0.975235,0.146418,-0.165763,1},{0.988505,0.148254,0.029651,1},
        {0.964330,0.144521,0.221770,1},{0.912180,0.125746,0.390021,1},
        {0.918965,0.142772,-0.367586,1},{0.970140,0.145540,-0.194028,1},
        {0.988936,0.148340,0.000000,1},{0.970140,0.145540,0.194028,1},
        {0.918965,0.142772,0.367586,1},{0.912180,0.125746,-0.390021,1},
        {0.964330,0.144521,-0.221770,1},{0.988505,0.148254,-0.029651,1},
        {0.975235,0.146418,0.165763,1},{0.927156,0.159753,0.338912,1},
        {0.907334,0.108253,-0.406235,1},{0.959215,0.137646,-0.246901,1},
        {0.988084,0.142909,-0.057164,1},{0.979901,0.143479,0.138589,1},
        {0.936576,0.168962,0.307046,1},
    }
    positions:[NX*NY]Vec3
    normals:[NX*NY]Vec3
    uvs:[NX*NY]Vec2
    indices:[TRI*3]u32
    i:=0
    for y in 0..<NY do for x in 0..<NX {
        fx:=f32(x)-2;fy:=f32(y)-2
        positions[i]={fx,fy,0.1*(fx*fx-fy*fy)}
        normals[i]=linalg.normalize0(Vec3{-0.2*fx,0.2*fy,1})
        uvs[i]={0.2*fx+0.05*fy+0.5,0.2*fy-0.03*fx+0.5}
        i+=1
    }
    triangle:=0
    for y in 0..<NY-1 do for x in 0..<NX-1 {
        a:=u32(y*NX+x);b:=u32((y+1)*NX+x);c:=u32((y+1)*NX+x+1);d:=u32(y*NX+x+1)
        indices[triangle*3+0]=a;indices[triangle*3+1]=b;indices[triangle*3+2]=c;triangle+=1
        indices[triangle*3+0]=a;indices[triangle*3+1]=c;indices[triangle*3+2]=d;triangle+=1
    }
    tangents:[TRI*3]Vec4
    testing.expect(t,corner_tangents(positions[:],normals[:],uvs[:],indices[:],tangents[:]))
    for tangent,at in tangents {
        want:=reference[indices[at]]
        testing.expectf(t,tangent_close(tangent.xyz,want.xyz,1e-5),"corner %d: %v, want %v",at,tangent.xyz,want.xyz)
        testing.expectf(t,tangent.w==want.w,"corner %d: sign %v, want %v",at,tangent.w,want.w)
    }
}
