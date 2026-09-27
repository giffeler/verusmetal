# Protocol references

Protocol behavior was checked against primary sources from
[VerusCoin/node-stratum-pool](https://github.com/VerusCoin/node-stratum-pool)
(job fields and submission framing) and
[VerusCoin/verushash-node](https://github.com/VerusCoin/verushash-node)
(PBaaS hash-view normalization). These were inspected as protocol references;
their implementation files are not part of the miner. Local review copies are
under ignored `build/setup`.

Solution version 8 retains the PBaaS header layout and VerusHash v2.2 selection.
Support was checked against the current upstream definitions on 2026-09-27:
[solution versions](https://github.com/VerusCoin/VerusCoin/blob/master/src/primitives/solutiondata.h),
[header hashing](https://github.com/VerusCoin/VerusCoin/blob/master/src/primitives/block.cpp),
and [hash dispatch](https://github.com/VerusCoin/VerusCoin/blob/master/src/crypto/verus_clhash.h).
The decoder accepts versions 4–8; unknown versions remain rejected. No upstream
hash implementation was added or substituted.

The PBaaS descriptor's two-byte field is the extra payload length, not the amount
of free space. Pool-reserved solution bytes can omit trailing zeros. The decoder
pads them to 1,344 bytes and requires headers plus declared extra data to end
at or before byte 1,329, preserving the final 15-byte nonce region.

## Supported mining flow

The decoder accepts the nine-field notify layout, block version `0x00010004`,
a 1,344-byte solution and solution versions 4–8. Unsupported layouts fail closed.
The pool target is a 32-byte big-endian integer; hash digests are compared as
little-endian integers. Pool-reserved solution bytes are preserved for submission;
only the canonical hash view clears the PBaaS non-canonical header fields.

Each GPU thread searches one nonce with fresh key generation. The large per-hash
workspace is in device memory. Every candidate is recomputed on the CPU and
checked against the target before submission. There is no shared-prefix/key cache.

The client subscribes and authorizes, handles `mining.set_target`, `mining.notify`
and `mining.set_extranonce`, and submits the user, job ID, timestamp, header nonce
suffix and serialized solution. Jobs received before authorization are held until
ready. New jobs, targets and subscription prefixes invalidate previous work;
latest-job policy also discards earlier jobs when `clean_jobs` is false.

Connection loss invalidates work and triggers reconnects with 1–30 second
exponential backoff. Framing and pending submissions are bounded. TLS uses system
trust evaluation; plaintext requires an explicitly configured TCP endpoint.
