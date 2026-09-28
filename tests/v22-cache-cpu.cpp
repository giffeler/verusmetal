#include "core.h"
#include "cpu.h"
#include <array>
#include <cstdio>
#include <cstring>

// Sanitizer coverage for reused overlays, short nonce fields and full-block fallback.
int main() {
    std::array<uint8_t,1487> input{};
    U64 random=0x7ab99e654123;
    auto next=[&]() { random^=random<<13; random^=random>>7; random^=random<<17; return random; };
    for(auto &b:input) b=uint8_t(next());
    alignas(16) uint8_t prepared[8896], scratch[8896], full[8896], cached[32], expected[32];
    uint32_t size=uint32_t(input.size());
    unsigned checked=0;
    for(U32 prefix=1;prefix<=14;++prefix) {
        for(U32 i=0;i<prefix;++i) input[1472+i]=uint8_t(next());
        U32 bytes=std::min(8u,15-prefix), offset=1472+prefix;
        vm_cpu_prepare(input.data(),size,prepared);
        for(int trial=0;trial<1500;++trial) {
            U64 nonce=next(); if(bytes<8) nonce &= (U64(1)<<(8*bytes))-1;
            auto patched=input;
            for(U32 i=0;i<bytes;++i) patched[offset+i]=uint8_t(nonce>>(8*i));
            vm_cpu_hashes(patched.data(),&size,size,1,expected,full);
            if(vm_cpu_finish_nonce(input.data(),size,offset,bytes,nonce,prepared,scratch,cached)!=1
               || memcmp(cached,expected,32)) return 1;
            ++checked;
        }
    }
    for(U32 offset:{0u,31u,1468u,1471u}) {
        auto patched=input; U64 nonce=next();
        for(U32 i=0;i<8;++i) patched[offset+i]=uint8_t(nonce>>(8*i));
        vm_cpu_hashes(patched.data(),&size,size,1,expected,full);
        if(vm_cpu_finish_nonce(input.data(),size,offset,8,nonce,prepared,scratch,cached)!=0
           || memcmp(cached,expected,32)) return 2;
    }
    if(vm_cpu_finish_nonce(input.data(),size,size,8,0,prepared,scratch,cached)!=-1) return 3;
    printf("ASan/UBSan: %u cached nonce comparisons, prefixes 1...14 and overlap fallback passed.\n",checked);
}
