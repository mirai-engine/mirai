package ai

import "base:runtime"
import "mirai:std/base"
import math "mirai:std/math"

// A volume agents move through, flying or swimming: its free space in zones,
// cubes of NAV_VOLUME_BLOCK·2^layers voxels a side on a grid, each a sparse
// voxel octree. The root of a zone splits in eight only where free and
// blocked voxels mix, down to blocks of 4×4×4 voxels kept as the bits of a
// u64: open space is one big node, and the memory follows the surface of the
// obstacles rather than the volume. The obstacles grew by half the size of
// the agent when the zone was built, so any point of a free node or voxel is
// a place for its center. Zones are built apart and added, replaced or
// removed like the tiles of a Nav_Mesh; nodes and voxels are named by Nav_Ref
// with the generation of their zone. Adding, replacing or removing a zone
// does not allocate.

NAV_VOLUME_BLOCK :: 4       // voxels across a block, the nodes of layer 0
NAV_VOLUME_MAX_LAYERS :: 6  // above the blocks: up to 256 voxels across a zone

Nav_Volume_Cell :: enum u8 {Free,Blocked,Mixed}

// A node of an octree. Above layer 0 a Mixed node has its eight children at
// `children` in the layer below, in the order of nav_volume_octant; a Mixed
// block has the bits of its voxels, set where blocked, at voxels[children].
Nav_Volume_Node :: struct {
    children:u32,
    cell:Nav_Volume_Cell,
}

// One zone, as a build leaves it. Every slice lives in `block`.
Nav_Volume_Data :: struct {
    coord:[3]i32,
    layers:u8,                           // the root is the node of this layer
    first:[NAV_VOLUME_MAX_LAYERS+1]u32,  // where the nodes of each layer start in `nodes`; the root is nodes[first[layers]]
    nodes:[]Nav_Volume_Node,
    voxels:[]u64,
    hash:u64,                            // what the zone was built from; the builder leaves it to the caller
    block:[]byte,
    allocator:runtime.Allocator,
}

nav_volume_data_free :: proc(data:^Nav_Volume_Data) {
    if data.allocator.procedure!=nil {delete(data.block,data.allocator)}
    data^={}
}

// A zone of that many nodes and voxel blocks, zeroed, in one block.
nav_volume_data_alloc :: proc(nodes,voxels:int,allocator:=context.allocator) -> (data:Nav_Volume_Data,ok:bool) {
    if nodes<=0 || voxels<0 || nodes>1<<24 || voxels>1<<24 {return}
    block,error:=make([]byte,voxels*size_of(u64)+nodes*size_of(Nav_Volume_Node),allocator)
    if error!=nil {return}
    data.voxels=([^]u64)(raw_data(block))[:voxels]
    data.nodes=([^]Nav_Volume_Node)(rawptr(uintptr(raw_data(block))+uintptr(voxels*size_of(u64))))[:nodes]
    data.block,data.allocator=block,allocator
    return data,true
}

nav_volume_data_clone :: proc(data:^Nav_Volume_Data,allocator:=context.allocator) -> (copy_of:Nav_Volume_Data,ok:bool) {
    if len(data.block)==0 {return}
    block,error:=make([]byte,len(data.block),allocator)
    if error!=nil {return}
    copy(block,data.block)
    moved :: proc(slice:$T/[]$E,from,to:[]byte) -> T {
        if len(slice)==0 {return nil}
        offset:=uintptr(raw_data(slice))-uintptr(raw_data(from))
        return ([^]E)(rawptr(uintptr(raw_data(to))+offset))[:len(slice)]
    }
    copy_of=data^
    copy_of.block,copy_of.allocator=block,allocator
    copy_of.nodes=moved(data.nodes,data.block,block)
    copy_of.voxels=moved(data.voxels,data.block,block)
    return copy_of,true
}

Nav_Volume_Zone :: struct {
    data:Nav_Volume_Data,
    salt:u32,
    next_free:i32,
    used:bool,
}

Nav_Volume_Desc :: struct {
    origin:math.Vec3, // corner of zone (0,0,0)
    voxel:f32,        // m across a voxel
    layers:int,       // above the blocks, 0 to NAV_VOLUME_MAX_LAYERS
    max_zones:int,
    allocator:runtime.Allocator,
}

Nav_Volume :: struct {
    origin:math.Vec3,
    voxel:f32,
    layers:u8,
    zone_size:f32,             // m across a zone
    zones:[]Nav_Volume_Zone,
    free_zone:i32,
    lookup:base.Hash_Map(u32), // zone coord to slot
    revision:u64,              // changes whenever a zone is added or removed
    allocator:runtime.Allocator,
}

// volume: [23:0] cell (x, y, z, 8 bits each), [26:24] 0 for a voxel or the
// layer of a node plus 1, [45:30] zone slot, [61:46] generation, [62] set
NAV_REF_VOLUME :: u64(1)<<62
NAV_VOLUME_SALT_MASK :: u32(0xffff)
NAV_VOLUME_SLOT_MAX :: 1<<16

nav_ref_is_volume :: #force_inline proc "contextless" (ref:Nav_Ref) -> bool {return u64(ref)&(NAV_REF_LINK|NAV_REF_VOLUME)==NAV_REF_VOLUME}

// layer -1 names a voxel.
nav_volume_ref :: #force_inline proc "contextless" (salt,slot:u32,layer:int,cell:[3]i32) -> Nav_Ref {
    packed:=u64(u32(cell.x)&0xff)|u64(u32(cell.y)&0xff)<<8|u64(u32(cell.z)&0xff)<<16
    return Nav_Ref(NAV_REF_VOLUME|u64(salt&NAV_VOLUME_SALT_MASK)<<46|u64(slot&(NAV_VOLUME_SLOT_MAX-1))<<30|u64(u32(layer+1)&7)<<24|packed)
}
nav_volume_ref_salt :: #force_inline proc "contextless" (ref:Nav_Ref) -> u32 {return u32(u64(ref)>>46)&NAV_VOLUME_SALT_MASK}
nav_volume_ref_slot :: #force_inline proc "contextless" (ref:Nav_Ref) -> u32 {return u32(u64(ref)>>30)&(NAV_VOLUME_SLOT_MAX-1)}
nav_volume_ref_layer :: #force_inline proc "contextless" (ref:Nav_Ref) -> int {return int(u32(u64(ref)>>24)&7)-1}
nav_volume_ref_cell :: #force_inline proc "contextless" (ref:Nav_Ref) -> [3]i32 {
    v:=u64(ref)
    return {i32(v&0xff),i32((v>>8)&0xff),i32((v>>16)&0xff)}
}

// Which of the eight children of its parent a cell is.
nav_volume_octant :: #force_inline proc "contextless" (cell:[3]i32) -> u32 {return u32(cell.x&1)|u32(cell.y&1)<<1|u32(cell.z&1)<<2}
// The bit of a voxel in the u64 of its block.
nav_volume_voxel_bit :: #force_inline proc "contextless" (voxel:[3]i32) -> u32 {
    return u32(voxel.x&1)|u32(voxel.y&1)<<1|u32(voxel.z&1)<<2|u32((voxel.x>>1)&1)<<3|u32((voxel.y>>1)&1)<<4|u32((voxel.z>>1)&1)<<5
}

nav_volume_init :: proc(volume:^Nav_Volume,desc:Nav_Volume_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    volume^={allocator=allocator}
    if desc.max_zones<=0 || desc.max_zones>NAV_VOLUME_SLOT_MAX || desc.layers<0 || desc.layers>NAV_VOLUME_MAX_LAYERS {return false}
    if !(desc.voxel>0) || desc.voxel>1e6 {return false}
    for x in desc.origin {if !(abs(x)<=1e9) {return false}}
    error:runtime.Allocator_Error
    volume.zones,error=make([]Nav_Volume_Zone,desc.max_zones,allocator)
    if error!=nil || !base.hash_map_init(&volume.lookup,desc.max_zones,allocator) {nav_volume_destroy(volume);return false}
    volume.origin,volume.voxel,volume.layers=desc.origin,desc.voxel,u8(desc.layers)
    volume.zone_size=desc.voxel*f32(i32(NAV_VOLUME_BLOCK)<<uint(desc.layers))
    for &zone,i in volume.zones {zone.next_free=i32(i+1) if i+1<len(volume.zones) else -1;zone.salt=1}
    return true
}
nav_volume_destroy :: proc(volume:^Nav_Volume) {
    if volume.allocator.procedure!=nil {
        for &zone in volume.zones {if zone.used {nav_volume_data_free(&zone.data)}}
        delete(volume.zones,volume.allocator)
        base.hash_map_destroy(&volume.lookup)
    }
    volume^={}
}

@(private)
nav_volume_key :: #force_inline proc "contextless" (coord:[3]i32) -> u64 {
    return u64(u32(coord.x)&0x1fffff)|u64(u32(coord.y)&0x1fffff)<<21|u64(u32(coord.z)&0x1fffff)<<42
}

// The zone coordinate a point falls in.
nav_volume_coord :: proc "contextless" (volume:^Nav_Volume,point:math.Vec3) -> [3]i32 {
    if !(volume.zone_size>0) {return {}}
    coord:[3]i32
    for axis in 0..<3 {
        f:=(point[axis]-volume.origin[axis])/volume.zone_size
        switch {
        case !(f>-1e6): coord[axis]=-1_000_000
        case !(f<1e6):  coord[axis]=1_000_000
        case:
            i:=i32(f)
            coord[axis]=i-1 if f32(i)>f else i
        }
    }
    return coord
}

nav_volume_zone_box :: proc "contextless" (volume:^Nav_Volume,coord:[3]i32) -> math.Aabb {
    low:=volume.origin+math.Vec3{f32(coord.x),f32(coord.y),f32(coord.z)}*volume.zone_size
    return {low,low+volume.zone_size}
}

nav_volume_zone_at :: proc "contextless" (volume:^Nav_Volume,coord:[3]i32) -> ^Nav_Volume_Zone {
    slot,found:=base.hash_map_get(&volume.lookup,nav_volume_key(coord))
    if !found {return nil}
    return &volume.zones[slot]
}

@(private)
nav_volume_zone_slot :: #force_inline proc "contextless" (volume:^Nav_Volume,zone:^Nav_Volume_Zone) -> u32 {
    return u32((uintptr(zone)-uintptr(raw_data(volume.zones)))/size_of(Nav_Volume_Zone))
}

// The zone of a reference to a node or a voxel, or nil when it is not valid.
nav_volume_zone_of :: proc "contextless" (volume:^Nav_Volume,ref:Nav_Ref) -> ^Nav_Volume_Zone {
    if !nav_ref_is_volume(ref) {return nil}
    slot:=nav_volume_ref_slot(ref)
    if int(slot)>=len(volume.zones) {return nil}
    zone:=&volume.zones[slot]
    if !zone.used || zone.salt!=nav_volume_ref_salt(ref) {return nil}
    return zone
}

// Adds a zone, taking its data: the volume frees it when the zone is
// replaced, removed or the volume destroyed. A zone at the same coordinate is
// replaced. False, leaving the data to the caller, when its layers are not
// those of the volume, its nodes disagree or the volume has no slot left.
nav_volume_add_zone :: proc(volume:^Nav_Volume,data:Nav_Volume_Data) -> bool {
    data:=data
    if data.layers!=volume.layers || !nav_volume_data_valid(&data) {return false}
    for c in data.coord {if abs(c)>1_000_000 {return false}}
    nav_volume_remove_zone(volume,data.coord)
    if volume.free_zone<0 || len(volume.zones)==0 {return false}
    slot:=volume.free_zone
    zone:=&volume.zones[slot]
    if !base.hash_map_set(&volume.lookup,nav_volume_key(data.coord),u32(slot)) {return false}
    volume.free_zone=zone.next_free
    zone.data=data
    zone.used=true
    zone.next_free=-1
    volume.revision+=1
    return true
}

nav_volume_remove_zone :: proc(volume:^Nav_Volume,coord:[3]i32) -> bool {
    slot,found:=base.hash_map_get(&volume.lookup,nav_volume_key(coord))
    if !found {return false}
    zone:=&volume.zones[slot]
    base.hash_map_remove(&volume.lookup,nav_volume_key(coord))
    nav_volume_data_free(&zone.data)
    zone.used=false
    zone.salt=(zone.salt+1)&NAV_VOLUME_SALT_MASK
    if zone.salt==0 {zone.salt=1}
    zone.next_free=volume.free_zone
    volume.free_zone=i32(slot)
    volume.revision+=1
    return true
}

// Makes dst a copy of src, every zone in its slot: references into src are
// valid in dst. A transaction: false without memory, leaving dst empty.
nav_volume_copy :: proc(dst,src:^Nav_Volume,allocator:=context.allocator) -> bool {
    nav_volume_destroy(dst)
    if len(src.zones)==0 {return true}
    if !nav_volume_init(dst,{origin=src.origin,voxel=src.voxel,layers=int(src.layers),max_zones=len(src.zones),allocator=allocator}) {return false}
    dst.free_zone,dst.revision=src.free_zone,src.revision
    for &zone,i in src.zones {
        dst.zones[i]=zone
        dst.zones[i].data={}
        if !zone.used {continue}
        data,ok:=nav_volume_data_clone(&zone.data,allocator)
        if !ok || !base.hash_map_set(&dst.lookup,nav_volume_key(zone.data.coord),u32(i)) {
            dst.zones[i].used=false
            nav_volume_destroy(dst)
            return false
        }
        dst.zones[i].data=data
    }
    return true
}

// Whether the nodes of a zone form an octree: every child and voxel index in
// range, and each layer as long as the Mixed nodes above ask.
@(private)
nav_volume_data_valid :: proc "contextless" (data:^Nav_Volume_Data) -> bool {
    layers:=int(data.layers)
    if layers>NAV_VOLUME_MAX_LAYERS || len(data.nodes)==0 || data.first[layers]!=0 {return false}
    end :: proc "contextless" (data:^Nav_Volume_Data,k:int) -> int {return len(data.nodes) if k==0 else int(data.first[k-1])}
    for k in 0..=layers {
        if int(data.first[k])>end(data,k) || end(data,k)>len(data.nodes) {return false}
    }
    if end(data,layers)!=1 {return false}
    voxels:=0
    for k:=layers;k>=0;k-=1 {
        below:=0 if k==0 else end(data,k-1)-int(data.first[k-1])
        mixed:=0
        for node in data.nodes[data.first[k]:end(data,k)] {
            if node.cell>.Mixed {return false}
            if node.cell!=.Mixed {continue}
            if k==0 {
                if int(node.children)!=voxels {return false}
                voxels+=1
            } else if int(node.children)!=mixed*8 {return false}
            mixed+=1
        }
        if k>0 && mixed*8!=below {return false}
    }
    return voxels==len(data.voxels)
}

@(private)
nav_volume_shr :: #force_inline proc "contextless" (v:[3]i32,s:uint) -> [3]i32 {return {v.x>>s,v.y>>s,v.z>>s}}
@(private)
nav_volume_shl :: #force_inline proc "contextless" (v:[3]i32,s:uint) -> [3]i32 {return {v.x<<s,v.y<<s,v.z<<s}}

// The cell a voxel of a zone lies in, as deep as `stop` (-1: down to the
// voxel): the layer of the node (-1 for a voxel), the cell of that node or
// voxel, what it is, and the index of the node in its layer.
nav_volume_descend :: proc "contextless" (data:^Nav_Volume_Data,voxel:[3]i32,stop:=-1) -> (layer:int,cell:[3]i32,state:Nav_Volume_Cell,index:u32) {
    layer=int(data.layers)
    index=0
    for {
        node:=data.nodes[int(data.first[layer])+int(index)]
        cell=nav_volume_shr(voxel,uint(2+layer))
        state=node.cell
        if state!=.Mixed || layer<=stop {return}
        if layer==0 {
            bit:=nav_volume_voxel_bit(voxel)
            blocked:=data.voxels[node.children]&(u64(1)<<bit)!=0
            return -1,voxel,.Blocked if blocked else .Free,node.children
        }
        layer-=1
        index=node.children+nav_volume_octant(nav_volume_shr(voxel,uint(2+layer)))
    }
}

// The voxel of a zone a point lies in, and whether it is inside the zone.
nav_volume_voxel_at :: proc "contextless" (volume:^Nav_Volume,coord:[3]i32,point:math.Vec3) -> (voxel:[3]i32,inside:bool) {
    box:=nav_volume_zone_box(volume,coord)
    n:=i32(NAV_VOLUME_BLOCK<<volume.layers)
    inside=true
    for axis in 0..<3 {
        f:=(point[axis]-box.min[axis])/volume.voxel
        if !(f>=0 && f<f32(n)) {inside=false}
        i:=i32(0)
        if f>=f32(n) {i=n-1} else if f>0 {i=min(i32(f),n-1)}
        voxel[axis]=i
    }
    return
}

// The box of a node or a voxel.
nav_volume_cell_box :: proc "contextless" (volume:^Nav_Volume,coord:[3]i32,layer:int,cell:[3]i32) -> math.Aabb {
    size:=volume.voxel if layer<0 else volume.voxel*f32(i32(NAV_VOLUME_BLOCK)<<uint(layer))
    low:=nav_volume_zone_box(volume,coord).min+math.Vec3{f32(cell.x),f32(cell.y),f32(cell.z)}*size
    return {low,low+size}
}

// The box of the node or voxel a reference names, when it is valid.
nav_volume_ref_box :: proc "contextless" (volume:^Nav_Volume,ref:Nav_Ref) -> (box:math.Aabb,ok:bool) {
    zone:=nav_volume_zone_of(volume,ref)
    if zone==nil {return}
    return nav_volume_cell_box(volume,zone.data.coord,nav_volume_ref_layer(ref),nav_volume_ref_cell(ref)),true
}

// The free node or voxel a point lies in.
nav_volume_find :: proc "contextless" (volume:^Nav_Volume,point:math.Vec3) -> (ref:Nav_Ref,ok:bool) {
    if !nav_point_finite(point) {return}
    coord:=nav_volume_coord(volume,point)
    zone:=nav_volume_zone_at(volume,coord)
    if zone==nil {return}
    voxel,inside:=nav_volume_voxel_at(volume,coord,point)
    if !inside {return}
    layer,cell,state,_:=nav_volume_descend(&zone.data,voxel)
    if state!=.Free {return}
    return nav_volume_ref(zone.salt,nav_volume_zone_slot(volume,zone),layer,cell),true
}

nav_volume_ref_valid :: proc "contextless" (volume:^Nav_Volume,ref:Nav_Ref) -> bool {
    zone:=nav_volume_zone_of(volume,ref)
    if zone==nil {return false}
    layer,cell:=nav_volume_ref_layer(ref),nav_volume_ref_cell(ref)
    if layer>int(zone.data.layers) {return false}
    voxel:=cell if layer<0 else nav_volume_shl(cell,uint(2+layer))
    n:=i32(NAV_VOLUME_BLOCK<<zone.data.layers)
    if voxel.x>=n || voxel.y>=n || voxel.z>=n {return false}
    found,at,state,_:=nav_volume_descend(&zone.data,voxel,layer)
    return state==.Free && found==layer && at==cell
}
