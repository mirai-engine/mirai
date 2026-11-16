package asset

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// One .scene file against one file per entity. Run with
//   mirai test asset scene_file_against_a_file_per_entity --release -define:ASSET_BENCH=true

@(private="file") ASSET_BENCH :: #config(ASSET_BENCH,false)

@(private="file") Bench_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private="file") Bench_Mesh :: struct {mesh,material:base.Asset_Id,layer:u32,flags:u32}
@(private="file") Bench_Body :: struct {velocity,angular:[3]f32,mass,friction,restitution:f32,kind:enum u8 {Static,Dynamic,Kinematic},layer:u16}
@(private="file") Bench_Light :: struct {color:[3]f32,intensity,range:f32,kind:enum u8 {Point,Spot,Sun}}

@(private="file")
Bench_World :: struct {
    ids,parents:[]base.Entity_Id,
    orders:[]u32,
    names:[]Entity_Name,
    transforms:[]Bench_Transform,
    meshes:[]Bench_Mesh,
    bodies:[]Bench_Body,
    lights:[]Bench_Light,
    counts:[4]int,
    entities:int,
}

@(private="file")
world_make :: proc(count:int) -> (world:Bench_World) {
    world.ids,world.parents=make([]base.Entity_Id,count),make([]base.Entity_Id,count)
    world.orders,world.names=make([]u32,count),make([]Entity_Name,count)
    world.transforms,world.meshes=make([]Bench_Transform,count),make([]Bench_Mesh,count)
    world.bodies,world.lights=make([]Bench_Body,count),make([]Bench_Light,count)
    return
}
@(private="file")
world_delete :: proc(world:^Bench_World) {
    delete(world.ids);delete(world.parents);delete(world.orders);delete(world.names)
    delete(world.transforms);delete(world.meshes);delete(world.bodies);delete(world.lights)
}

@(private="file") has_mesh :: proc(i:int) -> bool {return i%5!=0}
@(private="file") has_body :: proc(i:int) -> bool {return i%10<3}
@(private="file") has_light :: proc(i:int) -> bool {return i%20==0}
@(private="file") bench_id :: proc(i:int) -> base.Entity_Id {return base.Entity_Id(u64(i+1)*0x9e3779b97f4a7c15|1)}
@(private="file") bench_transform :: proc(i:int) -> Bench_Transform {return {{f32(i%100)*1.5,f32(i%7)*0.25,f32(i/100)*1.5},1,{1,1,1}}}
@(private="file") bench_mesh :: proc(i:int) -> Bench_Mesh {return {{u64(i%40)+1,7},{u64(i%12)+1,9},u32(i%4),1}}
@(private="file") bench_body :: proc(i:int) -> Bench_Body {return {mass=f32(1+i%9),friction=0.5,restitution=0.1,kind=.Dynamic,layer=u16(i%3)}}
@(private="file") bench_light :: proc(i:int) -> Bench_Light {return {{1,0.9,0.8},f32(1+i%5),10,.Point}}

// Groups of ten: the first of each is the parent of the other nine.
@(private)
bench_scene :: proc(scene:^Scene,types:^Types,count:int) {
    scene_init(scene,types,{0xbe,0xbe})
    rows:[4][dynamic]u32
    transforms:[dynamic]Bench_Transform
    meshes:[dynamic]Bench_Mesh
    bodies:[dynamic]Bench_Body
    lights:[dynamic]Bench_Light
    for i in 0..<count {
        scene_entity_add(scene,bench_id(i),i%10==0?0:bench_id(i-i%10),fmt.tprintf("Entity_%d",i),i%10)
        append(&rows[0],u32(i));append(&transforms,bench_transform(i))
        if has_mesh(i) {append(&rows[1],u32(i));append(&meshes,bench_mesh(i))}
        if has_body(i) {append(&rows[2],u32(i));append(&bodies,bench_body(i))}
        if has_light(i) {append(&rows[3],u32(i));append(&lights,bench_light(i))}
        if i%1024==0 {free_all(context.temp_allocator)}
    }
    scene_fill(scene,"Transform",rows[0][:],transforms[:])
    scene_fill(scene,"Mesh",rows[1][:],meshes[:])
    scene_fill(scene,"Body",rows[2][:],bodies[:])
    scene_fill(scene,"Light",rows[3][:],lights[:])
    for &list in rows {delete(list)}
    delete(transforms);delete(meshes);delete(bodies);delete(lights)
}

// What a runtime does with an open scene: every column into its own arrays.
@(private="file")
world_take :: proc(world:^Bench_World,a:^Asset,types:^Types) -> bool {
    view,error:=scene_view(a,types)
    if error!=.None {return false}
    count,at:=len(view.ids),world.entities
    copy(world.ids[at:],view.ids);copy(world.parents[at:],view.parents)
    copy(world.orders[at:],view.orders);copy(world.names[at:],view.names)
    world.entities+=count
    for &component in view.components {
        rows:=len(component.entities)
        switch component.name {
        case "Transform":
            index,_:=types_index(types,Bench_Transform)
            if scene_component_read(a,&component,&types.schema,index,mem.slice_to_bytes(world.transforms[world.counts[0]:][:rows]))!=.None {return false}
            world.counts[0]+=rows
        case "Mesh":
            index,_:=types_index(types,Bench_Mesh)
            if scene_component_read(a,&component,&types.schema,index,mem.slice_to_bytes(world.meshes[world.counts[1]:][:rows]))!=.None {return false}
            world.counts[1]+=rows
        case "Body":
            index,_:=types_index(types,Bench_Body)
            if scene_component_read(a,&component,&types.schema,index,mem.slice_to_bytes(world.bodies[world.counts[2]:][:rows]))!=.None {return false}
            world.counts[2]+=rows
        case "Light":
            index,_:=types_index(types,Bench_Light)
            if scene_component_read(a,&component,&types.schema,index,mem.slice_to_bytes(world.lights[world.counts[3]:][:rows]))!=.None {return false}
            world.counts[3]+=rows
        }
    }
    return true
}

@(private="file")
world_check :: proc(t:^testing.T,world:^Bench_World,count:int,loc:=#caller_location) {
    meshes,bodies,lights:=0,0,0
    for i in 0..<count {
        if has_mesh(i) {meshes+=1}
        if has_body(i) {bodies+=1}
        if has_light(i) {lights+=1}
    }
    testing.expect(t,world.entities==count && world.counts==[4]int{count,meshes,bodies,lights},"every entity and component was loaded",loc=loc)
}

@(private="file")
load_file :: proc(world:^Bench_World,types:^Types,path:string,uncached:bool,size:int) -> bool {
    a:Asset
    data:[]u8
    defer mem.free_bytes(data,context.allocator)
    if uncached {
        ok:bool
        data,ok=bench_read_uncached(path,size,context.allocator)
        if !ok || asset_open(&a,data)!=.None {return false}
    } else if asset_load(&a,path)!=.None {
        return false
    }
    defer asset_close(&a)
    return world_take(world,&a,types)
}

@(private)
seconds :: proc(start:time.Tick) -> f64 {return time.duration_seconds(time.tick_since(start))}

@(test)
scene_file_against_a_file_per_entity :: proc(t:^testing.T) {
    when !ASSET_BENCH {return}
    else {
        // The allocator of the test runner counts every allocation; the measurement uses the heap.
        context.allocator=runtime.heap_allocator()
        types:Types;types_init(&types);defer types_destroy(&types)
        root:=base.test_folder(t,"bench")
        for count in ([]int{1000,10000,50000,100000}) {
            scene:Scene
            bench_scene(&scene,&types,count)
            defer scene_destroy(&scene)

            // One file.
            single:=fmt.aprintf("%s/scene-%d.scene",root,count)
            save_single:=max(f64)
            for _ in 0..<3 {
                start:=time.tick_now()
                testing.expect_value(t,scene_save(&scene,single),Error.None)
                save_single=min(save_single,seconds(start))
            }
            stat,_:=os.stat(single,context.temp_allocator)
            single_bytes:=int(stat.size)
            load_single,cold_single:=max(f64),f64(-1)
            for round in 0..<4 {
                world:=world_make(count)
                start:=time.tick_now()
                ok:=load_file(&world,&types,single,round==3,single_bytes)
                elapsed:=seconds(start)
                if round==3 {
                    if ok {cold_single=elapsed}
                } else {
                    testing.expect(t,ok)
                    load_single=min(load_single,elapsed)
                }
                if ok {world_check(t,&world,count)}
                world_delete(&world)
            }
            fmt.printfln("%d entities, one file: save %.2f ms, load warm %.2f ms, load uncached %.2f ms, %d bytes",count,save_single*1000,load_single*1000,cold_single*1000,single_bytes)
            if count>50000 {continue}

            // One file per entity, written the cheapest way: no temporary file, no rename.
            folder:=fmt.aprintf("%s/entities-%d",root,count)
            os.make_directory_all(folder)
            ids,parents,orders,names:=scene_ids(&scene),scene_parents(&scene),scene_orders(&scene),scene_names(&scene)
            w:serial.Writer;serial.writer_init(&w)
            start:=time.tick_now()
            for i in 0..<count {
                one:Scene
                scene_init(&one,&types,{0xbe,u64(i)})
                scene_entity_add(&one,ids[i],0,serial.text_field(names[i][:]),int(orders[i]))
                scene_parents(&one)[0]=parents[i]
                value:=bench_transform(i)
                scene_set(&one,ids[i],"Transform",&value)
                if has_mesh(i) {mesh:=bench_mesh(i);scene_set(&one,ids[i],"Mesh",&mesh)}
                if has_body(i) {body:=bench_body(i);scene_set(&one,ids[i],"Body",&body)}
                if has_light(i) {light:=bench_light(i);scene_set(&one,ids[i],"Light",&light)}
                serial.writer_reset(&w)
                written:=scene_write(&one,&w)==.None && os.write_entire_file(fmt.tprintf("%s/%016x.entity",folder,u64(ids[i])),serial.writer_bytes(&w))==nil
                scene_destroy(&one)
                if !written {testing.expect(t,false,"an entity file was not written");break}
                if i%256==0 {free_all(context.temp_allocator)}
            }
            save_many:=seconds(start)
            serial.writer_destroy(&w)
            many_bytes,many_clusters:=0,0
            load_many,cold_many:=max(f64),f64(-1)
            for round in 0..<3 {
                world:=world_make(count)
                start=time.tick_now()
                files,list_error:=os.read_all_directory_by_path(folder,context.allocator)
                ok:=list_error==nil && len(files)==count
                for info in files {
                    if !ok {break}
                    ok=load_file(&world,&types,info.fullpath,round==2,int(info.size))
                }
                elapsed:=seconds(start)
                if round==2 {
                    if ok {cold_many=elapsed}
                } else {
                    testing.expect(t,ok)
                    load_many=min(load_many,elapsed)
                }
                if ok {world_check(t,&world,count)}
                if round==0 {
                    for info in files {
                        many_bytes+=int(info.size)
                        many_clusters+=(int(info.size)+4095)/4096*4096
                    }
                }
                os.file_info_slice_delete(files,context.allocator)
                world_delete(&world)
            }
            fmt.printfln("%d entities, file per entity: save %.2f ms, load warm %.2f ms, load uncached %.2f ms, %d bytes (%d in 4 KiB clusters)",count,save_many*1000,load_many*1000,cold_many*1000,many_bytes,many_clusters)
            fmt.printfln("%d entities, file per entity / one file: save %.0fx, load warm %.0fx, load uncached %.0fx, size %.1fx",count,save_many/save_single,load_many/load_single,cold_many/cold_single,f64(many_bytes)/f64(single_bytes))
            base.remove_all(folder)
            free_all(context.temp_allocator)
        }
    }
}
