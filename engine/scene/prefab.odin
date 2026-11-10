package scene

import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// What a prefab placed, as the entities of a world hold it: the components
// asset declares. An instance a document keeps linked has Prefab_Member on
// every entity it placed; a copy spawned while the world runs, only
// Prefab_Instance on its root.

Prefab_Instance :: asset.Prefab_Instance
Prefab_Member :: asset.Prefab_Member

// What a prefab placed with this entity as its root, also while the entity is off.
prefab_instance :: proc(w:core.World_Ref,root:core.Entity) -> (instance:Prefab_Instance,found:bool) {
    table:=core.world_table_of(w,Prefab_Instance)
    if table==nil {return}
    value:=(^Prefab_Instance)(core.raw_find(core.raw(table),type_info_of(Prefab_Instance),root))
    if value==nil {return}
    return value^,true
}

// What an entity is a member of, also while the entity is off.
prefab_member :: proc(w:core.World_Ref,e:core.Entity) -> (member:Prefab_Member,found:bool) {
    table:=core.world_table_of(w,Prefab_Member)
    if table==nil {return}
    value:=(^Prefab_Member)(core.raw_find(core.raw(table),type_info_of(Prefab_Member),e))
    if value==nil {return}
    return value^,true
}

// The root of the instance that placed an entity, with its component; NONE
// for an entity no instance placed, or whose root is no longer one.
prefab_instance_of :: proc(w:core.World_Ref,e:core.Entity) -> (root:core.Entity,instance:Prefab_Instance,member:Prefab_Member) {
    found:bool
    if member,found=prefab_member(w,e);!found {return core.NONE,{},{}}
    if instance,found=prefab_instance(w,member.instance);!found {return core.NONE,{},{}}
    return member.instance,instance,member
}

// The root of a spawned copy whose prefab, or something it takes, was not
// loaded: it is off and waits for jobs to read them, and then takes what its
// prefab places (scene_spawns).
@(component,description="A spawned copy that waits for its prefab to be read: off until it takes what the prefab places.")
Prefab_Pending :: struct {
    prefab:base.Asset_Id `mirai:"readonly"`,
}

PREFAB_WARMS :: 4 // prefabs read for spawns at once, by application

Prefab_Warm :: struct {
    prefab:base.Asset_Id,
    job:^Load_Job,
}

// The prefabs read in jobs for the spawns that wait for them, of every World
// of the application.
@(storage,host,free="prefab_warms_free")
Prefab_Warms :: struct {items:[dynamic]Prefab_Warm}

prefab_warms_free :: proc(warms:^Prefab_Warms) {
    for w in warms.items {load_cancel(w.job)}
    delete(warms.items)
    warms^={}
}

@(step="frame",loops="game editor")
scene_spawns :: proc(world:core.World_Ref,app:^host.App,warms:^Prefab_Warms,problems:^core.Problems) {
    spawns_fill(world,app,warms,problems)
}

// Moves the reads of prefabs on and gives each spawn that waits its prefab
// once it is read: the root takes what the prefab places but what it has,
// and turns on, unless the prefab turns its root off. A prefab that does not
// place takes its root away, which a problem says. With all, it waits for
// every read: what the editor and agents spawn is whole when they answer.
spawns_fill :: proc(w:core.World_Ref,app:^host.App,warms:^Prefab_Warms,problems:^core.Problems,all:=false) {
    if app==nil || app.assets==nil || warms==nil {return}
    a:=app.assets
    for i:=len(warms.items)-1;i>=0;i-=1 {
        if !load_step(warms.items[i].job,all) {continue}
        load_free(warms.items[i].job)
        unordered_remove(&warms.items,i)
    }
    pending:=core.world_table_of(w,Prefab_Pending)
    if pending==nil {return}
    t:=core.raw(pending)
    if core.raw_count(t)==0 {return}
    disabled:=core.world_table_of(w,core.Disabled)
    ids:=core.world_table_of(w,core.Id)
    forms:=core.world_storage_of(w,Prefab_Forms)
    for row in 0..<core.raw_count(t) {
        root:=t.entities[row]
        prefab:=(^Prefab_Pending)(core.raw_value(t,type_info_of(Prefab_Pending),row)).prefab
        form,entities,loaded,error:=prefab_form(forms,w,a,prefab)
        if !loaded && all {
            if job,begun:=prefab_warm_begin(app,prefab);begun==.None {
                load_step(job,true)
                load_free(job)
            }
            form,entities,loaded,error=prefab_form(forms,w,a,prefab)
        }
        if !loaded {
            warmed:=false
            for x in warms.items {warmed||=x.prefab==prefab}
            if warmed || len(warms.items)>=PREFAB_WARMS {continue}
            job,begun:=prefab_warm_begin(app,prefab)
            if begun==.None {append(&warms.items,Prefab_Warm{prefab,job});continue}
            error=begun
        }
        if error==.None {_,error=form_place(w,form,&a.types,{transient=ids==nil || core.raw_row(core.raw(ids),root)<0,fresh=true,documents=assets_documents(a),root=root},entities)}
        if error!=.None {
            name:[base.ASSET_ID_TEXT]u8
            core.report(problems,core.NONE,"scene.spawn","scene %s did not spawn: %s; open it in the editor and save it again, or spawn another",host.assets_name(a,prefab,&name),error_text(error))
            core.world_destroy_tree(w,root)
            continue
        }
        core.remove(pending,root)
        if !prefab_root_off(w,form) {core.remove(disabled,root)}
    }
}

// Whether the prefab of a form keeps its root off.
@(private)
prefab_root_off :: proc(w:core.World_Ref,form:^Form) -> bool {
    for c in form.components {
        if w.info.tables[c.table].type!=core.Disabled {continue}
        for row in c.rows {if row==form.root {return true}}
    }
    return false
}
