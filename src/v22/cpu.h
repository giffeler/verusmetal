#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void vm_cpu_hashes(const uint8_t *input, const uint32_t *lengths, uint32_t stride,
                   uint32_t count, uint8_t *output, void *scratch);
int vm_primitive_test(void);
#ifdef __cplusplus
}
#endif
