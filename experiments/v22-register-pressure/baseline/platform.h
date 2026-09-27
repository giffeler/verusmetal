#pragma once
#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
using V = uint4;
using U32 = uint;
using U64 = ulong;
#define VM_CONSTANT constant
#define VM_DEVICE device
#define VM_THREAD thread
#else
#include <cstdint>
#include <cstring>
#include <arm_neon.h>
using U32 = uint32_t;
using U64 = uint64_t;
using V = U32 __attribute__((ext_vector_type(4)));
#define VM_CONSTANT static const
#define VM_DEVICE
#define VM_THREAD
#endif
#include "constants.h"

inline U64 low(V x) { return U64(x.x) | (U64(x.y) << 32); }
inline U64 high(V x) { return U64(x.z) | (U64(x.w) << 32); }
inline V words(U64 lo, U64 hi) { return V{U32(lo), U32(lo >> 32), U32(hi), U32(hi >> 32)}; }

inline V aes(V x, V key) {
#ifdef __METAL_VERSION__
    V y;
    // ShiftRows selects one byte from each column. MixColumns is folded into T0.
    for (U32 c = 0; c != 4; ++c)
        y[c] = T0[x[c] & 255] ^ rotate(T0[(x[(c+1)&3] >> 8) & 255], 8u)
             ^ rotate(T0[(x[(c+2)&3] >> 16) & 255], 16u)
             ^ rotate(T0[x[(c+3)&3] >> 24], 24u);
    return y ^ key;
#else
    return V(vaesmcq_u8(vaeseq_u8(uint8x16_t(x), vdupq_n_u8(0)))) ^ key;
#endif
}

inline V product(U64 a, U64 b) {
#ifdef __METAL_VERSION__
    // Polynomial long multiplication: bounded live state, no lookup array.
    U64 lo = 0, hi = 0, upper = 0;
    for (U32 bit = 0; bit != 64; ++bit) {
        U64 mask = U64(0) - (a & 1);
        lo ^= b & mask;
        hi ^= upper & mask;
        upper = (upper << 1) | (b >> 63);
        b <<= 1;
        a >>= 1;
    }
    return words(lo, hi);
#else
    return V(vreinterpretq_u32_p128(vmull_p64(a, b)));
#endif
}
inline V cross(V x) { return product(low(x), high(x)); }

inline V roundedProduct(V a, V b) {
#ifdef __METAL_VERSION__
    int4 al = as_type<int4>(a << 16) >> 16, bl = as_type<int4>(b << 16) >> 16;
    int4 ah = as_type<int4>(a) >> 16, bh = as_type<int4>(b) >> 16;
    return (as_type<V>((al * bl + 16384) >> 15) & 65535u)
        | (as_type<V>((ah * bh + 16384) >> 15) << 16);
#else
    int16x8_t sa = int16x8_t(a), sb = int16x8_t(b);
    int32x4_t l = vaddq_s32(vmull_s16(vget_low_s16(sa), vget_low_s16(sb)), vdupq_n_s32(16384));
    int32x4_t h = vaddq_s32(vmull_high_s16(sa, sb), vdupq_n_s32(16384));
    // Non-saturating narrowing preserves the signed -32768 * -32768 edge case.
    return V(vcombine_s16(vshrn_n_s32(l, 15), vshrn_n_s32(h, 15)));
#endif
}

inline V remainder(V x, U32 denominator) {
    // Selector bits guarantee a nonzero divisor and exclude -1.
#ifdef __METAL_VERSION__
    long numerator = as_type<long>(low(x));
    int divisor = as_type<int>(denominator);
#else
    int64_t numerator = int64_t(low(x));
    int32_t divisor = int32_t(denominator);
#endif
    return V{U32(numerator % divisor), 0, 0, 0};
}

inline U64 reduce(V x) {
    // Reduction modulo x^64 + x^4 + x^3 + x + 1, including length binding.
    U64 h = high(x);
    U64 overflow = (h >> 63) ^ (h >> 61) ^ (h >> 60);
    return low(x) ^ U64(65536) ^ h ^ (h << 1) ^ (h << 3) ^ (h << 4)
        ^ overflow ^ (overflow << 1) ^ (overflow << 3) ^ (overflow << 4);
}
