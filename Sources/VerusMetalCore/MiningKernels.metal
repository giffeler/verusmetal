#include "../../src/v22/core.h"

struct SearchParameters {
    ulong firstNonce;
    uint count;
    uint stride;
    uint inputSize;
    uint nonceOffset;
    uint nonceBytes;
};

kernel void verus_search(device uchar *inputs [[buffer(0)]],
                         device uint4 *outputs [[buffer(1)]],
                         device uint4 *scratch [[buffer(2)]],
                         device uint *matches [[buffer(3)]],
                         constant uint *target [[buffer(4)]],
                         constant SearchParameters &p [[buffer(5)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= p.count) return;
    device uchar *input = inputs + tid*p.stride;
    ulong nonce = p.firstNonce + tid;
    for (uint i = 0; i < p.nonceBytes; ++i)
        input[p.nonceOffset+i] = uchar(nonce >> (8*i));
    hash(input, p.inputSize, Workspace{scratch+tid,p.count}, outputs+2*tid);
    uint4 lo = outputs[2*tid], hi = outputs[2*tid+1];
    bool accepted = true;
    // Digests and the target buffer both use little-endian 32-bit limbs.
    for (int i = 7; i >= 0; --i) {
        uint word = i < 4 ? lo[i] : hi[i-4];
        if (word != target[i]) { accepted = word < target[i]; break; }
    }
    matches[tid] = accepted ? 1u : 0u;
}
