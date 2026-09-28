# Per-job cache study

`baseline/` freezes the pre-cache production mining kernel and canonical hash
headers at the revision recorded in `baseline/revision.txt`. It is a local copy
of this project's independently written implementation, not third-party code.
The build script compiles that CPU source under renamed symbols as a differential
oracle. The immutable 148-vector corpus remains the independent hash oracle.

`binned.metal` is an isolated research kernel. Its build extracts one unchanged
mix step from the current canonical core into a generated header under `build/`.
It is never embedded in the miner. `evidence/` contains the new paired measurements,
resource metrics and source/binary fingerprints. Existing research evidence is
left in place. See [the report](../../Docs/research/KEY-CACHING.md).

Run `make test-cache-v22` to rebuild the study. The driver supports:

```sh
build/v22/cache-study/study check 129 cached binned
build/v22/cache-study/study bench 32768 baseline cached
build/v22/cache-study/study bench 32768 cached baseline
build/v22/cache-study/study bench 32768 cached control
build/v22/cache-study/study bench 32768 control cached
build/v22/cache-study/study bench 32768 cached:4096 cached:32768
MTL_CAPTURE_ENABLED=1 build/v22/cache-study/study capture 4096 baseline holes cached
```

Every benchmark has 20 alternating-order pairs after at least 0.75 seconds of
equal alternating warm-up, with setup and digest verification outside timing.
Capture replay must be stopped before benchmarking. `check` enables Metal shader
validation; all modes check two nonce ranges and consecutive dispatch reuse
against the frozen full CPU hash. New timing output goes to stdout: redirect it
to a new file rather than replacing retained evidence.
