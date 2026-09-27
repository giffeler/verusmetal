#include <metal_stdlib>
using namespace metal;
#include "constants.metal"

inline uint column(uint a, uint b, uint c, uint d) {
    return T0[a & 255] ^ rotate(T0[(b >> 8) & 255], 8u)
         ^ rotate(T0[(c >> 16) & 255], 16u) ^ rotate(T0[d >> 24], 24u);
}

inline uint4 aes_round(uint4 s, uint4 key) {
    return uint4(column(s.x, s.y, s.z, s.w), column(s.y, s.z, s.w, s.x),
                 column(s.z, s.w, s.x, s.y), column(s.w, s.x, s.y, s.z)) ^ key;
}

// One entire Haraka-512/256 v2 hash per thread. No inter-thread state or barriers.
kernel void haraka512(device const uint4 *input [[buffer(0)]],
                      device uint4 *output [[buffer(1)]],
                      constant uint &count [[buffer(2)]],
                      uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    uint4 a = input[4*gid], b = input[4*gid+1];
    uint4 c = input[4*gid+2], d = input[4*gid+3];
    // Only the eight feed-forward words used by the truncated result are needed.
    uint4 feed0 = uint4(a.zw, b.zw), feed1 = uint4(c.xy, d.xy);
    #pragma unroll
    for (uint r = 0; r < 5; ++r) {
        a = aes_round(a, RC[8*r]);   b = aes_round(b, RC[8*r+1]);
        c = aes_round(c, RC[8*r+2]); d = aes_round(d, RC[8*r+3]);
        a = aes_round(a, RC[8*r+4]); b = aes_round(b, RC[8*r+5]);
        c = aes_round(c, RC[8*r+6]); d = aes_round(d, RC[8*r+7]);
        uint4 t0 = uint4(a.w, c.w, b.w, d.w);
        uint4 t1 = uint4(c.x, a.x, d.x, b.x);
        uint4 t2 = uint4(c.y, a.y, d.y, b.y);
        uint4 t3 = uint4(a.z, c.z, b.z, d.z);
        a = t0; b = t1; c = t2; d = t3;
    }
    output[2*gid] = uint4(a.zw, b.zw) ^ feed0;
    output[2*gid+1] = uint4(c.xy, d.xy) ^ feed1;
}

// Observable, loop-carried synthetic state. Unused or volatile arrays are unsuitable:
// unused arrays disappear; volatile arrays can force memory instead of registers.
// All sizes perform 16 vector updates per Haraka round and write one uint4 checksum.
// Different dependency depths and final reductions remain experimental confounders.
template<uint N>
inline void pressure_hash(device const uint4 *input, device uint4 *output,
                          device uint4 *aux, uint gid) {
    uint4 a = input[4*gid], b = input[4*gid+1];
    uint4 c = input[4*gid+2], d = input[4*gid+3];
    uint4 feed0 = uint4(a.zw, b.zw), feed1 = uint4(c.xy, d.xy);
    uint4 state[N];
    #pragma unroll
    for (uint i = 0; i < N; ++i)
        state[i] = input[4*gid + (i % 4)] ^ uint4(0x9e3779b9u * (i+1));
    #pragma unroll
    for (uint r = 0; r < 5; ++r) {
        #pragma unroll
        for (uint k = 0; k < 16; ++k)
            state[k % N] = rotate(state[k % N] + a + uint4(k+1), uint4(7)) ^ b;
        a = aes_round(a, RC[8*r]);   b = aes_round(b, RC[8*r+1]);
        c = aes_round(c, RC[8*r+2]); d = aes_round(d, RC[8*r+3]);
        a = aes_round(a, RC[8*r+4]); b = aes_round(b, RC[8*r+5]);
        c = aes_round(c, RC[8*r+6]); d = aes_round(d, RC[8*r+7]);
        uint4 t0 = uint4(a.w, c.w, b.w, d.w);
        uint4 t1 = uint4(c.x, a.x, d.x, b.x);
        uint4 t2 = uint4(c.y, a.y, d.y, b.y);
        uint4 t3 = uint4(a.z, c.z, b.z, d.z);
        a = t0; b = t1; c = t2; d = t3;
    }
    output[2*gid] = uint4(a.zw, b.zw) ^ feed0;
    output[2*gid+1] = uint4(c.xy, d.xy) ^ feed1;
    uint4 checksum = uint4(0);
    #pragma unroll
    for (uint i = 0; i < N; ++i) checksum ^= state[i];
    aux[gid] = checksum;
}

#define PRESSURE_KERNEL(N) \
kernel void haraka_state##N(device const uint4 *input [[buffer(0)]], \
                            device uint4 *output [[buffer(1)]], \
                            constant uint &count [[buffer(2)]], \
                            device uint4 *aux [[buffer(3)]], \
                            uint gid [[thread_position_in_grid]]) { \
    if (gid < count) pressure_hash<N>(input, output, aux, gid); \
}
PRESSURE_KERNEL(1)
PRESSURE_KERNEL(4)
PRESSURE_KERNEL(8)
PRESSURE_KERNEL(16)
