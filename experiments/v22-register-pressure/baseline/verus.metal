#include "core.h"

struct Parameters { uint count; uint inputStride; };
kernel void verus_v22(device const uchar *inputs [[buffer(0)]],
                     device const uint *lengths [[buffer(1)]],
                     device uint4 *outputs [[buffer(2)]],
                     device uint4 *scratch [[buffer(3)]],
                     constant Parameters &parameters [[buffer(4)]],
                     uint tid [[thread_position_in_grid]]) {
    if (tid >= parameters.count) return;
    Workspace work{scratch+tid, parameters.count};
    hash(inputs+tid*parameters.inputStride, lengths[tid], work, outputs+2*tid);
}
