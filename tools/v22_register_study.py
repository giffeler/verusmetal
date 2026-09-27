#!/usr/bin/env python3
"""Build the paired study driver against the unchanged CPU reference object."""
from pathlib import Path
import subprocess
import shutil

root = Path(__file__).resolve().parents[1]
study = root / 'build/v22/register-study'
baseline = study / 'baseline'
shutil.copytree(root / 'experiments/v22-register-pressure/baseline', baseline / 'src', dirs_exist_ok=True)
subprocess.run(['xcrun', 'clang++', '-O3', '-std=c++20', '-mcpu=native', '-Wall', '-Wextra', '-Werror',
                '-c', str(baseline / 'src/cpu.cpp'), '-o', str(baseline / 'cpu.o')], check=True)
source = (baseline / 'src/Benchmark.swift').read_text().split('func run() throws {')[0]
source = source.replace('init(validation: Bool) throws {',
                        'init(validation: Bool, name: String, sharedQueue: (any MTLCommandQueue)? = nil) throws {')
source = source.replace('device = try unwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable")',
                        'device = try unwrap(sharedQueue?.device ?? MTLCreateSystemDefaultDevice(), "Metal device unavailable")')
source = source.replace('queue = try unwrap(device.makeCommandQueue(), "Command queue unavailable")',
                        'queue = try unwrap(sharedQueue ?? device.makeCommandQueue(), "Command queue unavailable")')
source = source.replace('"build/v22/verus.metallib"', '"build/v22/register-study/\\(name)/kernel.metallib"')
source = source.replace('name: "verus_v22"', 'name: "verus_\\(name)"')
source = source.replace('"VerusHash v2.2 / full hash per thread"', '"\\(name) / full hash per thread"')
source += '''
import CryptoKit
func fileSHA256(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(filePath: path))).map { String(format: "%02x", $0) }.joined()
}
'''
source += (root / 'tools/V22RegisterStudy.swift').read_text()
(study / 'Study.swift').write_text(source)
(study / 'bridge.h').write_text('#include "baseline/src/cpu.h"\nvoid vm_pressure_cases(void *, void *, void *);\nvoid vm_instruction_cases(void *, void *);\nvoid vm_cross_cases(void *, void *);\n')
subprocess.run(['xcrun', 'clang++', '-O3', '-std=c++20', '-mcpu=native', '-Wall', '-Wextra', '-Werror',
                '-I'+str(baseline / 'src'), '-c', str(root / 'tests/v22-pressure-cases.cpp'),
                '-o', str(study / 'cases.o')], check=True)
subprocess.run(['xcrun', 'clang++', '-O3', '-std=c++20', '-mcpu=native', '-Wall', '-Wextra', '-Werror',
                '-I'+str(baseline / 'src'), '-c', str(root / 'tests/v22-instruction-cases.cpp'),
                '-o', str(study / 'instruction-cases.o')], check=True)
subprocess.run(['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-swift-version', '6',
                '-target', 'arm64-apple-macos27.0', '-warnings-as-errors', '-import-objc-header',
                str(study / 'bridge.h'), str(study / 'Study.swift'), str(baseline / 'cpu.o'), str(study / 'cases.o'),
                str(study / 'instruction-cases.o'),
                '-lc++', '-framework', 'Metal', '-o', str(study / 'study')], check=True)
