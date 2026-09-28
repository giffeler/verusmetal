#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <cstring>
#include "cpu.h"

// A small stdin/stdout adapter for the independent fixture corpus and sanitizers.
int main() {
    if (vm_primitive_test() != 0) return 1;
    alignas(16) unsigned char scratch[8896], output[32], prepared[8896], cached[32];
    char *line = nullptr;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) > 0) {
        std::string hex(line);
        if (hex.back() == '\n') hex.pop_back();
        if (hex.size() % 2 != 0) { free(line); return 2; }
        std::vector<unsigned char> input;
        for (size_t i = 0; i < hex.size(); i += 2)
            input.push_back(std::stoul(hex.substr(i, 2), nullptr, 16));
        uint32_t length = uint32_t(input.size());
        vm_cpu_hashes(input.data(), &length, length, 1, output, scratch);
        vm_cpu_prepare(input.data(), length, prepared);
        for (int pass = 0; pass < 2; ++pass) {
            if (vm_cpu_finish_nonce(input.data(), length, 0, 0, 0, prepared, scratch, cached) != 1
                || memcmp(output, cached, 32)) return 3;
        }
        for (auto byte : output) printf("%02x", byte);
        puts("");
    }
    free(line);
}
