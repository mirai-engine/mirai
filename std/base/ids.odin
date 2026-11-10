package base

// Generational handle to an entity of one ecs.World. Only valid inside that world and that run.
Entity :: distinct Handle
ENTITY_NONE :: Entity(0)

// Persistent identity of an entity inside its scene or prefab. Zero is none.
Entity_Id :: distinct u64

// Persistent identity of an asset. Zero is none.
Asset_Id :: distinct [2]u64

// Stable identity of a name (component, field, event, method): FNV-1a 64.
// Everything saved or replicated refers to names through this hash.
name_hash :: proc "contextless" (name:string) -> u64 {
    hash:=HASH_SEED
    for i in 0..<len(name) {
        hash~=u64(name[i])
        hash*=0x100000001b3
    }
    return hash
}

// The name_hash of no name: where a fold of words with hash_mix starts.
HASH_SEED :: u64(0xcbf29ce484222325)

// Folds a word into a hash: the step of name_hash over the whole word, then
// its high bits brought down. A bijection of h for each v, so the order and
// the count of the words folded tell.
hash_mix :: #force_inline proc "contextless" (h,v:u64) -> u64 {
    x:=(h~v)*0x100000001b3
    return x~(x>>29)
}
hash_combine :: #force_inline proc "contextless" (a,b:u64) -> u64 {
    return a~(b+0x9e3779b97f4a7c15+(a<<6)+(a>>2))
}
