package scene

// What an entity is, for rules that match kinds of entities (a player, a
// structure, an enemy class): the game declares the values
// (TAG_PLAYER :: scene.Tag(0)), and data, the inspector and the API name them.
@(names="TAG_")
Tag :: distinct u8

@(name_bits="Tag")
Tag_Bits :: distinct u64

@(component,shared,description="The tags of an entity: the kinds of things it is, which the game names.")
Tags :: struct {bits:Tag_Bits}

TAG_LIMIT :: 64

tag_has :: proc "contextless" (tags:Tags,tag:Tag) -> bool {
    return tag<TAG_LIMIT && tags.bits&(Tag_Bits(1)<<uint(tag))!=0
}

tag_has_all :: proc "contextless" (tags,required:Tags) -> bool {
    return tags.bits&required.bits==required.bits
}

tag_has_any :: proc "contextless" (tags,choices:Tags) -> bool {
    return tags.bits&choices.bits!=0
}

// False for a tag past TAG_LIMIT.
tag_set :: proc "contextless" (tags:^Tags,tag:Tag) -> bool {
    if tags==nil || tag>=TAG_LIMIT {return false}
    tags.bits|=Tag_Bits(1)<<uint(tag)
    return true
}

// False for a tag past TAG_LIMIT.
tag_clear :: proc "contextless" (tags:^Tags,tag:Tag) -> bool {
    if tags==nil || tag>=TAG_LIMIT {return false}
    tags.bits&=~(Tag_Bits(1)<<uint(tag))
    return true
}
