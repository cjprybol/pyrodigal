#include "sequence.h"
#include "avx.h"
#include "generic.h"

#ifdef __AVX2__

#include <immintrin.h>

#include "template.h"

#define simd_t            __m256i
#define simd_load(m)      _mm256_load_si256((__m256i*) (m))
#define simd_store(x, m)  _mm256_store_si256((__m256i*) (m), x)
#define simd_set1(x)      _mm256_set1_epi8(x)
#define simd_or(x, y)     _mm256_or_si256(x, y)
#define simd_eq(x, y)     _mm256_cmpeq_epi8(x, y)
#define simd_and(x, y)    _mm256_and_si256(x, y)
#define simd_andnot(x, y) _mm256_andnot_si256(y, x)

#define SIMD_LANES 32
#define SIMD_MASK  0x1F

void skippable_avx(
    const int8_t* strands,
    const uint8_t* types,
    const uint8_t* frames,
    const int min,
    const int i,
    uint8_t* skip
) {
    skippable_simd(strands, types, frames, min, i, skip);
}

#endif
