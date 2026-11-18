package blake3

import "base:intrinsics"
import "core:simd"

@(private)
IV :: Chaining_Value{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}
@(private="file")
MESSAGE_SCHEDULE :: [7][16]int{
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13},
}

@(private)
compress :: #force_inline proc "contextless" (
    value: ^Chaining_Value, block: [^]u8, counter: u64, length, flags: u32,
) {
    compress_lanes(value, block, u32(counter), u32(counter >> 32), length, flags)
}

@(private)
full_chunk :: proc "contextless" (data: [^]u8, counter: u64) -> Chaining_Value {
    value := IV
    compress(&value, data, counter, BLOCK_BYTES, CHUNK_START)
    for offset := BLOCK_BYTES; offset < CHUNK_BYTES - BLOCK_BYTES; offset += BLOCK_BYTES {
        compress(&value, &data[offset], counter, BLOCK_BYTES, 0)
    }
    compress(&value, &data[CHUNK_BYTES - BLOCK_BYTES], counter, BLOCK_BYTES, CHUNK_END)
    return value
}

@(private)
BATCH_CHUNKS :: 4

@(private)
full_chunks :: proc "contextless" (
    data: [^]u8, counter: u64,
) -> (values: [BATCH_CHUNKS]Chaining_Value) {
    // A lane holds one chunk, with the same word index in every lane.
    iv := IV
    chaining: [8]simd.u32x4 = ---
    #unroll for index in 0..<8 {
        chaining[index] = simd.u32x4(iv[index])
    }

    low, high: [BATCH_CHUNKS]u32 = ---, ---
    #unroll for lane in 0..<BATCH_CHUNKS {
        chunk := counter + u64(lane)
        low[lane] = u32(chunk)
        high[lane] = u32(chunk >> 32)
    }
    counter_low := transmute(simd.u32x4) low
    counter_high := transmute(simd.u32x4) high

    for offset := 0; offset < CHUNK_BYTES; offset += BLOCK_BYTES {
        flags := u32(CHUNK_START) if offset == 0 else
            u32(CHUNK_END) if offset == CHUNK_BYTES - BLOCK_BYTES else 0
        compress_lanes(&chaining, &data[offset], counter_low, counter_high, BLOCK_BYTES, flags)
    }
    #unroll for lane in 0..<BATCH_CHUNKS {
        #unroll for index in 0..<8 {
            values[lane][index] = simd.extract(chaining[index], lane)
        }
    }
    return
}

@(private="file")
compress_lanes :: proc "contextless" (
    value: ^[8]$Word, block: [^]u8, counter_low, counter_high: Word, length, flags: u32,
) #no_bounds_check {
    state: [16]Word = ---
    #unroll for index in 0..<8 {
        state[index] = value[index]
    }
    state[8] = Word(IV[0])
    state[9] = Word(IV[1])
    state[10] = Word(IV[2])
    state[11] = Word(IV[3])
    state[12] = counter_low
    state[13] = counter_high
    state[14] = Word(length)
    state[15] = Word(flags)
    // The caller supplies a full block in each lane.
    words: [16]Word = ---
    when Word == u32 {
        #unroll for index in 0..<16 {
            words[index] = u32(intrinsics.unaligned_load((^u32le)(&block[4 * index])))
        }
    } else {
        #unroll for index in 0..<4 {
            columns: [BATCH_CHUNKS]Word = ---
            #unroll for lane in 0..<BATCH_CHUNKS {
                data := &block[lane * CHUNK_BYTES + index * size_of(Word)]
                when ODIN_ENDIAN == .Little {
                    columns[lane] = intrinsics.unaligned_load((^Word)(data))
                } else {
                    decoded: [4]u32 = ---
                    #unroll for word in 0..<4 {
                        decoded[word] = u32(intrinsics.unaligned_load((^u32le)(&data[4 * word])))
                    }
                    columns[lane] = transmute(Word) decoded
                }
            }
            a, b, c, d := columns[0], columns[1], columns[2], columns[3]
            ab_even := transmute(simd.u64x2) simd.shuffle(a, b, 0, 4, 2, 6)
            ab_odd := transmute(simd.u64x2) simd.shuffle(a, b, 1, 5, 3, 7)
            cd_even := transmute(simd.u64x2) simd.shuffle(c, d, 0, 4, 2, 6)
            cd_odd := transmute(simd.u64x2) simd.shuffle(c, d, 1, 5, 3, 7)
            words[4 * index] = transmute(Word) simd.shuffle(ab_even, cd_even, 0, 2)
            words[4 * index + 1] = transmute(Word) simd.shuffle(ab_odd, cd_odd, 0, 2)
            words[4 * index + 2] = transmute(Word) simd.shuffle(ab_even, cd_even, 1, 3)
            words[4 * index + 3] = transmute(Word) simd.shuffle(ab_odd, cd_odd, 1, 3)
        }
    }
    #unroll for schedule in MESSAGE_SCHEDULE {
        #unroll for index in 0..<8 {
            // The first four mixes use columns and the last four use diagonals.
            column := index % 4
            diagonal := index / 4
            a := column
            b := 4 + (column + diagonal) % 4
            c := 8 + (column + 2 * diagonal) % 4
            d := 12 + (column + 3 * diagonal) % 4

            state[a] += state[b] + words[schedule[2 * index]]
            first_d := state[d] ~ state[a]
            state[d] = funnel_right(first_d, first_d, Word(16))
            state[c] += state[d]
            first_b := state[b] ~ state[c]
            state[b] = funnel_right(first_b, first_b, Word(12))
            state[a] += state[b] + words[schedule[2 * index + 1]]
            second_d := state[d] ~ state[a]
            state[d] = funnel_right(second_d, second_d, Word(8))
            state[c] += state[d]
            second_b := state[b] ~ state[c]
            state[b] = funnel_right(second_b, second_b, Word(7))
        }
    }
    #unroll for index in 0..<8 {
        value[index] = state[index] ~ state[index + 8]
    }
}

// The dev compiler leaves shift-and-OR rotations as separate instructions.
@(private="file")
funnel_right :: proc{funnel_right_scalar, funnel_right_vector}

@(private="file")
foreign _ {
    @(link_name="llvm.fshr.i32")
    funnel_right_scalar :: proc "none" (high, low, shift: u32) -> u32 ---

    @(link_name="llvm.fshr.v4i32")
    funnel_right_vector :: proc "none" (high, low, shift: simd.u32x4) -> simd.u32x4 ---
}
