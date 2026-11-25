// BLAKE3-256 of a byte array, as the BLAKE3 specification defines it: the
// hash mode with a 32-byte output, which is what Kai calls an address.

const IV = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19])
const PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
const CHUNK_START = 1, CHUNK_END = 2, PARENT = 4, ROOT = 8
const BLOCK = 64, CHUNK = 1024

function g(s, a, b, c, d, x, y) {
    s[a] = s[a] + s[b] + x; s[d] ^= s[a]; s[d] = s[d] >>> 16 | s[d] << 16
    s[c] = s[c] + s[d]; s[b] ^= s[c]; s[b] = s[b] >>> 12 | s[b] << 20
    s[a] = s[a] + s[b] + y; s[d] ^= s[a]; s[d] = s[d] >>> 8 | s[d] << 24
    s[c] = s[c] + s[d]; s[b] ^= s[c]; s[b] = s[b] >>> 7 | s[b] << 25
}

// The first eight words of the compression of one block: the chaining value.
function compress(cv, m, counter, length, flags) {
    const s = new Uint32Array(16)
    s.set(cv, 0)
    s.set(IV.subarray(0, 4), 8)
    s[12] = counter % 0x100000000
    s[13] = Math.floor(counter / 0x100000000)
    s[14] = length
    s[15] = flags
    let w = Uint32Array.from(m)
    for (let round = 0; round < 7; round++) {
        g(s, 0, 4, 8, 12, w[0], w[1]); g(s, 1, 5, 9, 13, w[2], w[3])
        g(s, 2, 6, 10, 14, w[4], w[5]); g(s, 3, 7, 11, 15, w[6], w[7])
        g(s, 0, 5, 10, 15, w[8], w[9]); g(s, 1, 6, 11, 12, w[10], w[11])
        g(s, 2, 7, 8, 13, w[12], w[13]); g(s, 3, 4, 9, 14, w[14], w[15])
        if (round < 6) w = Uint32Array.from(PERMUTATION, i => w[i])
    }
    for (let i = 0; i < 8; i++) s[i] ^= s[i + 8]
    return s.slice(0, 8)
}

function words(bytes, at, length) {
    const m = new Uint32Array(16)
    for (let i = 0; i < length; i++) m[i >> 2] |= bytes[at + i] << 8 * (i & 3)
    return m
}

// What a chunk gives before its last block is compressed: the root flag goes there.
function chunkLast(bytes, at, end, counter) {
    let cv = IV
    let flags = CHUNK_START
    while (end - at > BLOCK) {
        cv = compress(cv, words(bytes, at, BLOCK), counter, BLOCK, flags)
        flags = 0
        at += BLOCK
    }
    return {cv, m: words(bytes, at, end - at), counter, length: end - at, flags: flags | CHUNK_END}
}

function parentOf(left, right) {
    const m = new Uint32Array(16)
    m.set(left, 0)
    m.set(right, 8)
    return {cv: IV, m, counter: 0, length: BLOCK, flags: PARENT}
}

function chain(o) {
    return compress(o.cv, o.m, o.counter, o.length, o.flags)
}

export function blake3(bytes) {
    const chunks = Math.max(1, Math.ceil(bytes.length / CHUNK))
    const stack = []
    for (let i = 0; i < chunks - 1; i++) {
        let cv = chain(chunkLast(bytes, i * CHUNK, (i + 1) * CHUNK, i))
        for (let total = i + 1; (total & 1) === 0; total >>= 1) cv = chain(parentOf(stack.pop(), cv))
        stack.push(cv)
    }
    let o = chunkLast(bytes, (chunks - 1) * CHUNK, bytes.length, chunks - 1)
    while (stack.length > 0) o = parentOf(stack.pop(), chain(o))
    const root = compress(o.cv, o.m, 0, o.length, o.flags | ROOT)
    const out = new Uint8Array(32)
    for (let i = 0; i < 32; i++) out[i] = root[i >> 2] >>> 8 * (i & 3)
    return out
}
