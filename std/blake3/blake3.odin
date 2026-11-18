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
    return finish(hasher, 0, ROOT)
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
    return finish(&hasher, first_chunk, 0), true
}

root :: proc "contextless" (values: []Hash, length: u64) -> (hash: Hash, ok: bool) {
    if length <= GROUP_BYTES || u64(len(values)) != 1 + (length - 1) / GROUP_BYTES {
        return {}, false
    }

    tree: Tree
    right := len(values) - 1
    for group, index in values[:right] {
        value := decode_hash(group)
        tree_push(&tree, u64(index), &value)
    }
    value := decode_hash(values[right])
    tree_fold(&tree, u64(right), &value, ROOT)
    return encode(value), true
}

@(private)
BLOCK_BYTES :: 64
@(private)
CHUNK_BYTES :: 1024
@(private="file")
GROUP_CHUNKS :: GROUP_BYTES / CHUNK_BYTES

@(private)
Chaining_Value :: [8]u32
@(private="file")
Tree :: [54]Chaining_Value // A u64 byte length has at most 54 bits of chunk indices.

@(private)
CHUNK_START :: 1 << 0
@(private)
CHUNK_END :: 1 << 1
@(private="file")
PARENT :: 1 << 2
@(private="file")
ROOT :: 1 << 3

@(private="file")
update_at :: proc "contextless" (hasher: ^Hasher, data: []u8, first_chunk: u64) {
    if len(data) == 0 {
        return
    }

    remaining := data
    if hasher.length != 0 {
        preceding := (hasher.length - 1) / CHUNK_BYTES
        used := int(1 + (hasher.length - 1) % CHUNK_BYTES)
        take := min(CHUNK_BYTES - used, len(remaining))
        append_chunk(hasher, remaining[:take], used, first_chunk + preceding)
        if take == len(remaining) {
            return
        }
        value := finish_chunk(hasher, CHUNK_BYTES, first_chunk + preceding, 0)
        tree_push(&hasher.tree, preceding, &value)
        remaining = remaining[take:]
    }

    preceding := hasher.length / CHUNK_BYTES
    // The final block must remain available for the CHUNK_END and ROOT flags.
    for len(remaining) > BATCH_CHUNKS * CHUNK_BYTES {
        batch := full_chunks(raw_data(remaining), first_chunk + preceding)
        for &value in batch {
            tree_push(&hasher.tree, preceding, &value)
            preceding += 1
        }
        remaining = remaining[BATCH_CHUNKS * CHUNK_BYTES:]
    }
    for len(remaining) > CHUNK_BYTES {
        value := full_chunk(raw_data(remaining), first_chunk + preceding)
        tree_push(&hasher.tree, preceding, &value)
        preceding += 1
        remaining = remaining[CHUNK_BYTES:]
    }
    hasher.length = preceding * CHUNK_BYTES
    append_chunk(hasher, remaining, 0, first_chunk + preceding)
}

@(private="file")
append_chunk :: proc "contextless" (hasher: ^Hasher, data: []u8, used: int, counter: u64) {
    if len(data) == 0 {
        return
    }

    hasher.length += u64(len(data))
    remaining := data
    flags: u32 = CHUNK_START
    if used > 0 {
        buffered := 1 + (used - 1) % BLOCK_BYTES
        take := min(BLOCK_BYTES - buffered, len(remaining))
        copy(hasher.block[buffered:buffered + take], remaining[:take])
        if take == len(remaining) {
            return
        }
        if used <= BLOCK_BYTES {
            hasher.chunk_value = IV
        } else {
            flags = 0
        }
        compress(&hasher.chunk_value, raw_data(hasher.block[:]), counter, BLOCK_BYTES, flags)
        flags = 0
        remaining = remaining[take:]
    } else {
        hasher.chunk_value = IV
    }

    for len(remaining) > BLOCK_BYTES {
        compress(&hasher.chunk_value, raw_data(remaining), counter, BLOCK_BYTES, flags)
        flags = 0
        remaining = remaining[BLOCK_BYTES:]
    }
    copy(hasher.block[:], remaining)
}

@(private="file")
finish_chunk :: proc "contextless" (
    hasher: ^Hasher, used: int, counter: u64, flags: u32,
) -> Chaining_Value {
    value := IV
    mode := flags | CHUNK_END | CHUNK_START
    if used > BLOCK_BYTES {
        value = hasher.chunk_value
        mode &= ~u32(CHUNK_START)
    }
    buffered := used - max(used - 1, 0) / BLOCK_BYTES * BLOCK_BYTES
    if buffered == BLOCK_BYTES {
        compress(&value, raw_data(hasher.block[:]), counter, BLOCK_BYTES, mode)
    } else {
        padded: [BLOCK_BYTES]u8
        copy(padded[:], hasher.block[:buffered])
        compress(&value, raw_data(padded[:]), counter, u32(buffered), mode)
    }
    return value
}

@(private="file")
finish :: proc "contextless" (hasher: ^Hasher, first_chunk: u64, flags: u32) -> Hash {
    preceding := (max(hasher.length, 1) - 1) / CHUNK_BYTES
    used := int(hasher.length - preceding * CHUNK_BYTES)
    if preceding == 0 {
        return encode(finish_chunk(hasher, used, first_chunk, flags))
    }
    value := finish_chunk(hasher, used, first_chunk + preceding, 0)
    tree_fold(&hasher.tree, preceding, &value, flags)
    return encode(value)
}

@(private="file")
tree_push :: proc "contextless" (tree: ^Tree, preceding: u64, value: ^Chaining_Value) {
    // Each set bit in the number of preceding leaves has one subtree at that height.
    pending := preceding
    level := 0
    for pending & 1 != 0 {
        merge_parent(&tree[level], value, 0)
        pending >>= 1
        level += 1
    }
    tree[level] = value^
}

@(private="file")
tree_fold :: proc "contextless" (
    tree: ^Tree, preceding: u64, right: ^Chaining_Value, flags: u32,
) {
    pending := preceding
    for level := 0; pending != 0; level += 1 {
        if pending & 1 != 0 {
            merge_parent(&tree[level], right, flags if pending == 1 else 0)
        }
        pending >>= 1
    }
}

@(private="file")
merge_parent :: proc "contextless" (left, right: ^Chaining_Value, flags: u32) {
    words: [16]u32le = ---
    #unroll for index in 0..<8 {
        words[index] = u32le(left[index])
        words[index + 8] = u32le(right[index])
    }
    right^ = IV
    compress(right, ([^]u8)(&words), 0, BLOCK_BYTES, PARENT | flags)
}

@(private="file")
decode_hash :: proc "contextless" (hash: Hash) -> (value: Chaining_Value) {
    words := transmute([8]u32le) hash
    #unroll for index in 0..<8 {
        value[index] = u32(words[index])
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
