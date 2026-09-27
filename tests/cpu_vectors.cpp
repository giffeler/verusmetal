#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "cpu.h"

// A small stdin/stdout adapter for the independent fixture corpus and sanitizers.
int main() {
    if (vm_primitive_test() != 0) return 1;
    alignas(16) unsigned char scratch[8896], output[32];
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
        for (auto byte : output) printf("%02x", byte);
        puts("");
    }
    free(line);
}
