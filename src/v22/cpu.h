#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void vm_cpu_hashes(const uint8_t *input, const uint32_t *lengths, uint32_t stride,
                   uint32_t count, uint8_t *output, void *scratch);
int vm_primitive_test(void);
// Prepared state and scratch each require 8,896 bytes, aligned to 16 bytes.
void vm_cpu_prepare(const uint8_t *input, uint32_t size, void *prepared);
// Returns 1 for the cached path, 0 for the full-hash fallback, -1 for invalid bounds.
int vm_cpu_finish_nonce(const uint8_t *input, uint32_t size, uint32_t nonceOffset,
                        uint32_t nonceBytes, uint64_t nonce, const void *prepared,
                        void *scratch, uint8_t *output);
#ifdef __cplusplus
}
#endif
