CXX := xcrun clang++
CXXFLAGS := -O3 -std=c++17 -mcpu=native -Wall -Wextra

.PHONY: all run capture sweep capture-sweep v22 run-v22 test-v22 validate-v22 capture-v22 sanitize-v22 register-study-v22 test-register-v22 instruction-study-v22 test-instructions-v22 parallel-study-v22 test-parallel-v22
all: miner

screening: build/verusmetal build/haraka.metallib v22

build:
	mkdir -p build

build/cpu.o: src/cpu.cpp | build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/pressure_reference.o: src/pressure_reference.cpp src/pressure_constants.h | build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/verusmetal: src/main.mm src/pressure.mm build/cpu.o build/pressure_reference.o | build
	$(CXX) $(CXXFLAGS) -fobjc-arc $^ -framework Foundation -framework Metal -o $@

build/haraka.metallib: src/haraka.metal src/constants.metal | build
	xcrun metal -O3 -frecord-sources -c $< -o build/haraka.air
	xcrun metallib build/haraka.air -o $@

run: screening
	./build/verusmetal

capture: screening
	MTL_CAPTURE_ENABLED=1 ./build/verusmetal --capture

sweep: screening
	./build/verusmetal --sweep

capture-sweep: screening
	MTL_CAPTURE_ENABLED=1 ./build/verusmetal --capture-sweep

build/v22:
	mkdir -p $@

build/v22/cpu.o: src/v22/cpu.cpp src/v22/cpu.h src/v22/core.h src/v22/platform.h src/v22/constants.h | build/v22
	$(CXX) -O3 -std=c++20 -mcpu=native -Wall -Wextra -Werror -c $< -o $@

build/v22/verusbench: src/v22/Benchmark.swift src/v22/cpu.h build/v22/cpu.o | build/v22
	xcrun swiftc -O -whole-module-optimization -swift-version 6 -target arm64-apple-macos27.0 -warnings-as-errors -import-objc-header src/v22/cpu.h $< build/v22/cpu.o -lc++ -framework Metal -o $@

build/v22/verus.metallib: src/v22/verus.metal src/v22/core.h src/v22/platform.h src/v22/constants.h | build/v22
	xcrun metal -std=metal4.0 -O3 -frecord-sources -c $< -o build/v22/verus.air
	xcrun metallib build/v22/verus.air -o $@

v22: build/v22/verusbench build/v22/verus.metallib

run-v22: v22
	./build/v22/verusbench

test-v22: v22
	./build/v22/verusbench --test

validate-v22: v22
	./build/v22/verusbench --test --validate

capture-v22: v22
	MTL_CAPTURE_ENABLED=1 ./build/v22/verusbench --capture

sanitize-v22: | build/v22
	$(CXX) -std=c++20 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -mcpu=native -Isrc/v22 tests/cpu_vectors.cpp src/v22/cpu.cpp -o build/v22/check-sanitized
	python3 tests/check_cpu.py

register-study-v22:
	python3 tools/v22_register_variants.py
	python3 tools/v22_register_study.py

test-register-v22: register-study-v22
	./build/v22/register-study/study test 64 baseline e1_finish e1_parity e1_selector e2_late e2_split e3_halves e4_reload e2_aes_key e5_product e5_rounds e5_aes e1_dispatch e4_snapshot e5_aes2

instruction-study-v22:
	python3 tools/v22_register_variants.py baseline
	python3 tools/v22_instruction_variants.py
	python3 tools/v22_instruction_variants.py i12_combined
	python3 tools/v22_register_study.py

test-instructions-v22: instruction-study-v22
	./build/v22/register-study/study test 64 baseline i1_tables i2_product32 i12_combined

parallel-study-v22:
	python3 tools/v22_instruction_variants.py i12_combined
	python3 tools/v22_parallel_variants.py
	python3 tools/v22_parallel_variants.py i3_control
	python3 tools/v22_register_study.py

test-parallel-v22: parallel-study-v22
	./build/v22/register-study/study test 64 i12_combined i3_control i3_aes_pair i3_cross_pair i3_cross_fold

.PHONY: miner standalone test-miner integration-miner mine screening
miner:
	xcodegen generate
	xcodebuild -project VerusMetal.xcodeproj -scheme VerusMetal -configuration Release -derivedDataPath build/miner build

standalone: miner
	mkdir -p Distribution
	install -m 755 build/miner/Build/Products/Release/verusmetal Distribution/verusmetal
	cd Distribution && shasum -a 256 verusmetal > verusmetal.sha256

test-miner:
	xcodegen generate
	xcodebuild -project VerusMetal.xcodeproj -scheme VerusMetal -configuration Profile -derivedDataPath build/miner -destination 'platform=macOS,arch=arm64' test

integration-miner: miner
	mkdir -p build/setup
	$(CXX) -O3 -std=c++20 -mcpu=native -dynamiclib src/v22/cpu.cpp -o build/setup/libverus-check.dylib
	python3 tests/test_cli.py
	python3 tests/test_pool_integration.py

mine: miner
	./build/miner/Build/Products/Release/verusmetal mine --config Config/local.json
