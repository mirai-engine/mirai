package blake3

import "core:encoding/hex"
import "core:testing"

@(test)
hash_matches_the_official_vectors :: proc(t: ^testing.T) {
    vectors := [?]struct{length: int, expected: string}{
        {0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
        {1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"},
        {2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"},
        {3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"},
        {4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32"},
        {5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2"},
        {6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844"},
        {7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe"},
        {8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb"},
        {63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"},
        {64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"},
        {65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"},
        {127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d"},
        {128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef"},
        {129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12"},
        {1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"},
        {1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"},
        {1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"},
        {2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"},
        {2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"},
        {3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"},
        {3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3"},
        {4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"},
        {4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"},
        {5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833"},
        {5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff"},
        {6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205"},
        {6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f"},
        {7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a"},
        {7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817"},
        {8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"},
        {8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"},
        {16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"},
        {31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"},
        {102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"},
    }
    input: [102400]u8
    fill_pattern(input[:])
    for vector in vectors {
        expected: Hash
        _, ok := hex.decode_into_buffer(transmute([]u8) vector.expected, expected[:])
        testing.expectf(t, ok && hash(input[:vector.length]) == expected,
            "Official vector for %d bytes", vector.length)
    }
}

@(test)
incremental_and_group_hashes_match_the_whole_blob :: proc(t: ^testing.T) {
    sizes := [?]int{
        0, 1, 1023, 1024, 1025,
        GROUP_BYTES - 1, GROUP_BYTES, GROUP_BYTES + 1,
        2*GROUP_BYTES - 1, 2*GROUP_BYTES, 2*GROUP_BYTES + 5,
        3*GROUP_BYTES - 1, 3*GROUP_BYTES, 3*GROUP_BYTES + 5,
        5*GROUP_BYTES - 1, 5*GROUP_BYTES, 5*GROUP_BYTES + 5,
        8*GROUP_BYTES - 1, 8*GROUP_BYTES, 8*GROUP_BYTES + 5,
        9*GROUP_BYTES - 1, 9*GROUP_BYTES, 9*GROUP_BYTES + 5,
    }
    splits := [?]int{1, 63, 0, 3, 1024, 17, 65529, 131}
    sample :: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()-_"
    sample_8 :: sample + sample + sample + sample + sample + sample + sample + sample
    sample_64 :: sample_8 + sample_8 + sample_8 + sample_8 +
        sample_8 + sample_8 + sample_8 + sample_8
    sample_512 :: sample_64 + sample_64 + sample_64 + sample_64 +
        sample_64 + sample_64 + sample_64 + sample_64
    sample_4096 :: sample_512 + sample_512 + sample_512 + sample_512 +
        sample_512 + sample_512 + sample_512 + sample_512
    input := transmute([]u8) string(sample_4096 + sample_4096)
    hasher: Hasher

    for size in sizes {
        expected := hash(input[:size])
        init(&hasher)
        offset := 0
        for step := 0; offset < size; step += 1 {
            end := min(offset + splits[step % len(splits)], size)
            ok := update(&hasher, input[offset:end])
            testing.expectf(t, ok, "Update at byte %d of %d", offset, size)
            offset = end
        }
        testing.expectf(t, final(&hasher) == expected, "Incremental hash of %d bytes", size)

        if size > GROUP_BYTES {
            values: [10]Hash
            count := 1 + (size - 1) / GROUP_BYTES
            for index in 0..<count {
                start := index * GROUP_BYTES
                end := min(start + GROUP_BYTES, size)
                value, ok := group_value(input[start:end], u64(index))
                testing.expectf(t, ok, "Group %d of %d bytes", index, size)
                values[index] = value
            }
            actual, ok := root(values[:count], u64(size))
            testing.expectf(t, ok && actual == expected, "Group root of %d bytes", size)
        }
    }
}

@(test)
group_values_depend_on_the_bytes_and_the_index :: proc(t: ^testing.T) {
    input: [2*GROUP_BYTES + 5]u8
    fill_pattern(input[:])
    values: [3]Hash
    for index in 0..<len(values) {
        start := index * GROUP_BYTES
        end := min(start + GROUP_BYTES, len(input))
        value, ok := group_value(input[start:end], u64(index))
        testing.expect_value(t, ok, true)
        values[index] = value
    }
    original, original_ok := root(values[:], len(input))
    testing.expect_value(t, original_ok, true)

    middle := input[GROUP_BYTES:2*GROUP_BYTES]
    wrong_indices := [?]u64{0, 1 + (1 << 26)}
    for index in wrong_indices {
        wrong, ok := group_value(middle, index)
        testing.expect(t, ok && wrong != values[1])
    }

    middle[123] ~= 1
    changed, changed_ok := group_value(middle, 1)
    testing.expect(t, changed_ok && changed != values[1])
    values[1] = changed
    actual, ok := root(values[:], len(input))
    testing.expect(t, ok && actual != original && actual == hash(input[:]))
}

@(test)
invalid_sizes_and_group_indices_are_refused :: proc(t: ^testing.T) {
    input: [GROUP_BYTES + 1]u8
    sizes := [?]int{0, len(input)}
    for size in sizes {
        _, ok := group_value(input[:size], 0)
        testing.expectf(t, !ok, "Group of %d bytes", size)
    }
    _, index_ok := group_value(input[:1], max(u64) / 64 + 1)
    testing.expect_value(t, index_ok, false)

    values: [3]Hash
    cases := [?]struct{count: int, length: u64}{
        {0, 0}, {1, 1}, {1, GROUP_BYTES}, {0, GROUP_BYTES + 1},
        {1, GROUP_BYTES + 1}, {3, GROUP_BYTES + 1}, {3, max(u64)},
    }
    for c in cases {
        _, ok := root(values[:c.count], c.length)
        testing.expectf(t, !ok, "Root with %d groups and %d bytes", c.count, c.length)
    }
}

@(private="file")
fill_pattern :: proc "contextless" (input: []u8) {
    for _, index in input {
        input[index] = u8(index % 251)
    }
}
