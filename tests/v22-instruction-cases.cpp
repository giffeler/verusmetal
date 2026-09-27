// Independent ARM AES/PMULL oracle from the frozen CPU backend.
#include "platform.h"

extern "C" void vm_instruction_cases(void *inputs, void *expected) {
    auto in = static_cast<V *>(inputs);
    auto out = static_cast<V *>(expected);
    U64 random = 0x2709221415;
    auto next = [&]() {
        random ^= random << 13; random ^= random >> 7; random ^= random << 17;
        return random;
    };
    for (U32 i = 0; i < 8192; ++i) {
        // Every single-bit pair, then random full-width products and AES rounds.
        U64 a = i < 4096 ? U64(1) << (i / 64) : next();
        U64 b = i < 4096 ? U64(1) << (i % 64) : next();
        if (i == 4096) { a = 0; b = 0; }
        if (i == 4097) { a = ~U64(0); b = ~U64(0); }
        if (i == 4098) { a = 0; b = ~U64(0); }
        if (i == 4099) { a = 0xaaaaaaaaaaaaaaaaull; b = 0x5555555555555555ull; }
        U64 keyLo = next(), keyHi = next();
        in[2*i] = words(a, b); in[2*i+1] = words(keyLo, keyHi);
        out[2*i] = product(a, b);
        out[2*i+1] = aes(in[2*i], in[2*i+1]);
    }
}

extern "C" void vm_cross_cases(void *inputs, void *expected) {
    vm_instruction_cases(inputs, expected);
    auto in = static_cast<V *>(inputs);
    auto out = static_cast<V *>(expected);
    for (U32 i = 0; i < 8192; ++i)
        out[2*i+1] = cross(in[2*i]) ^ cross(in[2*i+1]);
}
