#include "core.h"
#include "cpu.h"

extern "C" void vm_cpu_hashes(const uint8_t *input, const uint32_t *lengths, uint32_t stride,
                              uint32_t count, uint8_t *output, void *scratch) {
    Workspace work{static_cast<V *>(scratch), 1};
    // Serial hashes. ARM AES and PMULL operate only within the current hash.
    for (U32 i = 0; i != count; ++i)
        hash(input + size_t(i)*stride, lengths[i], work, reinterpret_cast<V *>(output) + 2*i);
}

extern "C" int vm_primitive_test() {
    V a{0x03020100, 0x07060504, 0x0b0a0908, 0x0f0e0d0c};
    V b{0x13121110, 0x17161514, 0x1b1a1918, 0x1f1e1d1c};
    V c{0x23222120, 0x27262524, 0x2b2a2928, 0x2f2e2d2c};
    V d{0x33323130, 0x37363534, 0x3b3a3938, 0x3f3e3d3c};
    haraka512<false>(a,b,c,d,Workspace{nullptr,1},0);
    // The byte vector is checked below without relying on host vector layout casts.
    const unsigned char bytes[32] = {0xbe,0x7f,0x72,0x3b,0x4e,0x80,0xa9,0x98,
        0x13,0xb2,0x92,0x28,0x7f,0x30,0x6f,0x62,0x5a,0x6d,0x57,0x33,0x1c,0xae,0x5f,0x34,
        0xdd,0x92,0x77,0xb0,0x94,0x5b,0xe2,0xaa};
    if (memcmp(&a, bytes, 16) || memcmp(&b, bytes+16, 16)) return 1;
    V edge{0x80008000,0x80008000,0x80008000,0x80008000};
    V r = roundedProduct(edge,edge);
    for (int i=0;i<4;++i) if (r[i]!=0x80008000) return 2;
    return 0;
}
