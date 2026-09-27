// Untimed independent ARM-AES oracle for the synthetic side output.
#include <arm_neon.h>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include "pressure_constants.h"

extern "C" void pressure_reference(uint32_t *out, const uint8_t *in, size_t count, unsigned n) {
    for (size_t h = 0; h < count; ++h) {
        uint32_t s[4][4], extra[16][4];
        std::memcpy(s, in + h*64, 64);
        for (unsigned i = 0; i < n; ++i)
            for (unsigned j = 0; j < 4; ++j)
                extra[i][j] = s[i%4][j] ^ (0x9e3779b9u*(i+1));
        for (unsigned r = 0; r < 5; ++r) {
            for (unsigned k = 0; k < 16; ++k)
                for (unsigned j = 0; j < 4; ++j) {
                    uint32_t v = extra[k%n][j] + s[0][j] + k+1;
                    extra[k%n][j] = ((v << 7) | (v >> 25)) ^ s[1][j];
                }
            for (unsigned round = 0; round < 2; ++round)
                for (unsigned lane = 0; lane < 4; ++lane) {
                    auto value = vld1q_u8(reinterpret_cast<uint8_t *>(s[lane]));
                    auto key = vld1q_u8(reinterpret_cast<const uint8_t *>(pressureRC[8*r+4*round+lane]));
                    value = veorq_u8(vaesmcq_u8(vaeseq_u8(value, vdupq_n_u8(0))), key);
                    vst1q_u8(reinterpret_cast<uint8_t *>(s[lane]), value);
                }
            uint32_t mixed[4][4] = {
                {s[0][3],s[2][3],s[1][3],s[3][3]},
                {s[2][0],s[0][0],s[3][0],s[1][0]},
                {s[2][1],s[0][1],s[3][1],s[1][1]},
                {s[0][2],s[2][2],s[1][2],s[3][2]}};
            std::memcpy(s, mixed, 64);
        }
        for (unsigned j = 0; j < 4; ++j) {
            uint32_t sum = 0;
            for (unsigned i = 0; i < n; ++i) sum ^= extra[i][j];
            out[h*4+j] = sum;
        }
    }
}
