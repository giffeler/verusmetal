#include "../src/v22/core.h"

kernel void cache_primitive_cases(device const uint4 *input [[buffer(0)]],
                                  device uint4 *output [[buffer(1)]],
                                  uint tid [[thread_position_in_grid]]) {
    V a = input[2*tid], b = input[2*tid+1];
    output[2*tid] = product(low(a), high(a));
    output[2*tid+1] = aes(a, b);
}

kernel void cache_mix_cases(device const V *pristine [[buffer(0)]],
                            device V *writes [[buffer(1)]],
                            device V *result [[buffer(2)]],
                            device V *digest [[buffer(3)]],
                            uint tid [[thread_position_in_grid]],
                            uint lane [[thread_index_in_threadgroup]]) {
    threadgroup uint dirty[16*128];
    // The directed-case corpus is transposed; gather each key for this test only.
    device const V *key = pristine+tid*556;
    V seeds[4];
    OverlayWorkspace work{key,writes+tid,dirty+lane,seeds,512,128};
    work.reset();
    U64 value = mix(work);
    for (uint i = 0; i < 556; ++i) result[i*512+tid] = work.get(i);
    digest[2*tid] = words(value,0);
    digest[2*tid+1] = roundedProduct(key[554],key[555]);
}
