package blake3

Hash :: [32]u8
GROUP_BYTES :: 64 << 10

Hasher :: struct {
    length: u64,
    block: [BLOCK_BYTES]u8,
    chunk_value: Chaining_Value,
    tree: Tree,
}

init :: proc "contextless" (hasher: ^Hasher) {
    if hasher != nil {
        hasher^ = {}
    }
}

update :: proc "contextless" (hasher: ^Hasher, data: []u8) -> bool {
    if hasher == nil || u64(len(data)) > max(u64) - hasher.length {
        return false
    }
    update_at(hasher, data, 0)
    return true
}

final :: proc "contextless" (hasher: ^Hasher) -> Hash {
    if hasher == nil {
        return {}
    }
    return root_hash(final_node(hasher, 0))
}

hash :: proc "contextless" (data: []u8) -> Hash {
    hasher: Hasher
    update_at(&hasher, data, 0)
    return final(&hasher)
}

group_value :: proc "contextless" (data: []u8, index: u64) -> (value: Hash, ok: bool) {
    if len(data) == 0 || len(data) > GROUP_BYTES || index > max(u64) / GROUP_CHUNKS {
        return {}, false
    }
    first_chunk := index * GROUP_CHUNKS
    hasher: Hasher
    update_at(&hasher, data, first_chunk)
    return encode(compress(final_node(&hasher, first_chunk))), true
}

root :: proc "contextless" (values: []Hash, length: u64) -> (hash: Hash, ok: bool) {
    if length <= GROUP_BYTES || u64(len(values)) != 1 + (length - 1) / GROUP_BYTES {
        return {}, false
    }

    tree: Tree
    right := len(values) - 1
    for value, index in values[:right] {
        tree_push(&tree, u64(index), decode(transmute([8]u32le) value))
    }
    node := tree_fold(&tree, u64(right), decode(transmute([8]u32le) values[right]))
    return root_hash(node), true
}

@(private="file")
BLOCK_BYTES :: 64
@(private="file")
CHUNK_BYTES :: 1024
@(private="file")
GROUP_CHUNKS :: GROUP_BYTES / CHUNK_BYTES

@(private="file")
Chaining_Value :: [8]u32
@(private="file")
Tree :: [54]Chaining_Value // A u64 byte length has at most 54 bits of chunk indices.

@(private="file")
Node :: struct {
    value: Chaining_Value,
    words: [16]u32,
    counter: u64,
    block_length, flags: u32,
}

@(private="file")
IV :: Chaining_Value{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}
@(private="file")
PERMUTATION :: [16]int{2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8}
@(private="file")
CHUNK_START :: 1 << 0
@(private="file")
CHUNK_END :: 1 << 1
@(private="file")
PARENT :: 1 << 2
@(private="file")
ROOT :: 1 << 3

@(private="file")
update_at :: proc "contextless" (hasher: ^Hasher, data: []u8, first_chunk: u64) {
    remaining := data
    for len(remaining) > 0 {
        used := int(hasher.length % BLOCK_BYTES)
        // Hold a full block until another byte establishes that it is not the last block.
        if hasher.length != 0 && used == 0 {
            node := block_node(hasher, first_chunk)
            if hasher.length % CHUNK_BYTES == 0 {
                node.flags |= CHUNK_END
                tree_push(&hasher.tree, (hasher.length - 1) / CHUNK_BYTES, compress(node))
            } else {
                hasher.chunk_value = compress(node)
            }
            hasher.block = {}
        }

        take := min(BLOCK_BYTES - used, len(remaining))
        copy(hasher.block[used:used + take], remaining[:take])
        hasher.length += u64(take)
        remaining = remaining[take:]
    }
}

@(private="file")
block_node :: proc "contextless" (hasher: ^Hasher, first_chunk: u64) -> Node {
    last := max(hasher.length, 1) - 1
    node := Node{
        words = decode(transmute([16]u32le) hasher.block),
        counter = first_chunk + last / CHUNK_BYTES,
        block_length = u32(hasher.length - last / BLOCK_BYTES * BLOCK_BYTES),
    }
    if last % CHUNK_BYTES < BLOCK_BYTES {
        node.value = IV
        node.flags = CHUNK_START
    } else {
        node.value = hasher.chunk_value
    }
    return node
}

@(private="file")
final_node :: proc "contextless" (hasher: ^Hasher, first_chunk: u64) -> Node {
    node := block_node(hasher, first_chunk)
    node.flags |= CHUNK_END
    preceding := (max(hasher.length, 1) - 1) / CHUNK_BYTES
    if preceding == 0 {
        return node
    }
    return tree_fold(&hasher.tree, preceding, compress(node))
}

@(private="file")
tree_push :: proc "contextless" (tree: ^Tree, preceding: u64, value: Chaining_Value) {
    // Each set bit in the number of preceding leaves has one subtree at that height.
    pending := preceding
    merged := value
    level := 0
    for pending & 1 != 0 {
        merged = compress(parent(tree[level], merged))
        pending >>= 1
        level += 1
    }
    tree[level] = merged
}

@(private="file")
tree_fold :: proc "contextless" (tree: ^Tree, preceding: u64, right: Chaining_Value) -> Node {
    node: Node
    value := right
    pending := preceding
    for level := 0; pending != 0; level += 1 {
        if pending & 1 != 0 {
            node = parent(tree[level], value)
            if pending != 1 {
                value = compress(node)
            }
        }
        pending >>= 1
    }
    return node
}

@(private="file")
parent :: proc "contextless" (left, right: Chaining_Value) -> Node {
    node := Node{value = IV, block_length = BLOCK_BYTES, flags = PARENT}
    for word, index in left {
        node.words[index] = word
        node.words[index + 8] = right[index]
    }
    return node
}

@(private="file")
root_hash :: proc "contextless" (node: Node) -> Hash {
    output := node
    output.counter = 0
    output.flags |= ROOT
    return encode(compress(output))
}

@(private="file")
decode :: proc "contextless" (bytes: [$N]u32le) -> (words: [N]u32) {
    for word, index in bytes {
        words[index] = u32(word)
    }
    return
}

@(private="file")
encode :: proc "contextless" (value: Chaining_Value) -> Hash {
    words: [8]u32le
    for word, index in value {
        words[index] = u32le(word)
    }
    return transmute(Hash) words
}

@(private="file")
compress :: proc "contextless" (node: Node) -> (value: Chaining_Value) {
    state := [16]u32{
        node.value[0], node.value[1], node.value[2], node.value[3],
        node.value[4], node.value[5], node.value[6], node.value[7],
        IV[0], IV[1], IV[2], IV[3],
        u32(node.counter), u32(node.counter >> 32), node.block_length, node.flags,
    }
    words := node.words
    for _ in 0..<6 {
        mix_round(&state, words)
        permuted: [16]u32
        for source, index in PERMUTATION {
            permuted[index] = words[source]
        }
        words = permuted
    }
    mix_round(&state, words)
    for _, index in value {
        value[index] = state[index] ~ state[index + 8]
    }
    return
}

@(private="file")
mix_round :: proc "contextless" (state: ^[16]u32, words: [16]u32) {
    mix(state, 0, 4, 8, 12, words[0], words[1])
    mix(state, 1, 5, 9, 13, words[2], words[3])
    mix(state, 2, 6, 10, 14, words[4], words[5])
    mix(state, 3, 7, 11, 15, words[6], words[7])
    mix(state, 0, 5, 10, 15, words[8], words[9])
    mix(state, 1, 6, 11, 12, words[10], words[11])
    mix(state, 2, 7, 8, 13, words[12], words[13])
    mix(state, 3, 4, 9, 14, words[14], words[15])
}

@(private="file")
mix :: proc "contextless" (state: ^[16]u32, a, b, c, d: int, x, y: u32) {
    state[a] += state[b] + x
    state[d] = rotate_right(state[d] ~ state[a], 16)
    state[c] += state[d]
    state[b] = rotate_right(state[b] ~ state[c], 12)
    state[a] += state[b] + y
    state[d] = rotate_right(state[d] ~ state[a], 8)
    state[c] += state[d]
    state[b] = rotate_right(state[b] ~ state[c], 7)
}

@(private="file")
rotate_right :: proc "contextless" (word: u32, shift: uint) -> u32 {
    return (word >> shift) | (word << (32 - shift))
}
