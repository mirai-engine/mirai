package scene

import "mirai:asset"
import "mirai:core"

// What a prefab placed, as the entities of a world hold it: the two
// components asset declares, for a document and for a world alike. The root
// of anything a prefab placed has Prefab_Instance, which names the prefab:
// whatever asks what prefab an entity is reads it. An instance a document
// keeps linked has, besides, Prefab_Member on every entity it placed, the
// root among them; a copy spawned while the world runs (scene.spawn) has
// none, and no document holds its Prefab_Instance.

Prefab_Instance :: asset.Prefab_Instance
Prefab_Member :: asset.Prefab_Member

// What a prefab placed with this entity as its root, an instance or a spawned
// copy, also while the entity is off.
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
