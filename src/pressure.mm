#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <stdexcept>
#include <vector>

extern "C" void cpu_hashes(uint8_t *, const uint8_t *, size_t);
extern "C" void pressure_reference(uint32_t *, const uint8_t *, size_t, unsigned);
using PClock = std::chrono::steady_clock;
static double elapsed(PClock::time_point t) { return std::chrono::duration<double>(PClock::now()-t).count(); }
static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static double med(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return (v[(v.size()-1)/2]+v[v.size()/2])/2;
}
struct PTime { double gpu, wall; };

int run_pressure(bool capture) {
    @autoreleasepool {
        try {
            constexpr uint32_t count = 262144;
            constexpr unsigned samples = 10, variants = 5;
            const unsigned states[variants] = {0,1,4,8,16};
            NSArray<NSString *> *names = @[@"haraka512", @"haraka_state1", @"haraka_state4", @"haraka_state8", @"haraka_state16"];
            check(pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0, "Cannot set QoS");
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            check(device != nil, "No Metal device");
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@"build/haraka.metallib"] error:&error];
            if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
            NSMutableArray<id<MTLComputePipelineState>> *pipelines = [NSMutableArray new];
            for (NSString *name in names) {
                MTLComputePipelineDescriptor *desc = [MTLComputePipelineDescriptor new];
                desc.computeFunction = [library newFunctionWithName:name];
                desc.label = name;
                desc.maxTotalThreadsPerThreadgroup = 128;
                auto pipeline = [device newComputePipelineStateWithDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
                if (!pipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
                check(pipeline.maxTotalThreadsPerThreadgroup >= 128 && 128 % pipeline.threadExecutionWidth == 0, "Unsupported group size");
                [pipelines addObject:pipeline];
            }
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLBuffer> input = [device newBufferWithLength:size_t(count)*64 options:MTLResourceStorageModeShared];
            id<MTLBuffer> output = [device newBufferWithLength:size_t(count)*32+256 options:MTLResourceStorageModeShared];
            id<MTLBuffer> aux = [device newBufferWithLength:size_t(count)*16+256 options:MTLResourceStorageModeShared];
            check(queue && input && output && aux, "Allocation failed");
            auto *in = static_cast<uint8_t *>(input.contents);
            auto *out = static_cast<uint8_t *>(output.contents);
            auto *side = static_cast<uint8_t *>(aux.contents);
            std::vector<uint8_t> cpu(size_t(count)*32);
            std::array<std::vector<uint32_t>, variants> oracle;
            uint64_t seed = 0x243f6a8885a308d3ULL;
            for (size_t i = 0; i < input.length; ++i) {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
                in[i] = uint8_t(seed >> 24);
            }
            for (unsigned i = 0; i < 64; ++i) in[i] = uint8_t(i);
            std::memset(in+64, 0, 64); std::memset(in+128, 255, 64);
            const uint8_t kat[32] = {0xbe,0x7f,0x72,0x3b,0x4e,0x80,0xa9,0x98,0x13,0xb2,0x92,0x28,0x7f,0x30,0x6f,0x62,
                0x5a,0x6d,0x57,0x33,0x1c,0xae,0x5f,0x34,0xdd,0x92,0x77,0xb0,0x94,0x5b,0xe2,0xaa};
            cpu_hashes(cpu.data(), in, count);
            check(!std::memcmp(cpu.data(), kat, 32), "CPU known-answer test failed");
            for (unsigned v = 1; v < variants; ++v) {
                oracle[v].resize(size_t(count)*4);
                pressure_reference(oracle[v].data(), in, count, states[v]);
            }
            auto dispatch = [&](unsigned v, uint32_t n) -> PTime {
                @autoreleasepool {
                    const auto start = PClock::now();
                    auto command = [queue commandBuffer];
                    check(command != nil, "Command allocation failed");
                    command.label = names[v];
                    auto encoder = [command computeCommandEncoder];
                    check(encoder != nil, "Encoder allocation failed");
                    encoder.label = names[v];
                    [encoder setComputePipelineState:pipelines[v]];
                    [encoder setBuffer:input offset:0 atIndex:0];
                    [encoder setBuffer:output offset:0 atIndex:1];
                    [encoder setBytes:&n length:sizeof(n) atIndex:2];
                    if (v) [encoder setBuffer:aux offset:0 atIndex:3];
                    [encoder dispatchThreadgroups:MTLSizeMake((n+127)/128,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];
                    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
                    const double wall = elapsed(start);
                    if (command.status != MTLCommandBufferStatusCompleted)
                        throw std::runtime_error(command.error.localizedDescription.UTF8String);
                    const double gpu = command.GPUEndTime-command.GPUStartTime;
                    check(std::isfinite(gpu) && gpu > 0, "No GPU timestamps");
                    return {gpu,wall};
                }
            };
            auto validate = [&](unsigned v, uint32_t n) {
                check(!std::memcmp(cpu.data(), out, size_t(n)*32), "Haraka digest mismatch");
                if (v) check(!std::memcmp(oracle[v].data(), side, size_t(n)*16), "Synthetic state checksum mismatch");
                for (size_t i = 0; i < 256; ++i) {
                    check(out[size_t(n)*32+i] == 0xa5, "Hash guard overwritten");
                    check(side[size_t(n)*16+i] == 0xa5, "Side-output guard overwritten");
                }
            };
            for (unsigned v = 0; v < variants; ++v) {
                for (uint32_t n : {1u,33u,257u,1027u,count}) {
                    std::memset(out,0xa5,output.length); std::memset(side,0xa5,aux.length);
                    dispatch(v,n); validate(v,n);
                }
                printf("PASS %s: known-answer test, all %u hashes, side output, tail guards\n",names[v].UTF8String,count);
            }
            NSString *directory = [@"build/pressure" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            check([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error], "Cannot create results directory");
            printf("Device %s; %s; low power %d; thermal state %ld\n",device.name.UTF8String,
                   NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
                   NSProcessInfo.processInfo.lowPowerModeEnabled,(long)NSProcessInfo.processInfo.thermalState);
            printf("Result directory: %s\n",directory.UTF8String);
            if (capture) {
                auto manager = MTLCaptureManager.sharedCaptureManager;
                check([manager supportsDestination:MTLCaptureDestinationGPUTraceDocument], "Enable MTL_CAPTURE_ENABLED=1");
                auto desc = [MTLCaptureDescriptor new];
                desc.captureObject = queue;
                desc.destination = MTLCaptureDestinationGPUTraceDocument;
                desc.outputURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"pressure.gputrace"]];
                if (![manager startCaptureWithDescriptor:desc error:&error]) throw std::runtime_error(error.localizedDescription.UTF8String);
                for (unsigned v = 0; v < variants; ++v) { dispatch(v,count); validate(v,count); }
                [manager stopCapture];
                printf("Capture: %s\n",desc.outputURL.path.UTF8String);
                return 0;
            }
            const auto warm = PClock::now();
            unsigned warmups = 0;
            do {
                cpu_hashes(cpu.data(),in,count);
                for (unsigned v = 0; v < variants; ++v) dispatch(v,count);
                ++warmups;
            } while (elapsed(warm) < 1.0);
            std::array<std::vector<double>, variants> gpuTimes, wallTimes;
            std::vector<double> cpuTimes;
            NSMutableArray *raw = [NSMutableArray new];
            for (unsigned round = 0; round < samples; ++round) {
                auto measureCPU = [&] {
                    const auto t = PClock::now(); cpu_hashes(cpu.data(),in,count);
                    const double duration = elapsed(t); cpuTimes.push_back(duration);
                    [raw addObject:@{@"sample":@(round),@"variant":@"cpu_arm_aes",@"seconds":@(duration)}];
                };
                if (!(round%2)) measureCPU();
                for (unsigned offset = 0; offset < variants; ++offset) {
                    unsigned v = (round+offset)%variants;
                    auto t = dispatch(v,count); validate(v,count);
                    gpuTimes[v].push_back(t.gpu); wallTimes[v].push_back(t.wall);
                    [raw addObject:@{@"sample":@(round),@"order":@(offset),@"variant":names[v],
                        @"gpu_seconds":@(t.gpu),@"wall_seconds":@(t.wall),
                        @"thermal_state":@(NSProcessInfo.processInfo.thermalState),
                        @"low_power":@(NSProcessInfo.processInfo.lowPowerModeEnabled)}];
                }
                if (round%2) measureCPU();
            }
            NSMutableArray *summary = [NSMutableArray new];
            printf("CPU ARM AES median %.3f MH/s; %u warm-up suites; %u samples/variant\n",count/med(cpuTimes)/1e6,warmups,samples);
            for (unsigned v = 0; v < variants; ++v) {
                const double g = count/med(gpuTimes[v])/1e6, w = count/med(wallTimes[v])/1e6;
                printf("%-16s extra %3u bytes; GPU %.3f MH/s; end-to-end %.3f MH/s\n",names[v].UTF8String,states[v]*16,g,w);
                [summary addObject:@{@"variant":names[v],@"extra_uint4":@(states[v]),@"extra_state_bytes":@(states[v]*16),
                    @"gpu_mhs":@(g),@"wall_mhs":@(w),@"simd_width":@(pipelines[v].threadExecutionWidth)}];
            }
            NSDictionary *report = @{@"device":device.name,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
                @"count":@(count),@"samples":@(samples),@"threads_per_group":@128,@"pipeline_max_threads":@128,
                @"warmup_seconds_min":@1,@"warmup_suites":@(warmups),@"cpu_mhs":@(count/med(cpuTimes)/1e6),
                @"summary":summary,@"raw":raw,@"all_validation_passed":@YES,
                @"method":@"Single CPU thread; one hash/GPU thread; shared buffers; serial CPU/GPU runs; rotating variant order. GPU timestamps cover one dispatch command buffer. Wall time covers command creation, encode, submit and wait; setup and validation excluded. Synthetic variants execute 80 vector updates and write 16 extra bytes/hash. CPU measures unchanged Haraka only."};
            auto data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
            check(data && [data writeToFile:[directory stringByAppendingPathComponent:@"timings.json"] options:NSDataWritingAtomic error:&error], "Cannot save timings");
            return 0;
        } catch (const std::exception &e) { fprintf(stderr,"Error: %s\n",e.what()); return 1; }
    }
}
