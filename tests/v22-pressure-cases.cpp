// Differential oracle compiled only with the frozen, pre-optimization core.
#include "core.h"
#include <cstring>

extern "C" void vm_pressure_cases(void *initial, void *expected, void *digests) {
    auto input = static_cast<V *>(initial);
    auto output = static_cast<V *>(expected);
    auto result = static_cast<V *>(digests);
    constexpr U32 count = 512;
    U32 random = 0x9272200;
    for (U32 id = 0; id < count; ++id) {
        V work[workspaceVectors];
        for (V &v : work) for (U32 word = 0; word < 4; ++word) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            v[word] = random;
        }
        U32 lane = id & 3, operation = (id >> 2) & 7;
        bool alias = (id >> 5) & 1, rounds = (id >> 6) & 1;
        bool negative = (id >> 7) & 1, branch = (id >> 8) & 1;
        U32 second = 128 | (branch ? 15 : 0);
        U32 first = alias ? second : second + 17;
        work[513].x = lane | (operation << 2) | (first << 5)
                    | (branch ? 0x70000000u : 0) | (negative ? 0x80000000u : 0);
        work[513].y = second | (rounds ? 0xe0000000u : 0);
        V a{0x80008000u, 0x7fff8000u, 0xffff0001u, 0x00008000u};
        V b{0x80008000u, 0x80007fffu, 0x7fff8000u, 0x8000ffffu};
        work[554] = a; work[555] = b;
        for (U32 i = 0; i < workspaceVectors; ++i) input[i*count+id] = work[i];
        U64 reduced = mix(Workspace{work, 1});
        for (U32 i = 0; i < workspaceVectors; ++i) output[i*count+id] = work[i];
        result[2*id] = words(reduced, 0);
        // Signed halfword extrema and mixed signs, including non-saturating wrap.
        result[2*id+1] = roundedProduct(a, b);
    }
}
