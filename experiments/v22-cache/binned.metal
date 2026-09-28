// Research only: persistent contexts grouped by operation and variable-loop length.
// The build script extracts an unchanged single mix step from the canonical core.
#include "binned-core.h"
struct SearchParameters { ulong firstNonce; uint count, stride, inputSize, nonceOffset, nonceBytes; };
VM_INLINE uint bucket(V acc) {
    uint op=(acc.x>>2)&7, rounds=acc.w>>29;
    return op==5 ? 6+rounds : op==6 ? 14+rounds : op==7 ? 5 : op;
}
VM_INLINE void nonceSeeds(thread V *seeds, device const V *prepared, constant SearchParameters &p, ulong nonce) {
    for(uint i=0;i<4;++i) seeds[i]=prepared[552+i];
    for(uint i=0;i<p.nonceBytes;++i) {
        uint b=p.nonceOffset-(p.inputSize/32)*32+i;
        uint v=2+b/16, w=(b/4)&3, shift=8*(b&3);
        seeds[v][w]=(seeds[v][w]&~(255u<<shift))|(uint((nonce>>(8*i))&255)<<shift);
    }
}
kernel void verus_search_binned(device const V *prepared [[buffer(0)]],
                                device V *output [[buffer(1)]],
                                device V *scratch [[buffer(2)]],
                                device uint *matches [[buffer(3)]],
                                constant uint *target [[buffer(4)]],
                                constant SearchParameters &p [[buffer(5)]],
                                uint tid [[thread_position_in_grid]],
                                uint lane [[thread_index_in_threadgroup]]) {
    threadgroup uint dirty[16*128];
    threadgroup V accumulators[128];
    threadgroup uint queues[22*128];
    threadgroup atomic_uint counts[22];
    uint base=tid-lane;
    for(uint i=0;i<16;++i) dirty[i*128+lane]=0;
    accumulators[lane]=prepared[513];
    for(uint step=0;step<32;++step) {
        if(lane<22) atomic_store_explicit(counts+lane,0,memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if(tid<p.count) {
            uint bin=bucket(accumulators[lane]);
            uint slot=atomic_fetch_add_explicit(counts+bin,1,memory_order_relaxed);
            queues[bin*128+slot]=lane;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // Each SIMD group serves one uniform operation/loop-length queue at a time.
        for(uint bin=lane/32;bin<22;bin+=4) {
            uint count=atomic_load_explicit(counts+bin,memory_order_relaxed);
            for(uint slot=lane%32;slot<count;slot+=32) {
                uint context=queues[bin*128+slot], id=base+context;
                V seeds[4]; nonceSeeds(seeds,prepared,p,p.firstNonce+id);
                OverlayWorkspace work{prepared,scratch+id,dirty+context,seeds,p.count,128};
                accumulators[context]=mixStep(work,accumulators[context]);
            }
        }
        // Both overlay device writes and context/mask updates cross lane ownership.
        threadgroup_barrier(mem_flags::mem_device|mem_flags::mem_threadgroup);
    }
    if(tid>=p.count) return;
    V seeds[4]; nonceSeeds(seeds,prepared,p,p.firstNonce+tid);
    OverlayWorkspace work{prepared,scratch+tid,dirty+lane,seeds,p.count,128};
    finish(work,p.inputSize&31,reduce(accumulators[lane]),output+2*tid);
    V lo=output[2*tid],hi=output[2*tid+1]; bool accepted=true;
    for(int i=7;i>=0;--i) {
        uint word=i<4?lo[i]:hi[i-4];
        if(word!=target[i]) { accepted=word<target[i]; break; }
    }
    matches[tid]=accepted?1u:0u;
}
