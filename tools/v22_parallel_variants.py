#!/usr/bin/env python3
"""Expose independent work within one hash thread, on the instruction baseline."""
import argparse
import v22_instruction_variants as instructions
import v22_register_variants as study


def transform(core, platform, name):
    if name in ['i1_tables', 'i2_product32']:
        return instructions.transform(core, platform, name)
    if name == 'i3_cross_fold':
        core, platform = transform(core, platform, 'i3_cross_pair')
        platform = study.replace(platform,
            '    U64 yll = 0, ylh = 0, yhl = 0, yhh = 0;\n', '')
        for suffix, xb, xm, yb, ym in [
            ('ll','xb0','xml','yb0','yml'), ('lh','xb1','xml','yb1','yml'),
            ('hl','xb0','xmh','yb0','ymh'), ('hh','xb1','xmh','yb1','ymh'),
        ]:
            platform = study.replace(platform,
                f'x{suffix} ^= {xb} & {xm}; y{suffix} ^= {yb} & {ym};',
                f'x{suffix} ^= ({xb} & {xm}) ^ ({yb} & {ym});')
        platform = study.replace(platform, 'xlh ^ xhl ^ ylh ^ yhl', 'xlh ^ xhl')
        platform = study.replace(platform, 'xll ^ yll ^ (middle << 32), xhh ^ yhh ^ (middle >> 32)',
                                 'xll ^ (middle << 32), xhh ^ (middle >> 32)')
        platform = study.replace(platform,
            '// Two independent products share loop control, never their input state.',
            '// Fold independent contributions into their required XOR sum each iteration.')
        return core, platform
    if name == 'i3_aes_pair':
        helper = '''
inline void aesPair(VM_THREAD V &a, VM_THREAD V &b, V ka, V kb) {
#ifdef __METAL_VERSION__
    V x, y;
    // Interleave independent columns of two states before their next AES round.
    for (U32 c = 0; c != 4; ++c) {
        x[c] = T0[a[c] & 255] ^ T1[(a[(c+1)&3] >> 8) & 255]
             ^ T2[(a[(c+2)&3] >> 16) & 255] ^ T3[a[(c+3)&3] >> 24];
        y[c] = T0[b[c] & 255] ^ T1[(b[(c+1)&3] >> 8) & 255]
             ^ T2[(b[(c+2)&3] >> 16) & 255] ^ T3[b[(c+3)&3] >> 24];
    }
    a = x ^ ka; b = y ^ kb;
#else
    a = aes(a, ka); b = aes(b, kb);
#endif
}
'''
        core = study.replace(core, 'inline void keyedPair(', helper+'\ninline void keyedPair(')
        for old,new in [
            ('a = aes(a, key.get(offset));\n    b = aes(b, key.get(offset + 1));',
             'aesPair(a, b, key.get(offset), key.get(offset + 1));'),
            ('a = aes(a, key.get(offset + 2));\n    b = aes(b, key.get(offset + 3));',
             'aesPair(a, b, key.get(offset + 2), key.get(offset + 3));'),
            ('a = aes(a, RC[r*4]); b = aes(b, RC[r*4+1]);',
             'aesPair(a, b, RC[r*4], RC[r*4+1]);'),
            ('a = aes(a, RC[r*4+2]); b = aes(b, RC[r*4+3]);',
             'aesPair(a, b, RC[r*4+2], RC[r*4+3]);'),
            ('a = aes(a, keyed ? key.get(offset+k) : RC[k]);\n            b = aes(b, keyed ? key.get(offset+k+1) : RC[k+1]);',
             'aesPair(a, b, keyed ? key.get(offset+k) : RC[k], keyed ? key.get(offset+k+1) : RC[k+1]);'),
            ('c = aes(c, keyed ? key.get(offset+k+2) : RC[k+2]);\n            d = aes(d, keyed ? key.get(offset+k+3) : RC[k+3]);',
             'aesPair(c, d, keyed ? key.get(offset+k+2) : RC[k+2], keyed ? key.get(offset+k+3) : RC[k+3]);'),
        ]:
            core = study.replace(core,old,new)
    elif name == 'i3_cross_pair':
        helper = '''
inline V crossXor(V x, V y) {
#ifdef __METAL_VERSION__
    // Two independent products share loop control, never their input state.
    U32 xl = x.x, xh = x.y, yl = y.x, yh = y.y;
    U64 xb0 = x.z, xb1 = x.w, yb0 = y.z, yb1 = y.w;
    U64 xll = 0, xlh = 0, xhl = 0, xhh = 0;
    U64 yll = 0, ylh = 0, yhl = 0, yhh = 0;
    for (U32 bit = 0; bit != 32; ++bit) {
        U64 xml = U64(0)-U64(xl&1), xmh = U64(0)-U64(xh&1);
        U64 yml = U64(0)-U64(yl&1), ymh = U64(0)-U64(yh&1);
        xll ^= xb0 & xml; yll ^= yb0 & yml;
        xlh ^= xb1 & xml; ylh ^= yb1 & yml;
        xhl ^= xb0 & xmh; yhl ^= yb0 & ymh;
        xhh ^= xb1 & xmh; yhh ^= yb1 & ymh;
        xl >>= 1; xh >>= 1; yl >>= 1; yh >>= 1;
        xb0 <<= 1; xb1 <<= 1; yb0 <<= 1; yb1 <<= 1;
    }
    U64 middle = xlh ^ xhl ^ ylh ^ yhl;
    return words(xll ^ yll ^ (middle << 32), xhh ^ yhh ^ (middle >> 32));
#else
    return cross(x) ^ cross(y);
#endif
}
'''
        platform = study.replace(platform, 'inline V roundedProduct(', helper+'\ninline V roundedProduct(')
        core = study.replace(core, 'cross(left ^ p) ^ cross(p)', 'crossXor(left ^ p, p)')
        core = study.replace(core, 'cross(right ^ p) ^ cross(p)', 'crossXor(right ^ p, p)')
    else:
        raise ValueError(name)
    return core, platform


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', nargs='?', choices=['i3_control', 'i3_aes_pair', 'i3_cross_pair', 'i3_cross_fold'])
    args = parser.parse_args()
    study.transform = transform
    for name in ([args.name] if args.name else ['i3_aes_pair', 'i3_cross_pair', 'i3_cross_fold']):
        extra = instructions.EXTRA
        if name.startswith('i3_cross'):
            extra = extra.replace('aes(a, b)', 'crossXor(a, b)')
        steps = ['i1_tables', 'i2_product32'] + ([] if name == 'i3_control' else [name])
        study.build(name, steps, extra_source=extra)
