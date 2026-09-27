#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <stdexcept>
#include <vector>

extern "C" void cpu_hashes(uint8_t *, const uint8_t *, size_t);
int run_pressure(bool capture);
using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
static double median(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    return values[values.size()/2];
}
struct Timing { double gpu, wall; };

int main(int argc, char **argv) {
    if (argc == 2 && !std::strcmp(argv[1], "--sweep")) return run_pressure(false);
    if (argc == 2 && !std::strcmp(argv[1], "--capture-sweep")) return run_pressure(true);
    @autoreleasepool {
        try {
            const bool capture = argc == 2 && !std::strcmp(argv[1], "--capture");
            require(argc == 1 || capture, "Usage: ./build/verusmetal [--capture]");
            constexpr uint32_t count = 262144;
            constexpr unsigned samples = 5;
            // A scheduling preference, not a guarantee of a particular CPU core.
            require(pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0,
                    "Cannot set benchmark thread QoS");
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            require(device != nil, "No Metal device available");
            NSError *error = nil;
            NSURL *libraryURL = [NSURL fileURLWithPath:@"build/haraka.metallib"];
            id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&error];
            if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
            id<MTLFunction> function = [library newFunctionWithName:@"haraka512"];
            require(function != nil, "Missing haraka512 kernel");
            MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
            descriptor.computeFunction = function;
            descriptor.label = @"Haraka-512/256: one complete hash per thread";
            // A single fixed launch size; this is not a tuning sweep.
            descriptor.maxTotalThreadsPerThreadgroup = 128;
            id<MTLComputePipelineState> pipeline = [device
                newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone
                reflection:nil error:&error];
            if (!pipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
            const NSUInteger threads = 128;
            require(threads <= pipeline.maxTotalThreadsPerThreadgroup &&
                    threads % pipeline.threadExecutionWidth == 0, "Unsupported threadgroup size");
            id<MTLCommandQueue> queue = [device newCommandQueue];
            require(queue != nil, "Cannot create command queue");
            id<MTLBuffer> input = [device newBufferWithLength:size_t(count)*64
                                                   options:MTLResourceStorageModeShared];
            id<MTLBuffer> output = [device newBufferWithLength:(size_t(count)+8)*32
                                                    options:MTLResourceStorageModeShared];
            require(input && output, "Cannot allocate shared buffers");
            input.label = @"Deterministic 64-byte inputs";
            output.label = @"32-byte Haraka digests and guard";
            auto *in = static_cast<uint8_t *>(input.contents);
            auto *out = static_cast<uint8_t *>(output.contents);
            std::vector<uint8_t> cpu(size_t(count)*32);
            uint64_t seed = 0x243f6a8885a308d3ULL;
            for (size_t i = 0; i < size_t(count)*64; ++i) {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
                in[i] = uint8_t(seed >> 24);
            }
            for (unsigned i = 0; i < 64; ++i) in[i] = uint8_t(i);
            std::memset(in+64, 0, 64);
            std::memset(in+128, 255, 64);

            auto dispatch = [&](uint32_t n) -> Timing {
                const auto start = Clock::now();
                id<MTLCommandBuffer> command = [queue commandBuffer];
                require(command != nil, "Cannot allocate command buffer");
                command.label = @"Haraka architecture screening";
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                require(encoder != nil, "Cannot allocate compute encoder");
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:input offset:0 atIndex:0];
                [encoder setBuffer:output offset:0 atIndex:1];
                [encoder setBytes:&n length:sizeof(n) atIndex:2];
                [encoder dispatchThreadgroups:MTLSizeMake((n+threads-1)/threads, 1, 1)
                         threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
                [encoder endEncoding];
                [command commit];
                [command waitUntilCompleted];
                const double wall = seconds(start);
                if (command.status != MTLCommandBufferStatusCompleted)
                    throw std::runtime_error(command.error.localizedDescription.UTF8String);
                const double gpu = command.GPUEndTime - command.GPUStartTime;
                require(std::isfinite(gpu) && gpu > 0, "GPU timestamps unavailable");
                return {gpu, wall};
            };
            auto validate = [&](uint32_t n) {
                require(std::memcmp(cpu.data(), out, size_t(n)*32) == 0,
                        "CPU/GPU digest mismatch");
                for (size_t i = size_t(n)*32; i < size_t(n)*32+256; ++i)
                    require(out[i] == 0xa5, "GPU wrote past the requested output range");
            };
            const uint8_t expected[32] = {
                0xbe,0x7f,0x72,0x3b,0x4e,0x80,0xa9,0x98,0x13,0xb2,0x92,0x28,0x7f,0x30,0x6f,0x62,
                0x5a,0x6d,0x57,0x33,0x1c,0xae,0x5f,0x34,0xdd,0x92,0x77,0xb0,0x94,0x5b,0xe2,0xaa};
            cpu_hashes(cpu.data(), in, count);
            require(std::memcmp(cpu.data(), expected, 32) == 0, "Official Haraka v2 CPU vector failed");
            for (uint32_t n : {1u, 33u, 257u, 1027u, count}) {
                std::memset(out, 0xa5, output.length);
                dispatch(n);
                validate(n);
                require(std::memcmp(out, expected, 32) == 0, "Official Haraka v2 GPU vector failed");
            }
            printf("Device: %s; OS: %s\n", device.name.UTF8String,
                   NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
            printf("Haraka-512/256 v2; one CPU thread (ARM AES); one complete hash/GPU thread\n");
            printf("SIMD width: %lu; threads/group: %lu; pipeline maximum: %lu; static threadgroup bytes: %lu\n",
                   (unsigned long)pipeline.threadExecutionWidth, (unsigned long)threads,
                   (unsigned long)pipeline.maxTotalThreadsPerThreadgroup,
                   (unsigned long)pipeline.staticThreadgroupMemoryLength);
            printf("PASS: official known-answer vector, full %u-digest comparison, tail guards (1/33/257/1027/%u)\n",
                   count, count);

            if (capture) {
                MTLCaptureManager *manager = MTLCaptureManager.sharedCaptureManager;
                require([manager supportsDestination:MTLCaptureDestinationGPUTraceDocument],
                        "GPU capture unavailable; run with MTL_CAPTURE_ENABLED=1");
                MTLCaptureDescriptor *cap = [MTLCaptureDescriptor new];
                cap.captureObject = queue;
                cap.destination = MTLCaptureDestinationGPUTraceDocument;
                NSString *name = [NSString stringWithFormat:@"build/haraka-%@.gputrace", NSUUID.UUID.UUIDString];
                cap.outputURL = [NSURL fileURLWithPath:name];
                if (![manager startCaptureWithDescriptor:cap error:&error])
                    throw std::runtime_error(error.localizedDescription.UTF8String);
                dispatch(count);
                [manager stopCapture];
                validate(count);
                printf("Capture saved: %s\n", cap.outputURL.path.UTF8String);
                return 0;
            }

            // Allow clocks to settle; CPU runs and GPU dispatches remain sequential.
            const auto warmStart = Clock::now();
            unsigned warmups = 0;
            do { cpu_hashes(cpu.data(), in, count); dispatch(count); ++warmups; }
            while (seconds(warmStart) < 0.5);
            std::vector<double> cpus, gpus, walls;
            printf("Batch: %u; warm-ups: %u pairs over >=0.5 s; measured samples: %u; setup/allocation/input generation excluded\n", count, warmups, samples);
            for (unsigned i = 0; i < samples; ++i) {
                double cpuTime;
                Timing time;
                auto runCPU = [&] {
                    const auto start = Clock::now();
                    cpu_hashes(cpu.data(), in, count);
                    cpuTime = seconds(start);
                };
                if (i % 2) { time = dispatch(count); runCPU(); }
                else { runCPU(); time = dispatch(count); }
                validate(count);
                cpus.push_back(cpuTime); gpus.push_back(time.gpu); walls.push_back(time.wall);
                printf("sample %u: CPU %.3f ms; GPU execution %.3f ms; GPU wall %.3f ms\n",
                       i+1, cpuTime*1e3, time.gpu*1e3, time.wall*1e3);
            }
            const double c = median(cpus), g = median(gpus), w = median(walls);
            printf("Median: CPU %.3f MH/s (%.3f ns/hash); GPU execution %.3f MH/s; GPU wall %.3f MH/s\n",
                   count/c/1e6, c/count*1e9, count/g/1e6, count/w/1e6);
            printf("GPU/CPU throughput: %.3fx execution; %.3fx including encode/submit/wait\n", c/g, c/w);
            uint64_t checksum = 14695981039346656037ULL;
            for (size_t i = 0; i < cpu.size(); ++i) { checksum ^= out[i]; checksum *= 1099511628211ULL; }
            printf("Digest checksum: %016llx\n", (unsigned long long)checksum);
            printf("Register count, spills, and occupancy: not measured by this timing run. Use make capture and Xcode.\n");
            printf("Scope: isolated Haraka throughput on this machine; not full VerusHash or whole-CPU throughput.\n");
            return 0;
        } catch (const std::exception &e) {
            fprintf(stderr, "Error: %s\n", e.what());
            return 1;
        }
    }
}
