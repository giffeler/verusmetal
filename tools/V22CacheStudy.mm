// Paired mining-layout study. CPU oracles are compiled from the frozen baseline.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>
#include <chrono>
#include <stdexcept>
#include "../src/v22/cpu.h"
extern "C" void vm_frozen_hashes(const uint8_t *, const uint32_t *, uint32_t, uint32_t, uint8_t *, void *);
extern "C" void vm_instruction_cases(void *, void *);
extern "C" void vm_pressure_cases(void *, void *, void *);
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void require(bool yes, const char *message) { if (!yes) throw std::runtime_error(message); }
struct Parameters { uint64_t nonce; uint32_t count, stride, size, offset, bytes; };
struct Engine {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> library;
    id<MTLComputePipelineState> pipeline;
    id<MTLBuffer> input, output, scratch, matches, target;
    Parameters p;
    std::string name;
    Engine(id<MTLDevice> d, const char *variant, uint32_t count, bool validation=false) : device(d), name(variant) {
        std::string kernel=variant;
        auto separator=kernel.find(':');
        if(separator!=std::string::npos) {
            count=uint32_t(std::stoul(kernel.substr(separator+1)));
            require(count>=1 && count<=32768,"invalid per-engine count");
            kernel.resize(separator);
        }
        NSError *error = nil;
        NSString *path = [NSString stringWithFormat:@"build/v22/cache-study/%s.metallib",kernel.c_str()];
        library = [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
        require(library != nil, error.description.UTF8String);
        queue = [d newCommandQueue];
        bool cached = kernel == "cached" || kernel == "control" || kernel == "binned";
        NSString *function = cached ? (kernel == "control" ? @"verus_search_control" : kernel == "binned" ? @"verus_search_binned" : @"verus_search_cached") : @"verus_search";
        pipeline = makePipeline(function, validation);
        p = {0x123456780000ull,count,1488,1487,1476,8};
        input = buffer(cached ? 8896 : count*1488);
        output = buffer(count*32+64); scratch = buffer(count*(cached ? 8192 : 8896)+64);
        matches = buffer(count*4+64); target = buffer(32);
        memset(output.contents,0xa5,output.length); memset(scratch.contents,0xa5,scratch.length);
        memset(matches.contents,0xa5,matches.length); memset(target.contents,0xff,32);
        uint8_t bytes[1488]{};
        for (int i=0;i<1487;++i) bytes[i] = uint8_t(i*37+19);
        if (cached) vm_cpu_prepare(bytes,1487,input.contents);
        else for (uint32_t i=0;i<count;++i) memcpy((uint8_t *)input.contents+i*1488,bytes,1488);
    }
    id<MTLBuffer> buffer(NSUInteger size) { auto b = [device newBufferWithLength:size options:MTLResourceStorageModeShared]; require(b != nil,"allocation failed"); return b; }
    id<MTLComputePipelineState> makePipeline(NSString *name, bool validation) {
        MTLComputePipelineDescriptor *desc = [MTLComputePipelineDescriptor new];
        desc.computeFunction = [library newFunctionWithName:name];
        desc.maxTotalThreadsPerThreadgroup = 128;
        desc.shaderValidation = validation ? MTLShaderValidationEnabled : MTLShaderValidationDisabled;
        NSError *error = nil;
        auto state = [device newComputePipelineStateWithDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
        require(state != nil,error.description.UTF8String); return state;
    }
    std::pair<double,double> run() {
        double start = now();
        auto cb = [queue commandBuffer]; auto enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        NSArray *buffers = @[input,output,scratch,matches,target];
        for (NSUInteger i=0;i<buffers.count;++i) [enc setBuffer:buffers[i] offset:0 atIndex:i];
        [enc setBytes:&p length:sizeof(p) atIndex:5];
        [enc dispatchThreadgroups:MTLSizeMake((p.count+127)/128,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        double wall = now()-start;
        require(cb.status == MTLCommandBufferStatusCompleted,cb.error.description.UTF8String);
        return {cb.GPUEndTime-cb.GPUStartTime,wall};
    }
    void check(const std::vector<uint8_t> &expected) {
        require(memcmp(output.contents,expected.data(),expected.size()) == 0,"digest mismatch");
        for (uint32_t i=0;i<p.count;++i) require(((uint32_t *)matches.contents)[i] == 1,"missing candidate");
        for (auto b : {output,scratch,matches}) for(NSUInteger i=b.length-64;i<b.length;++i)
            require(((uint8_t *)b.contents)[i] == 0xa5,"guard overwritten");
    }
};
static std::vector<uint8_t> oracle(uint32_t count, uint64_t first) {
    alignas(16) uint8_t scratch[8896],input[1488]{};
    std::vector<uint8_t> output(count*32); uint32_t size=1487;
    for (int i=0;i<1487;++i) input[i]=uint8_t(i*37+19);
    for (uint32_t i=0;i<count;++i) {
        uint64_t nonce=first+i; memcpy(input+1476,&nonce,8);
        vm_frozen_hashes(input,&size,1488,1,output.data()+i*32,scratch);
    }
    return output;
}
static void primitives(id<MTLDevice> device) {
    NSError *error=nil;
    auto library=[device newLibraryWithURL:[NSURL fileURLWithPath:@"build/v22/cache-study/tests.metallib"] error:&error];
    require(library != nil,"test library missing");
    auto queue=[device newCommandQueue];
    auto buffer=[&](NSUInteger n) { return [device newBufferWithLength:n options:MTLResourceStorageModeShared]; };
    auto dispatch=[&](NSString *name, NSArray *buffers, uint32_t count) {
        MTLComputePipelineDescriptor *desc=[MTLComputePipelineDescriptor new];
        desc.computeFunction=[library newFunctionWithName:name]; desc.maxTotalThreadsPerThreadgroup=128;
        desc.shaderValidation=MTLShaderValidationEnabled;
        auto pipeline=[device newComputePipelineStateWithDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
        require(pipeline != nil,"test pipeline failed");
        auto cb=[queue commandBuffer]; auto enc=[cb computeCommandEncoder]; [enc setComputePipelineState:pipeline];
        for(NSUInteger i=0;i<buffers.count;++i) [enc setBuffer:buffers[i] offset:0 atIndex:i];
        [enc dispatchThreadgroups:MTLSizeMake(count/128,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; require(cb.status==MTLCommandBufferStatusCompleted,"test dispatch failed");
    };
    auto input=buffer(8192*32), expected=buffer(8192*32), output=buffer(8192*32+64);
    memset(output.contents,0xa5,output.length); vm_instruction_cases(input.contents,expected.contents);
    dispatch(@"cache_primitive_cases",@[input,output],8192);
    require(memcmp(output.contents,expected.contents,8192*32)==0,"PMULL/AES mismatch");
    for(NSUInteger i=8192*32;i<output.length;++i) require(((uint8_t *)output.contents)[i]==0xa5,"primitive guard");
    auto transposed=buffer(512*8896), initial=buffer(512*8896), final=buffer(512*8896);
    auto result=buffer(512*8896+64), writes=buffer(512*8192+64), digest=buffer(512*32+64), expectedDigest=buffer(512*32);
    vm_pressure_cases(transposed.contents,final.contents,expectedDigest.contents);
    for(int i=0;i<512;++i) for(int j=0;j<556;++j)
        memcpy((uint8_t *)initial.contents+(i*556+j)*16,(uint8_t *)transposed.contents+(j*512+i)*16,16);
    for(auto b:{result,writes,digest}) memset(b.contents,0xa5,b.length);
    for(int pass=0;pass<2;++pass) {
        dispatch(@"cache_mix_cases",@[initial,writes,result,digest],512);
        require(memcmp(result.contents,final.contents,512*8896)==0,"overlay mutations differ from frozen mix");
        require(memcmp(digest.contents,expectedDigest.contents,512*32)==0,"mix/rounded product mismatch");
        for(auto b:{result,writes,digest}) for(NSUInteger i=b.length-64;i<b.length;++i)
            require(((uint8_t *)b.contents)[i]==0xa5,"mix guard");
    }
    puts("8,192 PMULL/AES cases and 512 directed overlay mix cases passed twice, with guards and Metal validation.");
}
int main(int argc,const char **argv) { @autoreleasepool { try {
    require(argc>=2,"Usage: cache-study test | bench COUNT A B | capture COUNT VARIANT...");
    auto device=MTLCreateSystemDefaultDevice(); require(device!=nil,"Metal unavailable");
    std::string mode=argv[1];
    if(mode=="test") { primitives(device); return 0; }
    require(argc>=5,"Missing count or variants"); uint32_t count=uint32_t(std::stoul(argv[2]));
    require(count>=1 && count<=32768,"invalid count");
    std::vector<Engine> engines;
    for(int i=3;i<argc;++i) engines.emplace_back(device,argv[i],count,mode=="check");
    std::vector<std::vector<uint8_t>> expected;
    for(auto &e:engines) {
        expected.push_back(oracle(e.p.count,e.p.nonce));
        for(int pass=0;pass<2;++pass) { e.run(); e.check(expected.back()); }
        e.p.nonce += 0x700000000000ull;
        auto second=oracle(e.p.count,e.p.nonce);
        for(int pass=0;pass<2;++pass) { e.run(); e.check(second); }
        e.p.nonce -= 0x700000000000ull;
    }
    if(mode=="check") { puts("Two nonce ranges and consecutive overlay reuse passes match the frozen full CPU hash."); return 0; }
    if(mode=="capture") {
        auto manager=[MTLCaptureManager sharedCaptureManager]; auto desc=[MTLCaptureDescriptor new];
        desc.captureObject=device; desc.destination=MTLCaptureDestinationGPUTraceDocument;
        desc.outputURL=[NSURL fileURLWithPath:[NSString stringWithFormat:@"build/v22/cache-study/capture-%@.gputrace",NSUUID.UUID.UUIDString]];
        NSError *error=nil; require([manager startCaptureWithDescriptor:desc error:&error],error.description.UTF8String);
        for(auto &e:engines) e.run(); [manager stopCapture]; puts(desc.outputURL.path.UTF8String); return 0;
    }
    require(mode=="bench" && engines.size()==2,"Benchmark requires A B");
    double start=now(); do { for(auto &e:engines) e.run(); } while(now()-start<0.75);
    NSMutableArray *samples=[NSMutableArray new];
    for(int pair=0;pair<20;++pair) for(int position=0;position<2;++position) {
        int index=position^(pair&1); auto &e=engines[index]; auto [gpu,wall]=e.run(); e.check(expected[index]);
        [samples addObject:@{@"count":@(e.p.count),@"pair":@(pair),@"position":@(position),@"variant":@(e.name.c_str()),@"gpuSeconds":@(gpu),@"wallSeconds":@(wall),@"thermal":@([NSProcessInfo processInfo].thermalState)}];
    }
    NSDictionary *report=@{@"count":@(count),@"inputBytes":@1487,@"device":device.name,@"os":[NSProcessInfo processInfo].operatingSystemVersionString,@"lowPowerMode":@([NSProcessInfo processInfo].lowPowerModeEnabled),@"samples":samples};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data]; puts("");
    return 0;
} catch(const std::exception &e) { fprintf(stderr,"%s\n",e.what()); return 1; } } }
