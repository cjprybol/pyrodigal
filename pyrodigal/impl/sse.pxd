from libc.stdint cimport int8_t, uint8_t

cdef extern from "impl/sse.h" nogil:
    void skippable_sse(const int8_t*, const uint8_t*, const uint8_t*, const int, const int, uint8_t*);
