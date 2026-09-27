#!/usr/bin/env python3
"""Build instruction/dependency experiments without altering the default kernel."""
import argparse
import re
import v22_register_variants as study


def transform(core, platform, name):
    if name == 'i1_tables':
        constants = (study.BASE / 'constants.h').read_text().split('T0[256] = {', 1)[1]
        values = [int(x, 16) for x in re.findall(r'0x([0-9a-f]+)u', constants)]
        assert len(values) == 256
        tables = '\n#ifdef __METAL_VERSION__\n// Derived locally from T0; rotations move from runtime to build time.\n'
        for n in [1, 2, 3]:
            rotated = [((x << (8*n)) | (x >> (32-8*n))) & 0xffffffff for x in values]
            tables += f'constant U32 T{n}[256] = {{\n'
            tables += '\n'.join('    '+', '.join(f'0x{x:08x}u' for x in rotated[i:i+8])+','
                                for i in range(0, 256, 8)) + '\n};\n'
        tables += '#endif\n'
        platform = study.replace(platform, '#include "constants.h"', '#include "constants.h"\n'+tables)
        for old, new in [
            ('rotate(T0[(x[(c+1)&3] >> 8) & 255], 8u)', 'T1[(x[(c+1)&3] >> 8) & 255]'),
            ('rotate(T0[(x[(c+2)&3] >> 16) & 255], 16u)', 'T2[(x[(c+2)&3] >> 16) & 255]'),
            ('rotate(T0[x[(c+3)&3] >> 24], 24u)', 'T3[x[(c+3)&3] >> 24]'),
        ]:
            platform = study.replace(platform, old, new)
    elif name == 'i2_product32':
        start = platform.index('    // Polynomial long multiplication:')
        end = platform.index('\n#else', start)
        platform = platform[:start] + '''    // Four independent degree-31 polynomial products; no integer carries.
    U32 al = U32(a), ah = U32(a >> 32);
    U64 bl = U32(b), bh = U32(b >> 32);
    U64 ll = 0, lh = 0, hl = 0, hh = 0;
    for (U32 bit = 0; bit != 32; ++bit) {
        U64 ml = U64(0) - U64(al & 1), mh = U64(0) - U64(ah & 1);
        ll ^= bl & ml; lh ^= bh & ml;
        hl ^= bl & mh; hh ^= bh & mh;
        al >>= 1; ah >>= 1;
        bl <<= 1; bh <<= 1;
    }
    U64 middle = lh ^ hl;
    return words(ll ^ (middle << 32), hh ^ (middle >> 32));''' + platform[end:]
    else:
        raise ValueError(name)
    return core, platform


EXTRA = '''
kernel void instruction_cases(device const uint4 *input [[buffer(0)]],
                              device uint4 *output [[buffer(1)]],
                              uint tid [[thread_position_in_grid]]) {
    V a = input[2*tid], b = input[2*tid+1];
    output[2*tid] = product(low(a), high(a));
    output[2*tid+1] = aes(a, b);
}
'''

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', nargs='?', choices=['i1_tables', 'i2_product32', 'i12_combined'])
    args = parser.parse_args()
    study.transform = transform
    for name in ([args.name] if args.name else ['i1_tables', 'i2_product32']):
        steps = ['i1_tables', 'i2_product32'] if name == 'i12_combined' else [name]
        study.build(name, steps, extra_source=EXTRA)
