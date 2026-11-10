package scene

import "mirai:core"
import "mirai:std/base"

// The instances of prefabs a document placed, as its entities hold them: the
// root knows its prefab, and every entity the instance placed, the root among
// them, the entity of the prefab it stands for. asset declares the same two
// for a document (asset.Instance, asset.Member), where the procedures that
// place, update and unlink instances are. A copy spawned while the world
// runs is no instance: its root has Prefab_Source.

@(component,description="The root of an instance of a prefab placed in this scene.")
Prefab_Instance :: struct {
    prefab:base.Asset_Id `mirai:"readonly,hidden"`,
    stamp:u64 `mirai:"readonly,hidden"`, // the content hash of the prefab, as resolved, it was last updated from; 0: not known
}

@(component,description="An entity an instance of a prefab placed in this scene.")
Prefab_Member :: struct {
    instance:core.Entity `mirai:"readonly,hidden"`, // the root of its instance; the root names itself
    source:u64 `mirai:"readonly,hidden"`,           // its Entity_Id in the prefab: not a reference into this scene
}

// The instance an entity is the root of, also while the entity is off.
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
