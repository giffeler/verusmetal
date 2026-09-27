#pragma once
#include "platform.h"

// 552 key vectors followed by the 64-byte finalization block.
enum : U32 { keyVectors = 552, workspaceVectors = 556 };
struct Workspace {
    VM_DEVICE V *base;
    U32 stride;
    V get(U32 index) const { return base[index * stride]; }
    void put(U32 index, V value) const { base[index * stride] = value; }
    V message(U32 index) const {
        V v = get(keyVectors + index);
        return index < 2 ? v ^ get(keyVectors + index + 2) : v;
    }
};

inline void interleave(VM_THREAD V &a, VM_THREAD V &b) {
    V next{a.x, b.x, a.y, b.y};
    b = V{a.z, b.z, a.w, b.w};
    a = next;
}
inline void keyedPair(VM_THREAD V &a, VM_THREAD V &b, Workspace key, U32 offset) {
    a = aes(a, key.get(offset));
    b = aes(b, key.get(offset + 1));
    a = aes(a, key.get(offset + 2));
    b = aes(b, key.get(offset + 3));
    interleave(a, b);
}
inline void haraka256(VM_THREAD V &a, VM_THREAD V &b) {
    V originalA = a, originalB = b;
    for (U32 r = 0; r != 5; ++r) {
        a = aes(a, RC[r*4]); b = aes(b, RC[r*4+1]);
        a = aes(a, RC[r*4+2]); b = aes(b, RC[r*4+3]);
        interleave(a, b);
    }
    a ^= originalA; b ^= originalB;
}

template<bool keyed>
inline void haraka512(VM_THREAD V &a, VM_THREAD V &b, V c, V d, Workspace key, U32 offset) {
    V feedA{a.z, a.w, b.z, b.w}, feedB{c.x, c.y, d.x, d.y};
    for (U32 r = 0; r != 5; ++r) {
        for (U32 pass = 0; pass != 2; ++pass) {
            U32 k = 8*r + 4*pass;
            a = aes(a, keyed ? key.get(offset+k) : RC[k]);
            b = aes(b, keyed ? key.get(offset+k+1) : RC[k+1]);
            c = aes(c, keyed ? key.get(offset+k+2) : RC[k+2]);
            d = aes(d, keyed ? key.get(offset+k+3) : RC[k+3]);
        }
        V nextA{a.w, c.w, b.w, d.w};
        V nextB{c.x, a.x, d.x, b.x};
        V nextC{c.y, a.y, d.y, b.y};
        d = V{a.z, c.z, b.z, d.z};
        a = nextA; b = nextB; c = nextC;
    }
    V outA{a.z, a.w, b.z, b.w};
    b = V{c.x, c.y, d.x, d.y} ^ feedB;
    a = outA ^ feedA;
}

inline V load16(VM_DEVICE const unsigned char *input) {
    V value{};
    for (U32 i = 0; i != 16; ++i) value[i/4] |= U32(input[i]) << (8*(i&3));
    return value;
}
inline void absorb(VM_DEVICE const unsigned char *input, U32 size, Workspace work) {
    V a{}, b{};
    U32 offset = 0;
    while (size - offset >= 32) {
        haraka512<false>(a, b, load16(input+offset), load16(input+offset+16), work, 0);
        offset += 32;
    }
    // FillExtra repeats the first 16 bytes starting at the end of the input tail.
    V c{}, d{};
    U32 tail = size - offset;
    for (U32 i = 0; i != 32; ++i) {
        U32 j = (i-tail)&15;
        U32 byte = i < tail ? input[offset+i] : (a[j/4] >> (8*(j&3))) & 255;
        if (i < 16) c[i/4] |= byte << (8*(i&3));
        else d[(i-16)/4] |= byte << (8*(i&3));
    }
    work.put(keyVectors, a); work.put(keyVectors+1, b);
    work.put(keyVectors+2, c); work.put(keyVectors+3, d);
}
inline void expandKey(Workspace work) {
    V a = work.get(keyVectors), b = work.get(keyVectors+1);
    for (U32 k = 0; k != keyVectors; k += 2) {
        haraka256(a, b);
        work.put(k, a); work.put(k+1, b);
    }
}

inline U64 mix(Workspace work) {
    V acc = work.get(513);
    for (U32 step = 0; step != 32; ++step) {
        U64 selector = low(acc);
        U32 first = U32(selector >> 5) & 511;
        U32 second = U32(selector >> 32) & 511;
        U32 lane = U32(selector) & 3;
        V p = work.message(lane), q = work.message(lane ^ 1);
        U32 operation = U32(selector >> 2) & 7;
        switch (operation) {
        case 0:
        case 2:
        case 7: {
            V right = work.get(second);
            V operand = right ^ (operation == 0 ? q : p);
            acc ^= operation == 2 ? operand : cross(operand);
            // Load before the store because first and second may alias.
            V left = work.get(first);
            work.put(first, right ^ roundedProduct(acc, right));
            if (operation == 7) acc ^= left ^ q;
            else {
                acc ^= cross(left ^ (operation == 0 ? p : q));
                if (operation == 2) acc ^= cross(q);
            }
            work.put(second, left ^ roundedProduct(acc, left));
            break;
        }
        case 1:
        case 3: {
            V left = work.get(first);
            if (operation == 1) acc ^= cross(left ^ p) ^ cross(p);
            else {
                acc ^= left ^ q;
                U64 dividend = low(acc);
                acc ^= remainder(acc, U32(selector));
                if ((dividend & 1) == 0) {
                    V right = work.get(second);
                    work.put(second, left ^ roundedProduct(acc, left));
                    work.put(first, right);
                    acc ^= p;
                    break;
                }
            }
            V right = work.get(second);
            work.put(second, left ^ roundedProduct(acc, left));
            acc ^= operation == 1 ? (right ^ q) : (cross(right ^ p) ^ cross(p));
            work.put(first, right ^ roundedProduct(acc, right));
            break;
        }
        case 4: {
            V a = q, b = p;
            for (U32 r = 0; r != 3; ++r) keyedPair(a, b, work, first+4*r);
            acc ^= a ^ b;
            V left = work.get(first), right = work.get(second);
            work.put(second, left ^ roundedProduct(acc, left));
            work.put(first, right);
            break;
        }
        case 5:
        case 6: {
            U32 cursor = first, aesOffset = 0;
            V last{};
            for (int r = int(selector >> 61); r >= 0; --r) {
                last = work.get(cursor++);
                bool branch = (selector & (U64(1) << (28+r))) != 0;
                V selected = ((r & 1) != 0) == branch ? p : q;
                if (operation == 6) {
                    last ^= selected;
                    if (branch) acc ^= remainder(last, U32(selector));
                    else { last = cross(last); acc ^= roundedProduct(acc, last); }
                } else if (branch) acc ^= cross(last ^ selected);
                else {
                    keyedPair(last, selected, work, cursor+aesOffset);
                    aesOffset += 4;
                    acc ^= last ^ selected;
                }
            }
            if (operation == 6) {
                V right = work.get(second);
                work.put(second, last);
                work.put(first, right ^ acc);
            } else {
                V left = work.get(first), right = work.get(second);
                work.put(second, left ^ roundedProduct(acc, left));
                work.put(first, right);
            }
            break;
        }
        }
    }
    return reduce(acc);
}

inline void finish(Workspace work, U32 tail, U64 intermediate, VM_DEVICE V *output) {
    V a = work.get(keyVectors), b = work.get(keyVectors+1);
    V c = work.get(keyVectors+2), d = work.get(keyVectors+3);
    for (U32 i = tail; i < 32; ++i) {
        U32 shift = 8*(i&3);
        U32 byte = U32(intermediate >> (8*((i-tail)&7))) & 255;
        if (i < 16) c[i/4] = (c[i/4] & ~(255u << shift)) | (byte << shift);
        else d[(i-16)/4] = (d[(i-16)/4] & ~(255u << shift)) | (byte << shift);
    }
    haraka512<true>(a, b, c, d, work, U32(intermediate) & 511);
    output[0] = a; output[1] = b;
}

inline void hash(VM_DEVICE const unsigned char *input, U32 size, Workspace work, VM_DEVICE V *output) {
    absorb(input, size, work);
    expandKey(work);
    U64 intermediate = mix(work);
    finish(work, size&31, intermediate, output);
}
