#include "sequence.h"
#include "sse.h"
#include "generic.h"

#ifdef __SSE2__

#include <emmintrin.h>

#include "template.h"

#define simd_t            __m128i
#define simd_load(m)      _mm_load_si128((__m128i*) (m))
#define simd_store(x, m)  _mm_store_si128((__m128i*) (m), x)
#define simd_set1(x)      _mm_set1_epi8(x)
#define simd_or(x, y)     _mm_or_si128(x, y)
#define simd_eq(x, y)     _mm_cmpeq_epi8(x, y)
#define simd_and(x, y)    _mm_and_si128(x, y)
#define simd_andnot(x, y) _mm_andnot_si128(y, x)

#define SIMD_LANES 16
#define SIMD_MASK  0xF

void skippable_sse(
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
