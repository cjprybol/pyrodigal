from pyrodigal.prodigal.bitmap cimport bitmap_t
from pyrodigal.prodigal.training cimport _training


cdef extern from "sequence.h" nogil:

    const size_t MAX_MASKS
    const size_t MASK_SIZE

    struct _mask:
        int begin
        int end

    enum node_type:
        ATG = 0
        GTG = 1
        TTG = 2
        STOP = 3

    # given a bitmap_t sequence `seq` of length `len`, write the reverse
    # complement of `seq` into `rseq`, ignoring chars set a ``
    void rcom_seq(const bitmap_t seq, bitmap_t rseq, bitmap_t useq, int slen)

    bint is_a(bitmap_t seq, int n)
    bint is_c(bitmap_t seq, int n)
    bint is_g(bitmap_t seq, int n)
    bint is_t(bitmap_t seq, int n)
    bint is_n(bitmap_t, int)
    bint is_gc(bitmap_t seq, int n)

    bint is_stop(bitmap_t, int, _training*)
    bint is_start(bitmap_t, int, _training*)
    bint is_atg(bitmap_t, int);
    bint is_gtg(bitmap_t, int);
    bint is_ttg(bitmap_t, int);

    double gc_content(bitmap_t seq, int a, int b)

    char amino(bitmap_t seq, int n, _training* tinf, bint is_init)
    int amino_num(char)
    char amino_letter(int)

    int max_fr(int, int, int)

    int* calc_most_gc_frame(bitmap_t seq, int slen)

    int mer_ndx(int, unsigned char*, int)
    void mer_text(char*, int, int)
    void calc_mer_bg(int, unsigned char*, unsigned char*, int, double*)

    int shine_dalgarno_exact(unsigned char*, int, int, double*);
    int shine_dalgarno_mm(unsigned char*, int, int, double*);
