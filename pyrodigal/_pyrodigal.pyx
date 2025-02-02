# coding: utf-8
# cython: language_level=3, linetrace=True

"""Bindings to Prodigal, an ORF finder for genomes and metagenomes.

Attributes:
    PRODIGAL_VERSION (`str`): The version of Prodigal currently wrapped
        in Pyrodigal.
    IDEAL_SINGLE_GENOME (`int`): The minimum length recommended for a 
        training sequence to be used in `OrfFinder.train`.
    MIN_SINGLE_GENOME (`int`): The minimum length required for a 
        training sequence to be used in `OrfFinder.train`.
    TRANSLATION_TABLES (`set` of `int`): A set containing all the
        translation tables supported by Prodigal.
    METAGENOMIC_BINS (`tuple` of `~pyrodigal.MetagenomicBin`): A tuple
        containing all the built-in metagenomic models.

Example:
    Pyrodigal can work on any DNA sequence stored in either a text or a
    byte array. To load a sequence from one of the common sequence formats,
    you can use an external dedicated library such as
    `Biopython <https://github.com/biopython/biopython>`_::

        >>> import gzip
        >>> import Bio.SeqIO
        >>> with gzip.open("KK037166.fna.gz", "rt") as f:
        ...     record = Bio.SeqIO.read(f, "fasta")

    Then use Pyrodigal to find the genes in *metagenomic* mode (without
    training first), for instance to build a map of codon frequencies
    for each gene::

        >>> import collections
        >>> import pyrodigal
        >>> p = pyrodigal.OrfFinder(meta=True)
        >>> for gene in p.find_genes(record.seq.encode()):
        ...     gene_seq = gene.sequence()
        ...     codon_counter = collections.Counter()
        ...     for i in range(0, len(gene_seq), 3):
        ...         codon_counter[gene_seq[i:i+3]] += 1
        ...     codon_frequencies = {
        ...         codon:count/(len(gene_seq)//3)
        ...         for codon, count in codon_counter.items()
        ...     }

Caution:
    In Pyrodigal, sequences are assumed to contain only the usual
    nucleotides (A/T/G/C) as lowercase or uppercase letters; any other
    symbol will be treated as an unknown nucleotide. Be careful to remove
    the gap characters if loading sequences from a multiple alignment file.

Note:
    To cite Pyrodigal, please cite both the original method and the short
    paper for the Python library itself, for instance as:

      Pyrodigal (Larralde, 2022), a Python library binding to Prodigal
      (Hyatt *et al.*, 2010).

References:
    - Larralde, M.
      *Pyrodigal: Python bindings and interface to Prodigal, an efficient
      method for gene prediction in prokaryotes*. Journal of Open Source
      Software 7, no. 72 (25 April 2022). :doi:`10.21105/joss.04296`.
    - Hyatt D, Chen GL, Locascio PF, Land ML, Larimer FW, Hauser LJ.
      *Prodigal: prokaryotic gene recognition and translation initiation
      site identification*. BMC Bioinformatics 11, no. 1 (December 2010).
      :doi:`10.1186/1471-2105-11-119`. :pmid:`20211023`. :pmc:`2848648`.

"""

# ----------------------------------------------------------------------------

from cpython cimport Py_buffer
from cpython.buffer cimport PyBUF_FORMAT, PyBUF_READ, PyBUF_WRITE
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AsString
from cpython.exc cimport PyErr_CheckSignals
from cpython.list cimport PyList_New, PyList_SET_ITEM
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New, PyTuple_SET_ITEM
from libc.math cimport sqrt, log, pow, fmax, fmin
from libc.stdint cimport int8_t, uint8_t, uintptr_t
from libc.stdio cimport printf
from libc.stdlib cimport abs, malloc, calloc, free, qsort
from libc.string cimport memcpy, memchr, memset, strstr

from pyrodigal.prodigal cimport bitmap, dprog, gene, node, sequence
from pyrodigal.prodigal.metagenomic cimport NUM_META, _metagenomic_bin, initialize_metagenomic_bins
from pyrodigal.prodigal.node cimport _motif, _node, MIN_EDGE_GENE, MIN_GENE, MAX_SAM_OVLP, cross_mask, compare_nodes, stopcmp_nodes
from pyrodigal.prodigal.sequence cimport _mask, node_type, rcom_seq, MASK_SIZE
from pyrodigal.prodigal.training cimport _training
from pyrodigal._unicode cimport *
from pyrodigal._sequence cimport (
    nucleotide,
    _is_a,
    _is_c,
    _is_g,
    _is_t,
    _is_gc,
    _is_stop,
    _is_start,
    _mer_ndx,
    _letters,
    _complement
)
from pyrodigal._connection cimport (
    _intergenic_mod_same,
    _intergenic_mod_diff,
    _intergenic_mod,
    _score_connection_forward_start,
    _score_connection_forward_stop,
    _score_connection_backward_start,
    _score_connection_backward_stop,
    _score_connections,
    connection_function,
    CONNECTION_FUNCTIONS,
)
from pyrodigal.impl.generic cimport skippable_generic

IF MMX_BUILD_SUPPORT:
    from pyrodigal.impl.mmx cimport skippable_mmx
IF SSE2_BUILD_SUPPORT:
    from pyrodigal.impl.sse cimport skippable_sse
IF AVX2_BUILD_SUPPORT:
    from pyrodigal.impl.avx cimport skippable_avx
IF NEON_BUILD_SUPPORT:
    from pyrodigal.impl.neon cimport skippable_neon

IF SYS_IMPLEMENTATION_NAME == "pypy":
    cdef int MVIEW_READ  = PyBUF_READ | PyBUF_WRITE
    cdef int MVIEW_WRITE = PyBUF_READ | PyBUF_WRITE
ELSE:
    cdef int MVIEW_READ  = PyBUF_READ
    cdef int MVIEW_WRITE = PyBUF_WRITE

# ----------------------------------------------------------------------------

import array
import itertools
import textwrap
import threading
import warnings

include "_version.py"

# --- Module-level constants -------------------------------------------------

cdef size_t MIN_MASKS_ALLOC      = 8
cdef size_t MIN_GENES_ALLOC      = 8
cdef size_t MIN_NODES_ALLOC      = 8 * MIN_GENES_ALLOC
cdef int    _IDEAL_SINGLE_GENOME = 100000
cdef int    _MIN_SINGLE_GENOME   = 20000
cdef int    _WINDOW              = 120
cdef set    _TRANSLATION_TABLES  = set(range(1, 7)) | set(range(9, 17)) | set(range(21, 26))
cdef str    _PRODIGAL_VERSION    = "v2.6.3+c1e2d36"

IDEAL_SINGLE_GENOME = 100000
MIN_SINGLE_GENOME   = 20000
TRANSLATION_TABLES  = frozenset(_TRANSLATION_TABLES)
PRODIGAL_VERSION    = _PRODIGAL_VERSION

cdef list _RBS_MOTIF = [
    None, "GGA/GAG/AGG", "3Base/5BMM", "4Base/6BMM", "AGxAG", "AGxAG",
    "GGA/GAG/AGG", "GGxGG", "GGxGG", "AGxAG", "AGGAG(G)/GGAGG",
    "AGGA/GGAG/GAGG", "AGGA/GGAG/GAGG", "GGA/GAG/AGG", "GGxGG",
    "AGGA", "GGAG/GAGG", "AGxAGG/AGGxGG", "AGxAGG/AGGxGG",
    "AGxAGG/AGGxGG", "AGGAG/GGAGG", "AGGAG", "AGGAG", "GGAGG",
    "GGAGG", "AGGAGG", "AGGAGG", "AGGAGG",
]

cdef list _RBS_SPACER = [
    None, "3-4bp", "13-15bp", "13-15bp", "11-12bp", "3-4bp",
    "11-12bp", "11-12bp", "3-4bp", "5-10bp", "13-15bp", "3-4bp",
    "11-12bp", "5-10bp", "5-10bp", "5-10bp", "5-10bp", "11-12bp",
    "3-4bp", "5-10bp", "11-12bp", "3-4bp", "5-10bp", "3-4bp",
    "5-10bp", "11-12bp", "3-4bp", "5-10bp",
]

cdef list _NODE_TYPE = [
    "ATG", "GTG", "TTG" , "Edge",
]


cdef inline size_t new_capacity(size_t capacity) nogil:
    return capacity + (capacity >> 3) + 6

# --- Sequence mask ----------------------------------------------------------

cdef class Mask:
    """The coordinates of a masked region.

    Hint:
        The region indices follow the Python `slice` convention:
        start-inclusive, end-exclusive. This allows the original sequence
        to be indexed by the mask ``start`` and ``end`` coordinates
        easily.

    .. versionchanged:: 2.0.0
        Change end coordinate to be exclusive.

    """
    # --- Magic methods ------------------------------------------------------

    def __init__(self, int begin, int end):
        self.owner = None
        self.mask = &self._data
        self.mask.begin = begin
        self.mask.end = end

    def __repr__(self):
        ty = type(self)
        return "<{}.{} begin={!r} end={!r}>".format(
            ty.__module__,
            ty.__name__,
            self.mask.begin,
            self.mask.end,
        )

    def __eq__(self, other):
        if isinstance(other, Mask):
            return self.mask.begin == other.begin and self.mask.end == other.end
        return False

    cpdef size_t __sizeof__(self):
        return sizeof(_mask) + sizeof(self)

    # --- Properties ---------------------------------------------------------

    @property
    def begin(self):
        """`int`: The leftmost coordinate of the masked region.
        """
        return self.mask.begin

    @property
    def end(self):
        """`int`: The rightmost coordinate of the masked region, exclusive.
        """
        return self.mask.end

    # --- C interface -------------------------------------------------------

    @staticmethod
    cdef bint _intersects(_mask* mask, int begin, int end) nogil:
        if mask == NULL:
            return False
        return mask.begin < end and begin < mask.end

    # --- Python interface ---------------------------------------------------

    cpdef bint intersects(self, int begin, int end):
        """intersects(self, begin, end)\n--

        Check whether the mask intersects a range of sequence coordinates.

        Arguments:
            begin (`int`): The rightmost coordinate of the region to
                check for intersection (inclusive).
            end (`int`): The leftmost coordinate of the region to check
                for intersection (exclusive).

        Example:
            >>> mask = pyrodigal.Mask(3, 5)
            >>> mask.intersects(2, 5)
            True
            >>> mask.intersects(1, 4)
            True
            >>> mask.intersects(1, 3)  # range end is exclusive
            False
            >>> mask.intersects(5, 7)  # mask end is exclusive
            False

        """
        return Mask._intersects(self.mask, begin, end)


cdef class Masks:
    """A list of masked regions within a `~pyrodigal.Sequence`.

    Prodigal and Pyrodigal support masking regions containing unknown
    nucleotides to prevent genes to be predicting across them. This
    collection allows storing the coordinates of the masked regions
    in a more compact way than a plain bitmap masking each position.

    Note:
        Pyrodigal also improves the logic used for region masking: in
        Prodigal, every time a gene is found, all the masks from the sequence
        are tested to see if the gene intersects with any of them. However,
        since gene extraction happens sequentially, sorting the masks once
        allows to bypass the full scan, saving some time for sequences with
        a lot of unknown regions.

    """

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self.masks = NULL
        self.capacity = 0
        self.length = 0

    def __init__(self):
        self._clear()

    def __dealloc__(self):
        PyMem_Free(self.masks)

    def __copy__(self):
        return self.copy()

    def __len__(self):
        return self.length

    def __getitem__(self, ssize_t index):
        cdef Mask mask
        if index < 0:
            index += <ssize_t> self.length
        if index >= <ssize_t> self.length or index < 0:
            raise IndexError("list index out of range")
        mask = Mask.__new__(Mask)
        mask.owner = self
        mask.mask = &self.masks[index]
        return mask

    cpdef size_t __sizeof__(self):
        return self.capacity * sizeof(_mask) + sizeof(self)

    cpdef list __getstate__(self):
        """__getstate__(self)\n--
        """
        cdef size_t i
        return [
            (self.masks[i].begin, self.masks[i].end)
            for i in range(self.length)
        ]

    cpdef object __setstate__(self, list state):
        """__setstate__(self, state)\n--
        """
        cdef size_t i
        cdef tuple  mask

        # realloc to the exact number of masks
        self.length = self.capacity = len(state)
        if self.capacity > 0:
            self._allocate(self.capacity)
        else:
            PyMem_Free(self.masks)
            self.masks = NULL

        # copy data from the state list
        for i, mask in enumerate(state):
            self.masks[i].begin, self.masks[i].end = mask

    # --- C interface -------------------------------------------------------

    cdef int _allocate(self, size_t capacity) except 1:
        # record new capacity
        cdef size_t old_capacity = self.capacity
        self.capacity = capacity
        # allocate node array
        self.masks = <_mask*> PyMem_Realloc(self.masks, self.capacity * sizeof(_mask))
        if self.masks == NULL:
            raise MemoryError("Failed to reallocate mask array")
        # clean newly-allocated memory
        if self.capacity > old_capacity:
            memset(&self.masks[old_capacity], 0, (self.capacity - old_capacity) * sizeof(_mask))
        return 0

    cdef inline _mask* _add_mask(
        self,
        const int  begin,
        const int  end,
    ) nogil except NULL:
        """Add a single node to the vector, and return a pointer to that node.
        """

        cdef size_t old_capacity = self.capacity
        cdef _mask* mask

        if self.length >= self.capacity:
            with gil:
                self._allocate(MIN_MASKS_ALLOC if self.capacity == 0 else new_capacity(self.capacity))

        self.length += 1
        mask = &self.masks[self.length - 1]
        mask.begin = begin
        mask.end = end
        return mask

    cdef int _clear(self) nogil:
        """Remove all masks from the vector.
        """
        cdef size_t old_length
        old_length, self.length = self.length, 0
        memset(self.masks, 0, old_length * sizeof(_mask))

    # --- Python interface ---------------------------------------------------

    cpdef void clear(self):
        """clear(self)\n--

        Remove all masks from the list.

        """
        with nogil:
            self._clear()

    cpdef Masks copy(self):
        """copy(self)\n--

        Return a copy of this list of masks.

        """
        cdef Masks new = Masks.__new__(Masks)
        new.capacity = self.capacity
        new.length = self.length
        new.masks = <_mask*> PyMem_Malloc(new.capacity * sizeof(_mask))
        if new.masks == NULL:
            raise MemoryError("Failed to allocate masks array")
        memcpy(new.masks, self.masks, new.capacity * sizeof(_mask))
        return new


# --- Input sequence ---------------------------------------------------------

cdef class Sequence:
    """A digitized input sequence.

    Attributes:
        gc (`float`): The GC content of the sequence, as a fraction
            (between 0 and 1).
        masks (`~pyrodigal.Masks`): A list of masked regions within the
            sequence. It will be empty if the sequence was created with
            ``mask=False``.

    .. versionchanged:: 2.0.0
        Removed the ``from_string`` and ``from_bytes`` constructors.

    """

    # --- Class methods ------------------------------------------------------

    @staticmethod
    cdef int _build(
        const int      kind,
        const void*    data,
        const size_t   length,
              double*  gc,
              uint8_t* digits,
    ) nogil except 1:
        cdef size_t  i
        cdef Py_UCS4 letter
        cdef int     gc_count   = 0

        for i in range(length):
            letter = PyUnicode_READ(kind, data, i)
            if letter == u'A' or letter == u'a':
                digits[i] = nucleotide.A
            elif letter == u'T' or letter == u't':
                digits[i] = nucleotide.T
            elif letter == u'G' or letter == u'g':
                digits[i] = nucleotide.G
                gc_count += 1
            elif letter == u'C' or letter == u'c':
                digits[i] = nucleotide.C
                gc_count += 1
            else:
                digits[i] = nucleotide.N

        if length > 0:
            gc[0] = (<double> gc_count) / (<double> length)

        return 0

    @staticmethod
    cdef int _mask(
        const uint8_t* digits,
        const size_t   length,
              Masks    masks,
        const size_t   mask_size,
    ) nogil except 1:
        cdef int     mask_begin = -1
        for i in range(length):
            if digits[i] == nucleotide.N:
                if mask_begin == -1:
                    mask_begin = i
            else:
                if mask_begin != -1:
                    if i >= mask_size + mask_begin:
                        masks._add_mask(mask_begin, i)
                    mask_begin = -1
        return 0

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self.slen = 0
        self.gc = 0.0
        self.digits = NULL
        self.masks = Masks.__new__(Masks)

    def __init__(self, object sequence, bint mask = False, size_t mask_size = MASK_SIZE):
        """__init__(self, sequence, mask=False, mask_size=50)\n--

        Create a new `Sequence` object from a nucleotide sequence.

        Arguments:
            sequence (`str`, `bytes` or `Sequence`): The sequence to read
                from. `bytes` or byte-like buffers will be treated as
                ASCII-encoded strings.
            mask (`bool`): Enable region-masking for spans of unknown
                characters, preventing genes from being built across them.
            mask_size (`int`): The minimum number of contiguous unknown 
                nucleotides required to build a mask.

        """
        cdef ssize_t                  i
        cdef int                      kind
        cdef const void*              data
        cdef const unsigned char[::1] view

        if isinstance(sequence, Sequence):
            self._allocate(sequence.slen)
            self.gc = sequence.gc
            memcpy(self.digits, (<Sequence> sequence).digits, self.slen * sizeof(uint8_t))
        else:
            if isinstance(sequence, str):
                # make sure the unicode string is in canonical form,
                # --> won't be needed anymore in Python 3.12
                IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 12:
                    PyUnicode_READY(sequence)
                kind = PyUnicode_KIND(sequence)
                data = PyUnicode_DATA(sequence)
                self._allocate(PyUnicode_GET_LENGTH(sequence))
            else:
                view = sequence
                kind = PyUnicode_1BYTE_KIND
                data = &view[0]
                self._allocate(view.shape[0])
            with nogil:
                Sequence._build(
                    kind,
                    data,
                    self.slen,
                    &self.gc,
                    self.digits,
                )

        if mask:
            Sequence._mask(
                self.digits,
                self.slen,
                self.masks,
                mask_size,
            )

    def __dealloc__(self):
        PyMem_Free(self.digits)

    def __len__(self):
        """__len__(self)\n--

        Return the number of nucleotides in the sequence.

        """
        return self.slen

    cpdef size_t __sizeof__(self):
        return self.slen * sizeof(uint8_t) + sizeof(self)

    def __str__(self):
        cdef int     i
        cdef Py_UCS4 nuc

        IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
            cdef bytes dna
            cdef void* data
            # create an empty byte buffer that we can write to
            dna = PyBytes_FromStringAndSize(NULL, self.slen)
            data = <void*> PyBytes_AsString(dna)
        ELSE:
            cdef unicode dna
            cdef int     kind
            cdef void*   data
            # create an empty string that we can write to
            dna  = PyUnicode_New(self.slen, 0x7F)
            kind = PyUnicode_KIND(dna)
            data = PyUnicode_DATA(dna)

        with nogil:
            for i in range(self.slen):
                nuc = _letters[self.digits[i]]
                IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
                    (<char*> data)[i] = nuc
                ELSE:
                    PyUnicode_WRITE(kind, data, i, nuc)

        IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
            return dna.decode("ascii")
        ELSE:
            return dna

    cpdef dict __getstate__(self):
        """__getstate__(self)\n--
        """
        assert self.digits != NULL
        # copy sequence digits
        cdef bytearray    digits = bytearray(self.slen)
        cdef uint8_t[::1] view   = digits
        memcpy(&view[0], self.digits, self.slen * sizeof(uint8_t))
        # build the state dict
        return {
            "slen": self.slen,
            "gc": self.gc,
            "masks": self.masks,
            "digits": digits
        }

    cpdef object __setstate__(self, dict state):
        """__setstate__(self, state)\n--
        """
        # get a view on the digits
        cdef uint8_t[::1] view = state["digits"]
        # copy attributes
        self.masks = state["masks"]
        self.gc = state["gc"]
        # allocate sequence storage and copy bytes
        self._allocate(state["slen"])
        memcpy(self.digits, &view[0], self.slen * sizeof(uint8_t))

    def __getbuffer__(self, Py_buffer* buffer, int flags):
        assert self.digits != NULL

        if flags & PyBUF_FORMAT:
            buffer.format = b"B"
        else:
            buffer.format = NULL
        buffer.buf = self.digits
        buffer.internal = NULL
        buffer.itemsize = sizeof(uint8_t)
        buffer.len = self.slen * sizeof(uint8_t)
        buffer.ndim = 1
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = &self.slen
        buffer.suboffsets = NULL
        buffer.strides = NULL

    # --- C interface -------------------------------------------------------

    cdef int _allocate(self, int slen) except 1:
        self.slen = slen
        self.digits = <uint8_t*> PyMem_Malloc(slen * sizeof(uint8_t))
        if self.digits == NULL:
            raise MemoryError()
        with nogil:
            memset(self.digits, 0, slen * sizeof(uint8_t))
        return 0

    cdef int* _max_gc_frame_plot(self, int window_size) nogil except NULL:
        cdef int  i
        cdef int  j
        cdef int  win
        cdef int* fwd  = <int*> malloc(self.slen*sizeof(int))
        cdef int* bwd  = <int*> malloc(self.slen*sizeof(int))
        cdef int* tot  = <int*> malloc(self.slen*sizeof(int))
        cdef int* gp   = <int*> malloc(self.slen*sizeof(int))

        if fwd == NULL or bwd == NULL or gp == NULL or tot == NULL:
            free(gp)
            free(fwd)
            free(bwd)
            free(tot)
            with gil:
                raise MemoryError("Could not allocate GC frame buffers")

        memset(fwd, 0, self.slen*sizeof(int))
        memset(bwd, 0, self.slen*sizeof(int))
        memset(tot, 0, self.slen*sizeof(int))
        memset(gp, -1, self.slen*sizeof(int))

        for i in range(min(3, self.slen)):
            fwd[i] = _is_gc(self.digits, self.slen, i, 1)
            bwd[self.slen-i-1] = _is_gc(self.digits, self.slen, i, -1)
        for i in range(3, self.slen):
            fwd[i] = fwd[i-3] + _is_gc(self.digits, self.slen, i, 1)
            bwd[self.slen-i-1] = bwd[self.slen-i+2] + _is_gc(self.digits, self.slen, i, -1)

        for i in range(self.slen):
            tot[i] = fwd[i] + bwd[i] - _is_gc(self.digits, self.slen, i, 1)
            if i >= _WINDOW/2:
                tot[i] -= fwd[i-_WINDOW/2]
            if i + _WINDOW/2 < self.slen:
                tot[i] -= bwd[i+_WINDOW/2]
        free(fwd)
        free(bwd)

        for i in range(0, self.slen-2, 3):
            win = sequence.max_fr(tot[i], tot[i+1], tot[i+2])
            for j in range(i, i+3):
                gp[j] = win
        free(tot)

        return gp

    cdef char _amino(
        self,
        int i,
        int tt,
        int strand = 1,
        bint is_init = False,
        char unknown_residue = b"X"
    ) nogil:
        cdef uint8_t x0
        cdef uint8_t x1
        cdef uint8_t x2

        if _is_stop(self.digits, self.slen, i, tt, strand):
            return b"*"
        if _is_start(self.digits, self.slen, i, tt, strand) and is_init:
            return b"M"

        if strand == 1:
            x0 = self.digits[i]
            x1 = self.digits[i+1]
            x2 = self.digits[i+2]
        else:
            x0 = _complement[self.digits[self.slen - 1 - i]]
            x1 = _complement[self.digits[self.slen - 2 - i]]
            x2 = _complement[self.digits[self.slen - 3 - i]]

        if x0 == nucleotide.T and x1 == nucleotide.T and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"F"
        if x0 == nucleotide.T and x1 == nucleotide.T and (x2 == nucleotide.A or x2 == nucleotide.G):
            return b"L"
        if x0 == nucleotide.T and x1 == nucleotide.C and x2 != nucleotide.N:
            return b"S"
        if x0 == nucleotide.T and x1 == nucleotide.A and x2 == nucleotide.T:
            return b"Y"
        if x0 == nucleotide.T and x1 == nucleotide.A and x2 == nucleotide.C:
            return b"Y"
        if x0 == nucleotide.T and x1 == nucleotide.A and x2 == nucleotide.A:
            if tt == 6:
                return b"Q"
            elif tt == 14:
                return b"Y"
        if x0 == nucleotide.T and x1 == nucleotide.A and x2 == nucleotide.G:
            if tt == 6 or tt == 15:
                return b"Q"
            elif tt == 22:
                return b"L"
        if x0 == nucleotide.T and x1 == nucleotide.G and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"C"
        if x0 == nucleotide.T and x1 == nucleotide.G and x2 == nucleotide.A:
            return b"G" if tt == 25 else b"W"
        if x0 == nucleotide.T and x1 == nucleotide.G and x2 == nucleotide.G:
            return b"W"
        if x0 == nucleotide.C and x1 == nucleotide.T and (x2 == nucleotide.T or x2 == nucleotide.C or x2 == nucleotide.A):
            return b"T" if tt == 3 else b"L"
        if x0 == nucleotide.C and x1 == nucleotide.T and x2 == nucleotide.G:
            return b"T" if tt == 3 else b"S" if tt == 12 else b"L"
        if x0 == nucleotide.C and x1 == nucleotide.C and x2 != nucleotide.N:
            return b"P"
        if x0 == nucleotide.C and x1 == nucleotide.A and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"H"
        if x0 == nucleotide.C and x1 == nucleotide.A and (x2 == nucleotide.A or x2 == nucleotide.G):
            return b"Q"
        if x0 == nucleotide.C and x1 == nucleotide.G and x2 != nucleotide.N:
            return b"R"
        if x0 == nucleotide.A and x1 == nucleotide.T and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"I"
        if x0 == nucleotide.A and x1 == nucleotide.T and x2 == nucleotide.A:
            return b"M" if tt == 2 or tt == 3 or tt == 5 or tt == 13 or tt == 22 else b"I"
        if x0 == nucleotide.A and x1 == nucleotide.T and x2 == nucleotide.G:
            return b"M"
        if x0 == nucleotide.A and x1 == nucleotide.C and x2 != nucleotide.N:
            return b"T"
        if x0 == nucleotide.A and x1 == nucleotide.A and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"N"
        if x0 == nucleotide.A and x1 == nucleotide.A and x2 == nucleotide.A:
            return b"N" if tt == 9 or tt == 14 or tt == 21 else b"K"
        if x0 == nucleotide.A and x1 == nucleotide.A and x2 == nucleotide.G:
            return b"K"
        if x0 == nucleotide.A and x1 == nucleotide.G and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"S"
        if x0 == nucleotide.A and x1 == nucleotide.G and (x2 == nucleotide.A or x2 == nucleotide.G):
            return b"G" if tt == 13 else b"S" if tt == 5 or tt == 9 or tt == 14 or tt == 21 else b"R"
        if x0 == nucleotide.G and x1 == nucleotide.T and x2 != nucleotide.N:
            return b"V"
        if x0 == nucleotide.G and x1 == nucleotide.C and x2 != nucleotide.N:
            return b"A"
        if x0 == nucleotide.G and x1 == nucleotide.A and (x2 == nucleotide.T or x2 == nucleotide.C):
            return b"D"
        if x0 == nucleotide.G and x1 == nucleotide.A and (x2 == nucleotide.A or x2 == nucleotide.G):
            return b"E"
        if x0 == nucleotide.G and x1 == nucleotide.G and x2 != nucleotide.N:
            return b"G"

        return unknown_residue

    cdef int _shine_dalgarno_exact(
        self,
        const int pos,
        const int start,
        const _training* tinf,
        const int strand
    ) nogil except -1:
        cdef int i
        cdef int j
        cdef int k
        cdef int mism
        cdef int rdis
        cdef int limit
        cdef int max_val
        cdef int cmp_val
        cdef int cur_val = 0
        cdef int match[6]
        cdef int cur_ctr
        cdef int dis_flag

        # reset the match array
        match[0] = match[1] = match[2] = match[3] = match[4] = match[5] = -10

        # compute distance to SD site
        limit = min(6, start - 4 - pos)

        # Compare the 6-base region to AGGAGG
        for i in range(limit):
            if i%3 == 0:
                if _is_a(self.digits, self.slen, pos+i, strand):
                    match[i] = 2
            else:
                if _is_g(self.digits, self.slen, pos+i, strand):
                    match[i] = 3

        # Find the maximally scoring motif
        max_val = 0
        for i in range(limit, 2, -1):
            for j in range(limit+1-i):
                # count number of matching positions, skip if less than
                # GAG matching (or if a mismatch occurs)
                cur_ctr = -2
                for k in range(j, j+i):
                    cur_ctr += match[k]
                if cur_ctr < 6:
                    continue
                # compute distance to the start codon
                rdis = start - (pos + j + i)
                if rdis < 5: # 3-4bp
                    dis_flag = 2 if i < 5 else 1
                elif rdis < 11: # 5-10bp
                    dis_flag = 0
                elif rdis < 13: # 11-12bp
                    dis_flag = 1 if i < 5 else 2
                elif rdis < 16: # 13-15bp
                    dis_flag = 3
                else:
                    continue
                # match exact RBS Motifs
                if cur_ctr == 6:  # GGA
                    if dis_flag == 0:   cur_val = 13
                    elif dis_flag == 1: cur_val = 6
                    elif dis_flag == 2: cur_val = 1
                    elif dis_flag == 3: cur_val = 2
                elif cur_ctr == 8: # AGGA
                    if dis_flag == 0:   cur_val = 15
                    elif dis_flag == 1: cur_val = 12
                    elif dis_flag == 2: cur_val = 11
                    elif dis_flag == 3: cur_val = 3
                elif cur_ctr == 9: # GGAG
                    if dis_flag == 0:   cur_val = 16
                    elif dis_flag == 1: cur_val = 12
                    elif dis_flag == 2: cur_val = 11
                    elif dis_flag == 3: cur_val = 3
                elif cur_ctr == 11: # AGGAG
                    if dis_flag == 0:   cur_val = 22
                    elif dis_flag == 1: cur_val = 21
                    elif dis_flag == 2: cur_val = 20
                    elif dis_flag == 3: cur_val = 10
                elif cur_ctr == 12: # GGAGG
                    if dis_flag == 0:   cur_val = 24
                    elif dis_flag == 1: cur_val = 23
                    elif dis_flag == 2: cur_val = 20
                    elif dis_flag == 3: cur_val = 10
                elif cur_ctr == 14: # AGGAGG
                    if dis_flag == 0:   cur_val = 27
                    elif dis_flag == 1: cur_val = 26
                    elif dis_flag == 2: cur_val = 25
                    elif dis_flag == 3: cur_val = 10
                else:
                    cur_val = 0
                # record the motif only if this is the maximal scoring motif so far
                if tinf.rbs_wt[cur_val] < tinf.rbs_wt[max_val]:
                    continue
                if tinf.rbs_wt[cur_val] == tinf.rbs_wt[max_val] and cur_val < max_val:
                    continue
                max_val = cur_val

        return max_val

    cdef int _shine_dalgarno_mm(
        self,
        const int pos,
        const int start,
        const _training* tinf,
        const int strand
    ) nogil except -1:
        cdef int i
        cdef int j
        cdef int k
        cdef int mism
        cdef int rdis
        cdef int limit
        cdef int max_val
        cdef int cmp_val
        cdef int cur_val = 0
        cdef int match[6]
        cdef int cur_ctr
        cdef int dis_flag

        # reset the match array
        match[0] = match[1] = match[2] = match[3] = match[4] = match[5] = -10

        # compute distance to SD site
        limit = min(6, start - 4 - pos)

        # Compare the 6-base region to AGGAGG
        for i in range(limit):
            if i%3 == 0:
                match[i] = 2 if _is_a(self.digits, self.slen, pos+i, strand) else -3
            else:
                match[i] = 3 if _is_g(self.digits, self.slen, pos+i, strand) else -2

        # Find the maximally scoring motif
        max_val = 0
        for i in range(limit, 4, -1):
            for j in range(limit+1-i):
                # count number of matching positions, skip if less than
                # GAG matching (or if not exactly one mismatch occurs)
                cur_ctr = -2
                mism = 0;
                for k in range(j, j+i):
                    cur_ctr += match[k]
                    if match[k] < 0.0:
                        mism += 1
                        if k <= j+1 or k >= j+i-2:
                            cur_ctr -= 10
                if mism != 1 or cur_ctr < 6:
                    continue
                # compute distance to the start codon
                rdis = start - (pos + j + i)
                if rdis < 5:
                    dis_flag = 1
                elif rdis < 11:
                    dis_flag = 0
                elif rdis < 13:
                    dis_flag = 2
                elif rdis < 16:
                    dis_flag = 3
                else:
                    continue
                # match single-mismatch RBS Motifs
                if cur_ctr == 6:  # AGxAG
                    if dis_flag == 0:   cur_val = 9
                    elif dis_flag == 1: cur_val = 5
                    elif dis_flag == 2: cur_val = 4
                    elif dis_flag == 3: cur_val = 2
                elif cur_ctr == 7: # GGxGG
                    if dis_flag == 0:   cur_val = 14
                    elif dis_flag == 1: cur_val = 8
                    elif dis_flag == 2: cur_val = 7
                    elif dis_flag == 3: cur_val = 2
                elif cur_ctr == 9: # AGGxGG
                    if dis_flag == 0:   cur_val = 19
                    elif dis_flag == 1: cur_val = 18
                    elif dis_flag == 2: cur_val = 17
                    elif dis_flag == 3: cur_val = 3
                # record the motif only if this is the maximal scoring motif so far
                if tinf.rbs_wt[cur_val] < tinf.rbs_wt[max_val]:
                    continue
                if tinf.rbs_wt[cur_val] == tinf.rbs_wt[max_val] and cur_val < max_val:
                    continue
                max_val = cur_val

        return max_val

    # --- Python interface ---------------------------------------------------

    cpdef object max_gc_frame_plot(self, int window_size=_WINDOW):
        """max_gc_frame_plot(self, window_size=120)\n--

        Create a maximum GC frame plot for the sequence.

        Arguments:
            window_size (`int`): The width of the sliding window to
                use for computing the frame plot.

        Returns:
            `array.array`: An array of `int` values recording the frame
            with the highest GC content within a window for each position
            of the sequence.

        """
        if window_size < 0:
            raise ValueError(f"Invalid window size {window_size!r}")

        cdef int*   gc   = self._max_gc_frame_plot(window_size)
        cdef object mem  = PyMemoryView_FromMemory(<char*> gc, self.slen*sizeof(int), MVIEW_READ)
        cdef object plot = array.array('i')

        plot.frombytes(mem)
        free(gc)

        if len(plot) != self.slen:
            raise BufferError("Failed to copy result data from C memory")
        return plot

    cpdef int shine_dalgarno(
        self,
        int pos,
        int start,
        TrainingInfo training_info,
        int strand=1,
        bint exact=True
    ) except -1:
        """shine_dalgarno(self, pos, start, training_info, strand=1, exact=True)\n--

        Find the highest scoring Shine-Dalgarno motif upstream of ``start``.

        Arguments:
            pos (`int`): The position where to look for the Shine-Dalgarno
                motif. Must be upstream of ``start`` (before or after,
                depending on the strand).
            start (`int`): The position of the start codon being considered.
            training_info (`~pyrodigal.TrainingInfo`): The training info
                containing the weights for the different ribosome weights.

        Keyword Arguments:
            strand (`int`): The strand to scan.
            exact (`bool`): `True` to score Shine-Dalgarno motifs matching
                exactly *AGGAGG*, `False` to allow one base mismatch.

        Returns:
            `int`: The index of the highest scoring Shine-Dalgarno motif.

        Raises:
            `ValueError`: On invalid `strand`, `pos` or `start` values.

        """
        if strand != 1 and strand != -1:
            raise ValueError(f"Invalid strand: {strand!r} (must be +1 or -1)")
        if pos < 0:
            raise ValueError(f"`pos` must be positive")
        if start < 0:
            raise ValueError(f"`start` must be positive")

        cdef int phase
        with nogil:
            if exact:
                phase = self._shine_dalgarno_exact(pos, start, training_info.tinf, strand)
            else:
                phase = self._shine_dalgarno_mm(pos, start, training_info.tinf, strand)

        return phase


# --- Connection Scorer ------------------------------------------------------

_TARGET_CPU           = TARGET_CPU
_AVX2_RUNTIME_SUPPORT = False
_NEON_RUNTIME_SUPPORT = False
_SSE2_RUNTIME_SUPPORT = False
_MMX_RUNTIME_SUPPORT  = False
_AVX2_BUILD_SUPPORT   = False
_NEON_BUILD_SUPPORT   = False
_SSE2_BUILD_SUPPORT   = False
_MMX_BUILD_SUPPORT    = False

IF TARGET_CPU == "x86" and TARGET_SYSTEM in ("freebsd", "linux_or_android", "macos", "windows"):
    from pyrodigal.cpu_features.x86 cimport GetX86Info, X86Info
    cdef X86Info cpu_info = GetX86Info()
    _MMX_BUILD_SUPPORT    = MMX_BUILD_SUPPORT
    _SSE2_BUILD_SUPPORT   = SSE2_BUILD_SUPPORT
    _AVX2_BUILD_SUPPORT   = AVX2_BUILD_SUPPORT
    _MMX_RUNTIME_SUPPORT  = cpu_info.features.mmx  != 0
    _SSE2_RUNTIME_SUPPORT = cpu_info.features.sse2 != 0
    _AVX2_RUNTIME_SUPPORT = cpu_info.features.avx2 != 0
ELIF TARGET_CPU == "arm" and TARGET_SYSTEM == "linux_or_android":
    from pyrodigal.cpu_features.arm cimport GetArmInfo, ArmInfo
    cdef ArmInfo cpu_info = GetArmInfo()
    _NEON_BUILD_SUPPORT   = NEON_BUILD_SUPPORT
    _NEON_RUNTIME_SUPPORT = cpu_info.features.neon != 0
ELIF TARGET_CPU == "aarch64":
    _NEON_BUILD_SUPPORT   = NEON_BUILD_SUPPORT
    _NEON_RUNTIME_SUPPORT = NEON_BUILD_SUPPORT

cdef enum simd_backend:
    NONE = 0
    MMX = 1
    SSE2 = 2
    AVX2 = 3
    NEON = 4
    GENERIC = 5

cdef class ConnectionScorer:
    """A dedicated class for the fast scoring of nodes.
    """

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self.capacity = 0
        self.skip_connection = self.skip_connection_raw = NULL
        self.node_types      = self.node_types_raw      = NULL
        self.node_strands    = self.node_strands_raw    = NULL
        self.node_frames     = self.node_frames_raw     = NULL

    def __init__(self, str backend="detect"):
        """__init__(self, backend="detect")\n--

        Create a new connection score.

        Arguments:
            backend (`str`): The SIMD backend to use for the heuristic filter.
                Use ``"detect"`` to use the best available one depending on
                the CPU capabilities of the local machine. Other available
                values are: ``"generic"``, ``"sse"``, ``"avx"``, ``neon``.

        """
        IF TARGET_CPU == "x86":
            if backend == "detect":
                self.backend = simd_backend.NONE
                IF MMX_BUILD_SUPPORT:
                    if _MMX_RUNTIME_SUPPORT:
                        self.backend = simd_backend.MMX
                IF SSE2_BUILD_SUPPORT:
                    if _SSE2_RUNTIME_SUPPORT:
                        self.backend = simd_backend.SSE2
                IF AVX2_BUILD_SUPPORT:
                    if _AVX2_RUNTIME_SUPPORT:
                        self.backend = simd_backend.AVX2
            elif backend == "mmx":
                IF not MMX_BUILD_SUPPORT:
                    raise RuntimeError("Extension was compiled without MMX support")
                ELSE:
                    if not _MMX_RUNTIME_SUPPORT:
                        raise RuntimeError("Cannot run MMX instructions on this machine")
                    self.backend = simd_backend.MMX
            elif backend == "sse":
                IF not SSE2_BUILD_SUPPORT:
                    raise RuntimeError("Extension was compiled without SSE2 support")
                ELSE:
                    if not _SSE2_RUNTIME_SUPPORT:
                        raise RuntimeError("Cannot run SSE2 instructions on this machine")
                    self.backend = simd_backend.SSE2
            elif backend == "avx":
                IF not AVX2_BUILD_SUPPORT:
                    raise RuntimeError("Extension was compiled without AVX2 support")
                ELSE:
                    if not _AVX2_RUNTIME_SUPPORT:
                        raise RuntimeError("Cannot run AVX2 instructions on this machine")
                    self.backend = simd_backend.AVX2
            elif backend == "generic":
                self.backend = simd_backend.GENERIC
            elif backend is None:
                self.backend = simd_backend.NONE
            else:
                raise ValueError(f"Unsupported backend on this architecture: {backend}")
        ELIF TARGET_CPU == "arm" or TARGET_CPU == "aarch64":
            if backend == "detect":
                self.backend = simd_backend.NONE
                IF NEON_BUILD_SUPPORT:
                    if _NEON_RUNTIME_SUPPORT:
                        self.backend = simd_backend.NEON
            elif backend == "neon":
                IF not NEON_BUILD_SUPPORT:
                    raise RuntimeError("Extension was compiled without NEON support")
                ELSE:
                    if not _NEON_RUNTIME_SUPPORT:
                        raise RuntimeError("Cannot run NEON instructions on this machine")
                    self.backend = simd_backend.NEON
            elif backend == "generic":
                self.backend = simd_backend.GENERIC
            elif backend is None:
                self.backend = simd_backend.NONE
            else:
                raise ValueError(f"Unsupported backend on this architecture: {backend}")
        ELSE:
            if backend == "detect":
                self.backend = simd_backend.NONE
            if backend == "generic":
                self.backend = simd_backend.GENERIC
            elif backend is None:
                self.backend = simd_backend.NONE
            else:
                raise ValueError(f"Unsupported backend on this architecture: {backend}")

    def __dealloc__(self):
        PyMem_Free(self.node_types_raw)
        PyMem_Free(self.node_strands_raw)
        PyMem_Free(self.node_frames_raw)
        PyMem_Free(self.skip_connection_raw)

    cpdef size_t __sizeof__(self):
        return sizeof(self) + (self.capacity * sizeof(uint8_t) + 0x1F) * 4

    # --- C interface --------------------------------------------------------

    cdef int _index(self, Nodes nodes) nogil except -1:
        cdef size_t i
        # nothing to be done if we are using the Prodigal code
        if self.backend == simd_backend.NONE:
            return 0
        # reallocate if needed
        if self.capacity < nodes.length:
            with gil:
                # reallocate new memory
                self.skip_connection_raw = <uint8_t*> PyMem_Realloc(self.skip_connection_raw, nodes.length * sizeof(uint8_t) + 0x1F)
                self.node_types_raw      = <uint8_t*> PyMem_Realloc(self.node_types_raw, nodes.length      * sizeof(uint8_t) + 0x1F)
                self.node_strands_raw    = <int8_t*>  PyMem_Realloc(self.node_strands_raw, nodes.length    * sizeof(int8_t)  + 0x1F)
                self.node_frames_raw     = <uint8_t*> PyMem_Realloc(self.node_frames_raw, nodes.length     * sizeof(uint8_t) + 0x1F)
                # check that allocations were successful
                if self.skip_connection_raw == NULL:
                    raise MemoryError("Failed to allocate memory for scoring bypass index")
                if self.node_types_raw == NULL:
                    raise MemoryError("Failed to allocate memory for node type array")
                if self.node_strands_raw == NULL:
                    raise MemoryError("Failed to allocate memory for node strand array")
                if self.node_frames_raw == NULL:
                    raise MemoryError("Failed to allocate memory for node frame array")
            # record new capacity
            self.capacity = nodes.length
            # compute pointers to aligned memory
            self.skip_connection = <uint8_t*> ((<uintptr_t> self.skip_connection_raw + 0x1F) & (~0x1F))
            self.node_types      = <uint8_t*> ((<uintptr_t> self.node_types_raw      + 0x1F) & (~0x1F))
            self.node_strands    = <int8_t*>  ((<uintptr_t> self.node_strands_raw    + 0x1F) & (~0x1F))
            self.node_frames     = <uint8_t*> ((<uintptr_t> self.node_frames_raw     + 0x1F) & (~0x1F))
        # copy data from the array of nodes
        for i in range(nodes.length):
            self.node_types[i]      = nodes.nodes[i].type
            self.node_strands[i]    = nodes.nodes[i].strand
            self.node_frames[i]     = nodes.nodes[i].ndx % 3
            self.skip_connection[i] = False
        # return 0 if no exceptions were raised
        return 0

    cdef int _compute_skippable(
        self,
        int min,
        int i
    ) nogil:
        IF AVX2_BUILD_SUPPORT:
            if self.backend == simd_backend.AVX2:
                skippable_avx(self.node_strands, self.node_types, self.node_frames, min, i, self.skip_connection)
                return 0
        IF SSE2_BUILD_SUPPORT:
            if self.backend == simd_backend.SSE2:
                skippable_sse(self.node_strands, self.node_types, self.node_frames, min, i, self.skip_connection)
                return 0
        IF MMX_BUILD_SUPPORT:
            if self.backend == simd_backend.MMX:
                skippable_mmx(self.node_strands, self.node_types, self.node_frames, min, i, self.skip_connection)
                return 0
        IF NEON_BUILD_SUPPORT:
            if self.backend == simd_backend.NEON:
                skippable_neon(self.node_strands, self.node_types, self.node_frames, min, i, self.skip_connection)
                return 0
        if self.backend == simd_backend.GENERIC:
            skippable_generic(self.node_strands, self.node_types, self.node_frames, min, i, self.skip_connection)
            return 0
        return 0

    cdef void _score_connections(
        self,
        Nodes nodes,
        const int min,
        const int i,
        const _training* tinf,
        const bint final
    ) nogil:
        cdef int j
        # NOTE: For comparison / testing purposes, it's still possible to
        #       score connections exactly the way it's done in the original
        #       Prodigal code.
        if self.backend == simd_backend.NONE:
            for j in range(min, i):
                dprog.score_connection(nodes.nodes, j, i, <_training*> tinf, final)
        else:
            _score_connections(
                self.skip_connection,
                self.node_types,
                self.node_strands,
                nodes.nodes,
                min,
                i,
                tinf,
                final
            )

    # --- Python interface ---------------------------------------------------

    def index(self, Nodes nodes not None):
        """index(self, nodes)\n--

        Index the nodes in preparation for the heuristic SIMD filter.

        """
        with nogil:
            self._index(nodes)

    def compute_skippable(self, int min, int i):
        """compute_skippable(self, min, i)\n--

        Find which connections to node *i* are invalid, starting from *min*.

        Arguments:
            min (`int`): The index of the first node from which to start
                scoring connections.
            i (`int`): The index of the node to score.

        """
        assert (self.skip_connection != NULL) | (self.backend == simd_backend.NONE)
        assert (i < <int> self.capacity) | (self.backend == simd_backend.NONE)
        assert min <= i
        with nogil:
            self._compute_skippable(min, i)

    def score_connections(
        self,
        Nodes nodes not None,
        int min,
        int i,
        TrainingInfo tinf not None,
        bint final=False
    ):
        """score_connections(self, nodes, min, i, tinf, final=False)\n--

        Score all connections to node *i*, starting from node *min*.

        Arguments:
            nodes (`~pyrodigal.Nodes`): The array of nodes to score.
            min (`int`): The index of the first node from which to start
                scoring connections.
            i (`int`): The index of the node to score.
            tinf (`~pyrodigal.TrainingInfo`): The training info from which
                to read the start codon weights.
            final (`bool`): ``False`` when the scoring occurs during training,
                ``True`` otherwise.

        """
        assert (self.skip_connection != NULL) | (self.backend == simd_backend.NONE)
        assert (i < <int> nodes.length) | (self.backend == simd_backend.NONE)
        assert min <= i
        with nogil:
            self._score_connections(nodes, min, i, tinf.tinf, final)


# --- Nodes ------------------------------------------------------------------

cdef class Node:
    """A dynamic programming node used by Prodigal to score ORFs.

    .. versionadded:: 0.5.4

    """

    # --- Magic methods ------------------------------------------------------

    def __init__(self):
        raise TypeError("Cannot instantiate `Node` objects directly")

    def __repr__(self):
        ty = type(self)
        return "<{}.{} index={!r} strand={:+} type={!r} edge={!r}>".format(
            ty.__module__,
            ty.__name__,
            self.index,
            self.strand,
            self.type,
            self.edge,
        )

    # --- Properties ---------------------------------------------------------

    @property
    def index(self):
        """`int`: The position of the node in the sequence.

        Hint:
            This coordinate is zero-based: a node at index 0 will correspond
            to a start or stop codon at the very beginning of the sequence.

        .. versionadded:: 0.7.0

        """
        assert self.node != NULL
        return self.node.ndx

    @property
    def strand(self):
        """`int`: *-1* if the node is on the reverse strand, *+1* otherwise.

        .. versionadded:: 0.7.0

        """
        return self.node.strand

    @property
    def type(self):
        """`str`: The node type (``ATG``, ``GTG``, ``TTG``, or ``Stop``).
        """
        assert self.node != NULL
        return ["ATG", "GTG", "TTG" , "Stop"][self.node.type]

    @property
    def edge(self):
        """`bool`: `True` if the node runs off the edge.
        """
        assert self.node != NULL
        return self.node.edge

    @property
    def gc_bias(self):
        """`int`: The frame of highest GC content within this node.
        """
        assert self.node != NULL
        return self.node.gc_bias

    @property
    def cscore(self):
        """`float`: The coding score for this node, based on 6-mer usage.
        """
        assert self.node != NULL
        return self.node.cscore

    @property
    def gc_cont(self):
        """`float`: The GC content for the node.
        """
        assert self.node != NULL
        return self.node.gc_cont

    @property
    def score(self):
        """`float`: The score of the total solution up to this node.
        """
        assert self.node != NULL
        return self.node.score

    @property
    def rscore(self):
        """`float`: The score for the RBS motif.

        .. versionadded:: 0.7.0

        """
        return self.node.rscore

    @property
    def sscore(self):
        """`float`: The score for the strength of the start codon.

        .. versionadded:: 0.7.0

        """
        return self.node.sscore

    @property
    def tscore(self):
        """`float`: The score for the codon kind (``ATG``/``GTG``/``TTG``).

        .. versionadded:: 0.7.0

        """
        return self.node.tscore

    # --- C interface --------------------------------------------------------

    @staticmethod
    cdef void _find_best_upstream_motif(
        _node* node,
        Sequence seq,
        const _training* tinf,
        const int stage
    ) nogil:
        cdef int i
        cdef int j
        cdef int start
        cdef int spacendx
        cdef int index
        cdef int max_spacer   = 0
        cdef int max_spacendx = 0
        cdef int max_len      = 0
        cdef int max_ndx      = 0
        cdef double max_sc    = -100.0
        cdef double score     = 0.0

        if node.type == node_type.STOP or node.edge:
            return

        if node.strand == 1:
            start = node.ndx
        else:
            start = seq.slen - 1 - node.ndx

        for i in reversed(range(4)):
            for j in range(start-18-i, start-5-i):
                if j < 0:
                    continue
                if j <= start - 16 - i:
                    spacendx = 3
                elif j <= start - 14 - i:
                    spacendx = 2
                elif j >= start - 7 - i:
                    spacendx = 1
                else:
                    spacendx = 0

                index = _mer_ndx(seq.digits, seq.slen, j, i+3, node.strand)
                score = tinf.mot_wt[i][spacendx][index]
                if score > max_sc:
                    max_sc = score
                    max_spacendx = spacendx
                    max_spacer = start - j - i - 3
                    max_ndx = index
                    max_len = i+3

        if stage == 2 and (max_sc == -4.0 or max_sc < tinf.no_mot + 0.69):
            node.mot.ndx = 0
            node.mot.len = 0
            node.mot.spacendx = 0
            node.mot.spacer = 0
            node.mot.score = tinf.no_mot
        else:
            node.mot.ndx = max_ndx
            node.mot.len = max_len
            node.mot.spacendx = max_spacendx
            node.mot.spacer = max_spacer
            node.mot.score = max_sc

    @staticmethod
    cdef void _score_upstream_composition(
        _node* node,
        Sequence seq,
        const _training* tinf,
    ) nogil:
        cdef int i
        cdef int start
        cdef int count = 0
        cdef int mer
        cdef int strand

        if node.strand == 1:
            start = node.ndx
            strand = 1
        else:
            start = seq.slen - 1 - node.ndx
            strand = -1

        node.uscore = 0.0;
        for i in range(1, 45):
            if i > 2 and i < 15:
                continue
            if i > start:
                continue
            mer = _mer_ndx(seq.digits, seq.slen, start - i, 1, strand=strand)
            node.uscore += 0.4 * tinf.st_wt * tinf.ups_comp[count][mer]
            count += 1

cdef class Nodes:
    """A list of dynamic programming nodes used by Prodigal to score ORFs.

    .. versionadded:: 0.5.4

    """

    # --- Class methods ------------------------------------------------------

    @classmethod
    def with_capacity(cls, size_t capacity):
        """with_capacity(cls, capacity)\n--

        Create a new node array with the given capacity.

        """
        cdef Nodes nodes = Nodes.__new__(Nodes)
        nodes._allocate(capacity)
        return nodes

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self.nodes = NULL
        self.capacity = 0
        self.length = 0

    def __init__(self):
        self._clear()

    def __dealloc__(self):
        PyMem_Free(self.nodes)

    def __copy__(self):
        return self.copy()

    def __len__(self):
        return self.length

    def __getitem__(self, ssize_t index):
        cdef Node node
        if index < 0:
            index += <ssize_t> self.length
        if index >= <ssize_t> self.length or index < 0:
            raise IndexError("list index out of range")
        node = Node.__new__(Node)
        node.owner = self
        node.node = &self.nodes[index]
        return node

    cpdef size_t __sizeof__(self):
        return self.capacity * sizeof(_node) + sizeof(self)

    cpdef list __getstate__(self):
        """__getstate__(self)\n--
        """
        cdef size_t i
        return [
            {
                "type": self.nodes[i].type,
                "edge": self.nodes[i].edge,
                "ndx": self.nodes[i].ndx,
                "strand": self.nodes[i].strand,
                "stop_val": self.nodes[i].stop_val,
                "star_ptr": [
                    self.nodes[i].star_ptr[0],
                    self.nodes[i].star_ptr[1],
                    self.nodes[i].star_ptr[2],
                ],
                "gc_bias": self.nodes[i].gc_bias,
                "gc_score": [
                    self.nodes[i].gc_score[0],
                    self.nodes[i].gc_score[1],
                    self.nodes[i].gc_score[2],
                ],
                "cscore": self.nodes[i].cscore,
                "gc_cont": self.nodes[i].gc_cont,
                "rbs": [
                    self.nodes[i].rbs[0],
                    self.nodes[i].rbs[1],
                ],
                "motif": {
                    "ndx": self.nodes[i].mot.ndx,
                    "len": self.nodes[i].mot.len,
                    "spacer": self.nodes[i].mot.spacer,
                    "spacendx": self.nodes[i].mot.spacendx,
                    "score": self.nodes[i].mot.spacendx,
                },
                "uscore": self.nodes[i].uscore,
                "tscore": self.nodes[i].tscore,
                "rscore": self.nodes[i].rscore,
                "sscore": self.nodes[i].sscore,
                "traceb": self.nodes[i].traceb,
                "tracef": self.nodes[i].tracef,
                "ov_mark": self.nodes[i].ov_mark,
                "score": self.nodes[i].score,
                "elim": self.nodes[i].elim,
            }
            for i in range(self.length)
        ]

    cpdef object __setstate__(self, list state):
        """__setstate__(self, state)\n--
        """
        cdef size_t i
        cdef dict   node
        cdef dict   motif

        # realloc to the exact number of nodes
        self.length = self.capacity = len(state)
        if self.capacity > 0:
            self.nodes = <_node*> PyMem_Realloc(self.nodes, self.capacity * sizeof(_node))
            if self.nodes == NULL:
                raise MemoryError("Failed to reallocate node array")
        else:
            PyMem_Free(self.nodes)
            self.nodes = NULL

        # copy node data from the state dictionary
        for i, node in enumerate(state):
            motif = node["motif"]
            self.nodes[i].type = node["type"]
            self.nodes[i].edge = node["edge"]
            self.nodes[i].ndx = node["ndx"]
            self.nodes[i].strand = node["strand"]
            self.nodes[i].stop_val = node["stop_val"]
            self.nodes[i].star_ptr = node["star_ptr"]
            self.nodes[i].gc_bias = node["gc_bias"]
            self.nodes[i].gc_score = node["gc_score"]
            self.nodes[i].cscore = node["cscore"]
            self.nodes[i].gc_cont = node["gc_cont"]
            self.nodes[i].rbs = node["rbs"]
            self.nodes[i].mot.ndx = motif["ndx"]
            self.nodes[i].mot.len = motif["len"]
            self.nodes[i].mot.spacer = motif["spacer"]
            self.nodes[i].mot.spacendx = motif["spacendx"]
            self.nodes[i].mot.score = motif["score"]
            self.nodes[i].uscore = node["uscore"]
            self.nodes[i].tscore = node["tscore"]
            self.nodes[i].rscore = node["rscore"]
            self.nodes[i].sscore = node["sscore"]
            self.nodes[i].traceb = node["traceb"]
            self.nodes[i].tracef = node["tracef"]
            self.nodes[i].ov_mark = node["ov_mark"]
            self.nodes[i].score = node["score"]
            self.nodes[i].elim = node["elim"]

    # --- C interface --------------------------------------------------------

    cdef int _allocate(self, size_t capacity) except 1:
        # record new capacity
        cdef size_t old_capacity = self.capacity
        self.capacity = capacity
        # allocate node array
        self.nodes = <_node*> PyMem_Realloc(self.nodes, self.capacity * sizeof(_node))
        if self.nodes == NULL:
            raise MemoryError("Failed to reallocate node array")
        # clean newly-allocated memory
        if self.capacity > old_capacity:
            memset(&self.nodes[old_capacity], 0, (self.capacity - old_capacity) * sizeof(_node))
        return 0

    cdef inline _node* _add_node(
        self,
        const int  ndx,
        const int  type,
        const int  strand,
        const int  stop_val,
        const bint edge,
    ) nogil except NULL:
        """Add a single node to the vector, and return a pointer to that node.
        """
        # reallocate if needed
        if self.length >= self.capacity:
            with gil:
                self._allocate(MIN_NODES_ALLOC if self.capacity == 0 else new_capacity(self.capacity))
        # record node data
        self.length += 1
        cdef _node* node = &self.nodes[self.length - 1]
        node.ndx = ndx
        node.type = type
        node.strand = strand
        node.stop_val = stop_val
        node.edge = edge
        return node

    cdef int _calc_orf_gc(self, Sequence seq) nogil except -1:
        cdef int i
        cdef int j
        cdef int last[3]
        cdef int phase
        cdef double gc[3]
        cdef double gsize = 0.0

        # direct strand
        gc[0] = gc[1] = gc[2] = 0.0
        for i in reversed(range(<int> self.length)):
            if self.nodes[i].strand == 1:
                phase = self.nodes[i].ndx %3
                if self.nodes[i].type == node_type.STOP:
                    last[phase] = j = self.nodes[i].ndx
                    gc[phase] = (
                        _is_gc(seq.digits, seq.slen, j,   1)
                      + _is_gc(seq.digits, seq.slen, j+1, 1)
                      + _is_gc(seq.digits, seq.slen, j+2, 1)
                    )
                else:
                    for j in range(last[phase] - 3, self.nodes[i].ndx - 1, -3):
                        gc[phase] += (
                            _is_gc(seq.digits, seq.slen, j,   1)
                          + _is_gc(seq.digits, seq.slen, j+1, 1)
                          + _is_gc(seq.digits, seq.slen, j+2, 1)
                        )
                    gsize = abs(self.nodes[i].stop_val - self.nodes[i].ndx) + 3.0
                    self.nodes[i].gc_cont = gc[phase] / gsize
                    last[phase] = self.nodes[i].ndx

        # reverse strand
        gc[0] = gc[1] = gc[2] = 0.0
        for i in range(<int> self.length):
            if self.nodes[i].strand == -1:
                phase = self.nodes[i].ndx % 3
                if self.nodes[i].type == node_type.STOP:
                    last[phase] = j = self.nodes[i].ndx
                    gc[phase] = (
                        _is_gc(seq.digits, seq.slen, j,   1)
                      + _is_gc(seq.digits, seq.slen, j-1, 1)
                      + _is_gc(seq.digits, seq.slen, j-2, 1)
                    )
                else:
                    for j in range(last[phase] + 3, self.nodes[i].ndx + 1, 3):
                        gc[phase] += (
                              _is_gc(seq.digits, seq.slen, j,   1)
                            + _is_gc(seq.digits, seq.slen, j+1, 1)
                            + _is_gc(seq.digits, seq.slen, j+2, 1)
                        )
                    gsize = abs(self.nodes[i].stop_val - self.nodes[i].ndx) + 3.0
                    self.nodes[i].gc_cont = gc[phase] / gsize
                    last[phase] = self.nodes[i].ndx

        # return 0 on success
        return 0

    cdef int _clear(self) nogil except 1:
        """Remove all nodes from the vector.
        """
        cdef size_t old_length
        old_length, self.length = self.length, 0
        memset(self.nodes, 0, old_length * sizeof(_node))

    cdef int _dynamic_programming(
        self,
        const _training* tinf,
        ConnectionScorer scorer,
        const bint final
    ) nogil:
        cdef int    i
        cdef int    j
        cdef int    min
        cdef int    path
        cdef int    nxt
        cdef int    tmp
        cdef int    max_ndx = -1
        cdef double max_sc  = -1.0

        if self.length == 0:
            return -1

        for i in range(<int> self.length):
            self.nodes[i].score = 0
            self.nodes[i].traceb = -1
            self.nodes[i].tracef = -1

        for i in range(<int> self.length):
            # Set up distance constraints for making connections,
            # but make exceptions for giant ORFS.
            min = 0 if i < dprog.MAX_NODE_DIST else i - dprog.MAX_NODE_DIST
            if self.nodes[i].strand == -1 and self.nodes[i].type != node_type.STOP and self.nodes[min].ndx >= self.nodes[i].stop_val:
                if self.nodes[i].ndx != self.nodes[i].stop_val:
                    min = 0
            elif self.nodes[i].strand == 1 and self.nodes[i].type == node_type.STOP and self.nodes[min].ndx >= self.nodes[i].stop_val:
                if self.nodes[i].ndx != self.nodes[i].stop_val:
                    min = 0
            min = 0 if min < dprog.MAX_NODE_DIST else min - dprog.MAX_NODE_DIST
            # Check which nodes can be skipped
            scorer._compute_skippable(min, i)
            # Score connections
            scorer._score_connections(self, min, i, tinf, final)

        for i in reversed(range(<int> self.length)):
            if self.nodes[i].strand == 1 and self.nodes[i].type != node_type.STOP:
                continue
            if self.nodes[i].strand == -1 and self.nodes[i].type == node_type.STOP:
                continue
            if self.nodes[i].score > max_sc:
                max_sc = self.nodes[i].score
                max_ndx = i

        # First Pass: untangle the triple overlaps
        path = max_ndx
        while self.nodes[path].traceb != -1:
            nxt = self.nodes[path].traceb
            if self.nodes[path].strand == -1 and self.nodes[path].type == node_type.STOP and self.nodes[nxt].strand == 1 and self.nodes[nxt].type == node_type.STOP and self.nodes[path].ov_mark != -1 and self.nodes[path].ndx > self.nodes[nxt].ndx:
                tmp = self.nodes[path].star_ptr[self.nodes[path].ov_mark];
                i = tmp
                while self.nodes[i].ndx != self.nodes[tmp].stop_val:
                    i -= 1
                self.nodes[path].traceb = tmp
                self.nodes[tmp].traceb = i
                self.nodes[i].ov_mark = -1
                self.nodes[i].traceb = nxt
            path = self.nodes[path].traceb

        # Second Pass: Untangle the simple overlaps
        path = max_ndx
        while self.nodes[path].traceb != -1:
            nxt = self.nodes[path].traceb
            if self.nodes[path].strand == -1 and self.nodes[path].type != node_type.STOP and self.nodes[nxt].strand == 1 and self.nodes[nxt].type == node_type.STOP:
                i = path
                while self.nodes[i].ndx != self.nodes[path].stop_val:
                    i -= 1
                self.nodes[path].traceb = i
                self.nodes[i].traceb = nxt
            if self.nodes[path].strand == 1 and self.nodes[path].type == node_type.STOP and self.nodes[nxt].strand == 1 and self.nodes[nxt].type == node_type.STOP:
                self.nodes[path].traceb = self.nodes[nxt].star_ptr[self.nodes[path].ndx%3]
                self.nodes[self.nodes[path].traceb].traceb = nxt
            if self.nodes[path].strand == -1 and self.nodes[path].type == node_type.STOP and self.nodes[nxt].strand == -1 and self.nodes[nxt].type == node_type.STOP:
                self.nodes[path].traceb = self.nodes[path].star_ptr[self.nodes[nxt].ndx%3]
                self.nodes[self.nodes[path].traceb].traceb = nxt
            path = self.nodes[path].traceb

        # Mark forward pointers
        path = max_ndx
        while self.nodes[path].traceb != -1:
            self.nodes[self.nodes[path].traceb].tracef = path
            path = self.nodes[path].traceb

        return -1 if self.nodes[max_ndx].traceb == -1 else max_ndx

    cdef int _extract(
        self,
        Sequence sequence,
        int translation_table,
        bint closed,
        int min_gene,
        int min_edge_gene,
    ) nogil except -1:
        cdef int    i
        cdef int    j
        cdef bint   skip
        cdef _mask* mask[3]
        cdef int    last[3]
        cdef int    min_dist[3]
        cdef bint   saw_start[3]
        cdef int    slmod        = sequence.slen % 3
        cdef int    nn           = 0
        cdef int    tt           = translation_table

        # If sequence is smaller than a codon, there are no nodes to add
        if sequence.slen < 3:
            return nn

        # Forward strand nodes
        if sequence.masks.length > 0:
            mask[0] = mask[1] = mask[2] = &sequence.masks.masks[sequence.masks.length - 1]
        else:
            mask[0] = mask[1] = mask[2] = NULL
        for i in range(3):
            last[(i+slmod)%3] = sequence.slen + i
            saw_start[i%3] = False
            min_dist[i%3] = min_edge_gene
            if not closed:
                while last[(i+slmod)%3] + 3 > sequence.slen:
                    last[(i+slmod)%3] -= 3
        for i in reversed(range(sequence.slen-2)):
            # check if the current phase encountered a stop
            if _is_stop(sequence.digits, sequence.slen, i, tt, 1):
                if saw_start[i%3]:
                    self._add_node(
                        ndx = last[i%3],
                        type = node_type.STOP,
                        strand = 1,
                        stop_val = i,
                        edge = not _is_stop(sequence.digits, sequence.slen, last[i%3], tt, 1),
                    )
                    nn += 1
                min_dist[i%3] = min_gene
                last[i%3] = i
                saw_start[i%3] = False
                continue
            if last[i%3] >= sequence.slen:
                continue
            # find the next phase mask if the candidate gene end is after the mask start
            while mask[i%3] != NULL and last[i%3] < mask[i%3].begin:
                if mask[i%3] == &sequence.masks.masks[0]:
                    mask[i%3] = NULL
                else:
                    mask[i%3] -= 1
            # check that the current phase mask does not intersect the candidate gene
            if Mask._intersects(mask[i%3], i, last[i%3]):
                continue
            # check if the current phase encountered a start
            if last[i%3] - i + 3 >= min_dist[i%3] and _is_start(sequence.digits, sequence.slen, i, tt, 1):
                if _is_a(sequence.digits, sequence.slen, i, 1):
                    saw_start[i%3] = True
                    self._add_node(
                        ndx = i,
                        type = node_type.ATG,
                        stop_val = last[i%3],
                        strand = 1,
                        edge = False
                    )
                    nn += 1
                elif _is_t(sequence.digits, sequence.slen, i, 1):
                    saw_start[i%3] = True
                    self._add_node(
                        ndx = i,
                        type = node_type.TTG,
                        stop_val = last[i%3],
                        strand = 1,
                        edge = False
                    )
                    nn += 1
                elif _is_g(sequence.digits, sequence.slen, i, 1):
                    saw_start[i%3] = True
                    self._add_node(
                        ndx = i,
                        type = node_type.GTG,
                        stop_val = last[i%3],
                        strand = 1,
                        edge = False
                    )
                    nn += 1
                else:
                    raise RuntimeError("Encountered a STOP codon that is none of ATG/TTG/GTG")
            elif i <= 2 and not closed and last[i%3] - i > min_edge_gene:
                saw_start[i%3] = True
                self._add_node(
                    ndx = i,
                    type = node_type.ATG,
                    stop_val = last[i%3],
                    strand = 1,
                    edge = True,
                )
                nn += 1
        for i in range(3):
            if saw_start[i%3]:
                self._add_node(
                    ndx = last[i%3],
                    type = node_type.STOP,
                    strand = 1,
                    stop_val = i - 6,
                    edge = not _is_stop(sequence.digits, sequence.slen, last[i%3], tt, 1)
                )
                nn += 1

        # Reverse strand nodes
        if sequence.masks.length > 0:
            mask[0] = mask[1] = mask[2] = &sequence.masks.masks[0]
        else:
            mask[0] = mask[1] = mask[2] = NULL
        for i in range(3):
            last[(i + slmod) % 3] = sequence.slen + i
            saw_start[i%3] = False
            min_dist[i%3] = min_edge_gene
            if not closed:
                while last[(i+slmod) % 3] + 3 > sequence.slen:
                    last[(i+slmod)%3] -= 3
        for i in reversed(range(sequence.slen-2)):
            # check if the current phase encountered a stop
            if _is_stop(sequence.digits, sequence.slen, i, tt, -1):
                if saw_start[i%3]:
                    self._add_node(
                        ndx = sequence.slen - last[i%3] - 1,
                        type = node_type.STOP,
                        strand = -1,
                        stop_val = sequence.slen - i - 1,
                        edge = not _is_stop(sequence.digits, sequence.slen, last[i%3], tt, -1)
                    )
                    nn += 1
                min_dist[i%3] = min_gene
                last[i%3] = i
                saw_start[i%3] = False
                continue
            if last[i%3] >= sequence.slen:
                continue
            # find the next phase mask if the candidate gene start is after the mask end
            while mask[i%3] != NULL and sequence.slen-last[i%3]-1 > mask[i%3].end:
                if mask[i%3] == &sequence.masks.masks[sequence.masks.length]:
                    mask[i%3] = NULL
                else:
                    mask[i%3] += 1
            # check that the current phase mask does not intersect the candidate gene

            if Mask._intersects(mask[i%3], sequence.slen-last[i%3]-1, sequence.slen-i-1):
                continue
            # check if the current phase encountered a start
            if last[i%3] - i + 3 >= min_dist[i%3] and _is_start(sequence.digits, sequence.slen, i, tt, -1):
                if _is_a(sequence.digits, sequence.slen, i, -1):
                    saw_start[i%3] = True
                    self._add_node(
                        ndx = sequence.slen - i - 1,
                        type = node_type.ATG,
                        strand = -1,
                        stop_val = sequence.slen - last[i%3] - 1,
                        edge = False
                    )
                    nn += 1
                elif _is_g(sequence.digits, sequence.slen, i, -1):
                    saw_start[i%3] = True
                    self._add_node(
                        ndx = sequence.slen - i - 1,
                        type = node_type.GTG,
                        strand = -1,
                        stop_val = sequence.slen - last[i%3] - 1,
                        edge = False
                    )
                    nn += 1
                elif _is_t(sequence.digits, sequence.slen, i, -1):
                    saw_start[i%3] = 1
                    self._add_node(
                        ndx = sequence.slen - i - 1,
                        type = node_type.TTG,
                        strand = -1,
                        stop_val = sequence.slen - last[i%3] - 1,
                        edge = False,
                    )
                    nn += 1
                else:
                    raise RuntimeError("Encountered a STOP codon that is none of ATG/TTG/GTG")
            elif i <= 2 and not closed and last[i%3] - i > min_edge_gene:
                saw_start[i%3] = 1
                node = self._add_node(
                    ndx = sequence.slen - i - 1,
                    type = node_type.ATG,
                    strand = -1,
                    stop_val = sequence.slen - last[i%3] - 1,
                    edge = True,
                )
                nn += 1
        for i in range(3):
            if saw_start[i%3]:
                node = self._add_node(
                    ndx = sequence.slen - last[i%3] - 1,
                    type = node_type.STOP,
                    strand = -1,
                    stop_val = sequence.slen - i + 5,
                    edge = not _is_stop(sequence.digits, sequence.slen, last[i%3], tt, -1),
                )
                nn += 1

        return nn

    cdef int _raw_coding_score(
        self,
        Sequence seq,
        const _training* tinf
    ) nogil except -1:
        cdef double  score[3]
        cdef double  lfac
        cdef double  no_stop
        cdef double  gsize
        cdef ssize_t last[3]
        cdef size_t  phase
        cdef ssize_t j
        cdef ssize_t i
        cdef ssize_t nn = self.length

        if tinf.trans_table != 11:
            no_stop =  ((1-tinf.gc)*(1-tinf.gc)*tinf.gc)     / 8.0
            no_stop += ((1-tinf.gc)*(1-tinf.gc)*(1-tinf.gc)) / 8.0
            no_stop = 1 - no_stop
        else:
            no_stop =  ((1-tinf.gc)*(1-tinf.gc)*tinf.gc)     / 4.0
            no_stop += ((1-tinf.gc)*(1-tinf.gc)*(1-tinf.gc)) / 8.0
            no_stop = 1 - no_stop

        # Initial Pass: Score coding potential (start->stop)
        score[0] = score[1] = score[2] = 0.0
        for i in reversed(range(nn)):
            if self.nodes[i].strand == 1:
                phase = self.nodes[i].ndx%3
                if self.nodes[i].type == node_type.STOP:
                    last[phase] = self.nodes[i].ndx
                    score[phase] = 0.0
                else:
                    for j in range(last[phase] - 3, self.nodes[i].ndx - 1, -3):
                        score[phase] += tinf.gene_dc[_mer_ndx(seq.digits, seq.slen, j, 6, 1)];
                    self.nodes[i].cscore = score[phase]
                    last[phase] = self.nodes[i].ndx
        score[0] = score[1] = score[2] = 0.0
        for i in range(nn):
            if self.nodes[i].strand == -1:
                phase = self.nodes[i].ndx%3
                if self.nodes[i].type == node_type.STOP:
                    last[phase] = self.nodes[i].ndx
                    score[phase] = 0.0
                else:
                    for j in range(last[phase] + 3, self.nodes[i].ndx + 1, 3):
                        score[phase] += tinf.gene_dc[_mer_ndx(seq.digits, seq.slen, seq.slen-1-j, 6, -1)]
                    self.nodes[i].cscore = score[phase]
                    last[phase] = self.nodes[i].ndx

        # Second Pass: Penalize start nodes with ascending coding to their left
        score[0] = score[1] = score[2] = -10000.0
        for i in range(nn):
            if self.nodes[i].strand == 1:
                phase = self.nodes[i].ndx%3
                if self.nodes[i].type == node_type.STOP:
                    score[phase] = -10000.0
                elif self.nodes[i].cscore > score[phase]:
                    score[phase] = self.nodes[i].cscore
                else:
                    self.nodes[i].cscore -= score[phase] - self.nodes[i].cscore
        score[0] = score[1] = score[2] = -10000.0
        for i in reversed(range(nn)):
            if self.nodes[i].strand == -1:
                phase = self.nodes[i].ndx%3
                if self.nodes[i].type == node_type.STOP:
                    score[phase] = -10000.0
                elif self.nodes[i].cscore > score[phase]:
                    score[phase] = self.nodes[i].cscore
                else:
                    self.nodes[i].cscore -= (score[phase] - self.nodes[i].cscore);

        # Third Pass: Add length-based factor to the score
        # Penalize start nodes based on length to their left
        for i in range(nn):
            if self.nodes[i].strand == 1:
                phase = self.nodes[i].ndx%3
                if self.nodes[i].type == node_type.STOP:
                    score[phase] = -10000.0;
                else:
                    gsize = ((<double> self.nodes[i].stop_val - self.nodes[i].ndx)+3.0)/3.0
                    if gsize > 1000.0:
                        lfac = log((1-pow(no_stop, 1000.0))/pow(no_stop, 1000.0))
                        lfac -= log((1-pow(no_stop, 80))/pow(no_stop, 80))
                        lfac *= (gsize - 80) / 920.0
                    else:
                        lfac = log((1-pow(no_stop, gsize))/pow(no_stop, gsize))
                        lfac -= log((1-pow(no_stop, 80))/pow(no_stop, 80))
                    if lfac > score[phase]:
                        score[phase] = lfac
                    else:
                        lfac -= fmax(fmin(score[phase] - lfac, lfac), 0);
                    if lfac > 3.0 and self.nodes[i].cscore < 0.5*lfac:
                        self.nodes[i].cscore = 0.5*lfac
                    self.nodes[i].cscore += lfac
        for i in reversed(range(nn)):
            if self.nodes[i].strand == -1:
                phase = self.nodes[i].ndx%3;
                if self.nodes[i].type == node_type.STOP:
                    score[phase] = -10000.0;
                else:
                    gsize = ((<double> self.nodes[i].ndx - self.nodes[i].stop_val)+3.0)/3.0
                    if(gsize > 1000.0):
                        lfac = log((1-pow(no_stop, 1000.0))/pow(no_stop, 1000.0));
                        lfac -= log((1-pow(no_stop, 80))/pow(no_stop, 80));
                        lfac *= (gsize - 80) / 920.0;
                    else:
                        lfac = log((1-pow(no_stop, gsize))/pow(no_stop, gsize));
                        lfac -= log((1-pow(no_stop, 80))/pow(no_stop, 80));
                    if lfac > score[phase]:
                        score[phase] = lfac
                    else:
                        lfac -= fmax(fmin(score[phase] - lfac, lfac), 0);
                    if lfac > 3.0 and self.nodes[i].cscore < 0.5*lfac:
                        self.nodes[i].cscore = 0.5*lfac
                    self.nodes[i].cscore += lfac

        # Return 0 on success
        return 0

    cdef int _rbs_score(
        self,
        Sequence seq,
        const _training* tinf
    ) nogil except -1:
        cdef int i
        cdef int j
        cdef int cur_sc[2]
        cdef int slen      = seq.slen

        for i in range(<int> self.length):
            if self.nodes[i].type == node_type.STOP or self.nodes[i].edge:
                continue
            self.nodes[i].rbs[0] = self.nodes[i].rbs[1] = 0

            if self.nodes[i].strand == 1:
                for j in range(self.nodes[i].ndx - 20, self.nodes[i].ndx - 5):
                    if j < 0:
                        continue
                    cur_sc[0] = seq._shine_dalgarno_exact(j, self.nodes[i].ndx, tinf, strand=1)
                    cur_sc[1] = seq._shine_dalgarno_mm(j, self.nodes[i].ndx, tinf, strand=1)
                    if cur_sc[0] > self.nodes[i].rbs[0]:
                        self.nodes[i].rbs[0] = cur_sc[0]
                    if cur_sc[1] > self.nodes[i].rbs[1]:
                        self.nodes[i].rbs[1] = cur_sc[1]
            else:
                for j in range(slen - self.nodes[i].ndx - 21, slen - self.nodes[i].ndx - 6):
                    if j >= slen:
                        continue
                    cur_sc[0] = seq._shine_dalgarno_exact(j, slen-1-self.nodes[i].ndx, tinf, strand=-1)
                    cur_sc[1] = seq._shine_dalgarno_mm(j, slen-1-self.nodes[i].ndx, tinf, strand=-1)
                    if cur_sc[0] > self.nodes[i].rbs[0]:
                        self.nodes[i].rbs[0] = cur_sc[0]
                    if cur_sc[1] > self.nodes[i].rbs[1]:
                        self.nodes[i].rbs[1] = cur_sc[1]

        return 0

    cdef void _record_overlapping_starts(
        self,
        const _training* tinf,
        const int flag,
        const int max_sam_overlap
    ) nogil:
        cdef int    i
        cdef int    j
        cdef double sc
        cdef double max_sc
        cdef int    nn     = <int> self.length

        for i in range(nn):
            for j in range(3):
                self.nodes[i].star_ptr[j] = -1
            if self.nodes[i].type != node_type.STOP or self.nodes[i].edge == 1:
                continue
            if self.nodes[i].strand == 1:
                max_sc = -100
                for j in reversed(range(i+4)):
                    if j >= nn or self.nodes[j].ndx > self.nodes[i].ndx+2:
                        continue
                    if self.nodes[j].ndx + max_sam_overlap < self.nodes[i].ndx:
                        break
                    if self.nodes[j].strand == 1 and self.nodes[j].type != node_type.STOP:
                        if self.nodes[j].stop_val <= self.nodes[i].ndx:
                            continue
                        if flag == 0 and self.nodes[i].star_ptr[self.nodes[j].ndx%3] == -1:
                            self.nodes[i].star_ptr[self.nodes[j].ndx%3] = j
                        elif flag == 1:
                            sc = self.nodes[j].cscore + self.nodes[j].sscore + _intergenic_mod_same(&self.nodes[i], &self.nodes[j], tinf.st_wt)
                            if sc > max_sc:
                                self.nodes[i].star_ptr[self.nodes[j].ndx%3] = j
                                max_sc = sc
            else:
                max_sc = -100
                for j in range(i-3, nn):
                    if j < 0 or self.nodes[j].ndx < self.nodes[i].ndx-2:
                        continue
                    if self.nodes[j].ndx - max_sam_overlap > self.nodes[i].ndx:
                        break
                    if self.nodes[j].strand == -1 and self.nodes[j].type != node_type.STOP:
                        if self.nodes[j].stop_val >= self.nodes[i].ndx:
                            continue
                        if flag == 0 and self.nodes[i].star_ptr[self.nodes[j].ndx%3] == -1:
                            self.nodes[i].star_ptr[self.nodes[j].ndx%3] = j
                        elif flag == 1:
                            sc = self.nodes[j].cscore + self.nodes[j].sscore + _intergenic_mod_same(&self.nodes[j], &self.nodes[i], tinf.st_wt)
                            if sc > max_sc:
                                self.nodes[i].star_ptr[self.nodes[j].ndx%3] = j
                                max_sc = sc

    cdef int _score(
        self,
        Sequence seq,
        const _training* tinf,
        const bint closed,
        const bint is_meta,
    ) nogil except -1:

        cdef size_t i
        cdef size_t j
        cdef size_t orf_length
        cdef double negf
        cdef double posf
        cdef double rbs1
        cdef double rbs2
        cdef double sd_score
        cdef double edge_gene
        cdef double min_meta_len

        # Calculate raw coding potential for every start-stop pair
        self._calc_orf_gc(seq)
        self._raw_coding_score(seq, tinf)

        # Calculate raw RBS Scores for every start node.
        if tinf.uses_sd:
            self._rbs_score(seq, tinf)
        else:
            for i in range(self.length):
                if self.nodes[i].type == node_type.STOP or self.nodes[i].edge:
                    continue
                Node._find_best_upstream_motif(&self.nodes[i], seq, tinf, stage=2)

        # Score the start nodes
        for i in range(self.length):
            if self.nodes[i].type == node_type.STOP:
                continue

            # compute ORF length, we'll need it later several times
            if self.nodes[i].ndx > self.nodes[i].stop_val:
                orf_length = self.nodes[i].ndx - self.nodes[i].stop_val
            else:
                orf_length = self.nodes[i].stop_val - self.nodes[i].ndx

            # Does this gene run off the edge?
            edge_gene = 0
            if self.nodes[i].edge:
                edge_gene += 1
            if (
                    self.nodes[i].strand == 1 and not _is_stop(seq.digits, seq.slen, self.nodes[i].stop_val, tinf.trans_table, 1)
                or  self.nodes[i].strand == -1 and not _is_stop(seq.digits, seq.slen, seq.slen - 1 - self.nodes[i].stop_val, tinf.trans_table, -1)
            ):
                edge_gene += 1

            # Edge Nodes : stops with no starts, give a small bonus
            if self.nodes[i].edge:
                self.nodes[i].tscore = node.EDGE_BONUS*tinf.st_wt / edge_gene
                self.nodes[i].uscore = 0.0
                self.nodes[i].rscore = 0.0
            else:
                # Type Score
                self.nodes[i].tscore = tinf.type_wt[self.nodes[i].type] * tinf.st_wt

                # RBS Motif Score
                rbs1 = tinf.rbs_wt[self.nodes[i].rbs[0]];
                rbs2 = tinf.rbs_wt[self.nodes[i].rbs[1]];
                sd_score = fmax(rbs1, rbs2) * tinf.st_wt
                if tinf.uses_sd:
                    self.nodes[i].rscore = sd_score
                else:
                    self.nodes[i].rscore = tinf.st_wt * self.nodes[i].mot.score
                    if self.nodes[i].rscore < sd_score and tinf.no_mot > -0.5:
                        self.nodes[i].rscore = sd_score

                # Upstream Score
                Node._score_upstream_composition(&self.nodes[i], seq, tinf)

                # Penalize upstream score if choosing this start would stop the gene
                # from running off the edge
                if not closed and self.nodes[i].ndx <= 2 and self.nodes[i].strand == 1:
                    self.nodes[i].uscore += node.EDGE_UPS*tinf.st_wt
                elif not closed and self.nodes[i].ndx >= seq.slen - 3 and self.nodes[i].strand == -1:
                    self.nodes[i].uscore += node.EDGE_UPS*tinf.st_wt
                elif i < 500 and self.nodes[i].strand == 1:
                    for j in reversed(range(i)):
                        if self.nodes[j].edge and self.nodes[i].stop_val == self.nodes[j].stop_val:
                            self.nodes[i].uscore += node.EDGE_UPS*tinf.st_wt
                            break
                elif i + 500>= self.length and self.nodes[i].strand == -1:
                    for j in range(i+1, self.length):
                        if self.nodes[j].edge and self.nodes[i].stop_val == self.nodes[j].stop_val:
                            self.nodes[i].uscore += node.EDGE_UPS*tinf.st_wt
                            break

            # Convert starts at base 1 and slen to edge genes if closed = 0
            if (
                    not closed
                and not self.nodes[i].edge
                and ((self.nodes[i].ndx <= 2 and self.nodes[i].strand == 1) or (self.nodes[i].ndx >= seq.slen - 3 and self.nodes[i].strand == -1))
            ):
                edge_gene += 1
                self.nodes[i].edge = True
                self.nodes[i].tscore = 0.0
                self.nodes[i].uscore = node.EDGE_BONUS*tinf.st_wt / edge_gene
                self.nodes[i].rscore = 0.0

            # Penalize starts with no stop codon
            if not self.nodes[i].edge and edge_gene == 1:
                self.nodes[i].uscore -= 0.5*node.EDGE_BONUS*tinf.st_wt

            # Penalize non-edge genes < 250bp
            if edge_gene == 0 and orf_length < 250:
                negf = 250.0 / <float> orf_length
                posf = <float> orf_length / 250.0
                self.nodes[i].rscore *= negf if self.nodes[i].rscore < 0 else posf
                self.nodes[i].uscore *= negf if self.nodes[i].uscore < 0 else posf
                self.nodes[i].tscore *= negf if self.nodes[i].tscore < 0 else posf

            # Coding Penalization in Metagenomic Fragments:  Internal genes must
            # have a score of 5.0 and be >= 120bp.  High GC genes are also penalized.                                  */
            if (
                    is_meta
                and seq.slen < 3000
                and edge_gene == 0
                and (self.nodes[i].cscore < 5.0 or orf_length < 120)
            ):
                self.nodes[i].cscore -= node.META_PEN * fmax(0, (3000.0 - seq.slen) / 2700.0)

            # Base Start Score
            self.nodes[i].sscore = self.nodes[i].tscore + self.nodes[i].rscore + self.nodes[i].uscore

            # Penalize starts if coding is negative.  Larger penalty for edge genes,
            # since the start is offset by a smaller amount of coding than normal.
            if self.nodes[i].cscore < 0.0:
                if edge_gene > 0 and not self.nodes[i].edge:
                    if not is_meta or seq.slen > 1500:
                        self.nodes[i].sscore -= tinf.st_wt
                    else:
                        self.nodes[i].sscore -= 10.31 - 0.004*seq.slen
                elif is_meta and seq.slen < 3000 and self.nodes[i].edge:
                    min_meta_len = sqrt(<double> seq.slen)*5.0
                    if orf_length >= min_meta_len:
                        if self.nodes[i].cscore >= 0:
                            self.nodes[i].cscore = -1.0
                        self.nodes[i].sscore = 0.0
                        self.nodes[i].uscore = 0.0
                else:
                    self.nodes[i].sscore -= 0.5
            elif (
                    is_meta
                and self.nodes[i].cscore < 5.0
                and orf_length < 120
                and self.nodes[i].sscore < 0.0
            ):
                self.nodes[i].sscore -= tinf.st_wt

        # Return 0 on success
        return 0

    cdef int _sort(self) nogil except 1:
        """Sort all nodes in the vector by their index and strand.
        """
        qsort(self.nodes, self.length, sizeof(_node), compare_nodes)
        return 0

    cdef int _reset_scores(self) nogil except 1:
        node.reset_node_scores(self.nodes, self.length)
        return 0

    # --- Python interface ---------------------------------------------------

    cpdef Nodes copy(self):
        """copy(self)\n--

        Create a copy of the `Nodes` object.

        """
        cdef Nodes new = Nodes.__new__(Nodes)
        new.capacity = self.capacity
        new.length = self.length
        if self.capacity > 0:
            new._allocate(new.capacity)
            memcpy(new.nodes, self.nodes, new.length * sizeof(_node))
        return new

    def clear(self):
        """clear(self)\n--

        Remove all nodes from the node list.

        """
        with nogil:
            self._clear()

    def extract(
        self,
        Sequence sequence,
        *,
        bint closed=False,
        int min_gene=MIN_GENE,
        int min_edge_gene=MIN_EDGE_GENE,
        int translation_table=11,
    ):
        """extract(self, sequence, *, closed=False, min_gene=90, min_edge_gene=60, translation_table=11)\n--

        Extract nodes from the given sequence based on the training info.

        After calling this method, nodes won't be sorted; make sure to call
        `Nodes.sort` before using this further.

        Arguments:
            sequence (`~pyrodigal.Sequence`): The sequence to extract the
                nodes from.

        Keyword Arguments:
            closed (`bool`): Set to `True` to prevent proteins from running
                off edges when finding genes in a sequence.
            min_gene (`int`): The minimum gene length. Defaults to the value
                used in Prodigal.
            min_edge_gene (`int`): The minimum edge gene length. Defaults to
                the value used in Prodigal.
            translation_table (`int`): The translation table to use. Check the
                `Wikipedia <https://w.wiki/47wo>`_ page listing all genetic
                codes for the available values.

        Returns:
            `int`: The number of nodes added from the given sequence.

        Note:
            This function is adapted from the ``add_nodes`` function in
            the ``node.c`` file of the Prodigal source code.

        """
        cdef int nn
        with nogil:
            nn = self._extract(
                sequence,
                translation_table=translation_table,
                closed=closed,
                min_gene=min_gene,
                min_edge_gene=min_edge_gene
            )
        return nn

    def reset_scores(self):
        """reset_scores(self)\n--

        Reset node scores.

        """
        with nogil:
            self._reset_scores()

    def score(
        self,
        Sequence sequence,
        TrainingInfo training_info,
        *,
        bint closed=False,
        bint is_meta=False
    ):
        """score(self, sequence, training_info, *, closed=False, is_meta=False)\n--

        Score the start nodes currently stored.

        Note:
            This function is reimplemented from the ``score_nodes`` function of
            ``node.c`` from the Prodigal source, and already contains the patch
            from `hyattpd/Prodigal#88 <https://github.com/hyattpd/Prodigal/pull/88>`_.

        """
        with nogil:
            self._score(sequence, training_info.tinf, closed=closed, is_meta=is_meta)

    def sort(self):
        """sort(self)\n--

        Sort all nodes in the vector by their index and strand.

        """
        with nogil:
            self._sort()

# --- Genes ------------------------------------------------------------------

# NOTE: Use a custom structure to store the gene data instead of the one
#       declared in `gene.h` to save some memory; in Prodigal, gene structures
#       each allocated 1,000 bytes of string data for each gene. In Pyrodigal,
#       we build these strings on request through a property, so we don't have
#       to reserve extra memory anymore.
cdef struct _gene:
    int begin
    int end
    int start_ndx
    int stop_ndx

cdef class Gene:
    """A single raw gene found by Prodigal within a DNA sequence.

    Caution:
        The gene coordinates follows the conventions from Prodigal, not
        Python, so coordinates are 1-based, end-inclusive. To index the
        original sequence with a gene object, remember to switch back
        to zero-based coordinates: ``sequence[gene.begin-1:gene.end]``.

    .. versionadded:: 0.5.4

    """

    # --- Magic methods ------------------------------------------------------

    def __init__(self):
        raise TypeError("Cannot instantiate `Gene` objects directly")

    def __repr__(self):
        ty = type(self)
        return "<{}.{} begin={!r} end={!r} strand={:+} start_type={!r} rbs_motif={!r} rbs_spacer={!r}>".format(
            ty.__module__,
            ty.__name__,
            self.begin,
            self.end,
            self.strand,
            self.start_type,
            self.rbs_motif,
            self.rbs_spacer,
        )

    # --- Properties ---------------------------------------------------------

    @property
    def begin(self):
        """`int`: The coordinate at which the gene begins.
        """
        return self.gene.begin

    @property
    def end(self):
        """`int`: The coordinate at which the gene ends.
        """
        return self.gene.end

    @property
    def strand(self):
        """`int`: *-1* if the gene is on the reverse strand, *+1* otherwise.
        """
        return self.owner.nodes.nodes[self.gene.start_ndx].strand

    @property
    def partial_begin(self):
        """`bool`: Whether the gene overlaps with the start of the sequence.
        """
        if self.strand == 1:
            return self.owner.nodes.nodes[self.gene.start_ndx].edge == 1
        else:
            return self.owner.nodes.nodes[self.gene.stop_ndx].edge == 1

    @property
    def partial_end(self):
        """`bool`: Whether the gene overlaps with the end of the sequence.
        """
        if self.strand == 1:
            return self.owner.nodes.nodes[self.gene.stop_ndx].edge == 1
        else:
            return self.owner.nodes.nodes[self.gene.start_ndx].edge == 1

    @property
    def start_type(self):
        """`str`: The start codon of this gene.

        Can be one of ``ATG``, ``GTG`` or ``TTG``, or ``Edge`` if the
        `OrfFinder` has been initialized in open ends mode and the gene
        starts right at the beginning of the input sequence.

        """
        node = self.owner.nodes.nodes[self.gene.start_ndx]
        start_type = 3 if node.edge else node.type
        return _NODE_TYPE[start_type]

    @property
    def rbs_motif(self):
        """`str`, optional: The motif of the Ribosome Binding Site.

        Possible non-`None` values are ``GGA/GAG/AGG``, ``3Base/5BMM``,
        ``4Base/6BMM``, ``AGxAG``, ``GGxGG``, ``AGGAG(G)/GGAGG``, ``AGGA``,
        ``AGGA/GGAG/GAGG``, ``GGAG/GAGG``, ``AGGAG/GGAGG``, ``AGGAG``,
        ``GGAGG`` or ``AGGAGG``.

        """
        assert self.owner is not None
        assert self.owner.nodes is not None
        assert self.owner.nodes.nodes != NULL

        cdef char[10]   qt
        cdef _node*     node = &self.owner.nodes.nodes[self.gene.start_ndx]
        cdef _training* tinf = self.owner.training_info.tinf
        cdef double     rbs1 = tinf.rbs_wt[node.rbs[0]] * tinf.st_wt
        cdef double     rbs2 = tinf.rbs_wt[node.rbs[1]] * tinf.st_wt

        if tinf.uses_sd:
            return _RBS_MOTIF[node.rbs[0 if rbs1 > rbs2 else 1]]
        elif tinf.no_mot > -0.5 and rbs1 > rbs2 and rbs1 > node.mot.score * tinf.st_wt:
            return _RBS_MOTIF[node.rbs[0]]
        elif tinf.no_mot > -0.5 and rbs2 >= rbs1 and rbs2 > node.mot.score * tinf.st_wt:
            return _RBS_MOTIF[node.rbs[1]]
        elif node.mot.len == 0:
            return None
        else:
            sequence.mer_text(&qt[0], node.mot.len, node.mot.ndx)
            return qt.decode('ascii')

    @property
    def rbs_spacer(self):
        """`str`, optional: The number of bases between the RBS and the CDS.

        Possible non-`None` values are ``3-4bp``, ``5-10bp``, ``11-12bp`` or
        ``13-15bp``.

        """
        assert self.owner is not None
        assert self.owner.nodes is not None
        assert self.owner.nodes.nodes != NULL

        cdef _node*     node = &self.owner.nodes.nodes[self.gene.start_ndx]
        cdef _training* tinf = self.owner.training_info.tinf
        cdef double     rbs1 = tinf.rbs_wt[node.rbs[0]] * tinf.st_wt
        cdef double     rbs2 = tinf.rbs_wt[node.rbs[1]] * tinf.st_wt

        if tinf.uses_sd:
            return _RBS_SPACER[node.rbs[0 if rbs1 > rbs2 else 1]]
        elif tinf.no_mot > -0.5 and rbs1 > rbs2 and rbs1 > node.mot.score * tinf.st_wt:
            return _RBS_SPACER[node.rbs[0]]
        elif tinf.no_mot > -0.5 and rbs2 >= rbs1 and rbs2 > node.mot.score * tinf.st_wt:
            return _RBS_SPACER[node.rbs[1]]
        elif node.mot.len == 0:
            return None
        else:
            return f"{node.mot.spacer}bp"

    @property
    def gc_cont(self):
        """`float`: The GC content of the gene (between *0* and *1*).
        """
        return self.owner.nodes.nodes[self.gene.start_ndx].gc_cont

    @property
    def translation_table(self):
        """`int`: The translation table used to find the gene.
        """
        return self.owner.training_info.translation_table

    @property
    def cscore(self):
        """`float`: The coding score for the start node, based on 6-mer usage.

        .. versionadded:: 0.5.1

        """
        return self.owner.nodes.nodes[self.gene.start_ndx].cscore

    @property
    def rscore(self):
        """`float`: The score for the RBS motif.

        .. versionadded:: 0.5.1

        """
        return self.owner.nodes.nodes[self.gene.start_ndx].rscore

    @property
    def sscore(self):
        """`float`: The score for the strength of the start codon.

        .. versionadded:: 0.5.1

        """
        return self.owner.nodes.nodes[self.gene.start_ndx].sscore

    @property
    def tscore(self):
        """`float`: The score for the codon kind (``ATG``/``GTG``/``TTG``).

        .. versionadded:: 0.5.1

        """
        return self.owner.nodes.nodes[self.gene.start_ndx].tscore

    @property
    def uscore(self):
        """`float`: The score for the upstream regions.

        .. versionadded:: 0.5.1

        """
        return self.owner.nodes.nodes[self.gene.start_ndx].uscore

    @property
    def score(self):
        """`float`: The gene score, sum of the coding and start codon scores.

        .. versionadded:: 0.7.3

        """
        cdef _node* node = &self.owner.nodes.nodes[self.gene.start_ndx]
        return node.cscore + node.sscore

    @property
    def start_node(self):
        """`~pyrodigal.Node`: The start node at the beginning of this gene.
        """
        return self.owner.nodes[self.gene.start_ndx]

    @property
    def stop_node(self):
        """`~pyrodigal.Node`: The stop node at the end of this gene.
        """
        return self.owner.nodes[self.gene.stop_ndx]


    # --- Utils --------------------------------------------------------------

    cpdef str _gene_data(self, object sequence_id):
        cdef size_t node_index = <size_t> (self.gene - &self.owner.genes[0])
        return "ID={}_{};partial={}{};start_type={};rbs_motif={};rbs_spacer={};gc_cont={:.3f}".format(
            sequence_id,
            node_index + 1,
            int(self.partial_begin),
            int(self.partial_end),
            self.start_type,
            self.rbs_motif,
            self.rbs_spacer,
            self.owner.nodes.nodes[self.gene.start_ndx].gc_cont
        )

    cpdef str _score_data(self):
        return "conf={:.2f};score={:.2f};cscore={:.2f};sscore={:.2f};rscore={:.2f};uscore={:.2f};tscore={:.2f};".format(
            self.confidence(),
            self.score,
            self.cscore,
            self.sscore,
            self.rscore,
            self.uscore,
            self.tscore,
        )

    # --- Python interface ---------------------------------------------------

    cpdef double confidence(self):
        """confidence(self)\n--

        Estimate the confidence of the prediction.

        Returns:
            `float`: A confidence percentage (between *0* and *100*).

        """
        cdef int ndx = self.gene.start_ndx
        return gene.calculate_confidence(
            self.owner.nodes.nodes[ndx].cscore + self.owner.nodes.nodes[ndx].sscore,
            self.owner.training_info.tinf.st_wt
        )

    cpdef str sequence(self):
        """sequence(self)\n--

        Build the nucleotide sequence of this predicted gene.

        This function takes care of reverse-complementing the sequence
        if it is on the reverse strand.

        Note:
            Since Pyrodigal uses a generic symbol for unknown nucleotides,
            any unknown characters in the original sequence will be
            rendered with an ``N``.

        .. versionadded:: 0.5.4

        """
        cdef size_t   i
        cdef size_t   j
        cdef size_t   begin
        cdef size_t   end
        cdef size_t   length
        cdef Py_UCS4  nuc
        cdef _gene*   gene   = self.gene
        cdef int      slen   = self.owner.sequence.slen
        cdef int      strand = self.owner.nodes.nodes[gene.start_ndx].strand
        cdef uint8_t* digits   = self.owner.sequence.digits

        # compute the right length to hold the nucleotides
        length = (<size_t> gene.end) - (<size_t> gene.begin) + 1

        # compute the offsets in the sequence bitmap
        if strand == 1:
            begin = gene.begin - 1
            end = gene.end
        else:
            begin = slen - gene.end
            end = slen + 1 - gene.begin

        # NB(@althonos): For some reason, PyPy3.6 (v7.3.3) is not happy with
        #                the use of the PyUnicode API here, and will just not
        #                write any letter with PyUnicode_WRITE. The bug
        #                doesn't seem to affect `Gene.translate`, so
        #                I'm not sure what's going on, but in that case we
        #                can build an ASCII string and decode afterwards.
        IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
            cdef bytes dna
            cdef void* data
            # create an empty byte buffer that we can write to
            dna = PyBytes_FromStringAndSize(NULL, length)
            data = <void*> PyBytes_AsString(dna)
        ELSE:
            cdef unicode  dna
            cdef int      kind
            cdef void*    data
            # create an empty string that we can write to
            dna  = PyUnicode_New(length, 0x7F)
            kind = PyUnicode_KIND(dna)
            data = PyUnicode_DATA(dna)

        with nogil:
            for i, j in enumerate(range(begin, end)):
                if strand == 1:
                    nuc = _letters[digits[j]]
                else:
                    nuc = _letters[_complement[digits[slen - 1 - j]]]
                IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
                    (<char*> data)[i] = nuc
                ELSE:
                    PyUnicode_WRITE(kind, data, i, nuc)

        IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 7 and SYS_IMPLEMENTATION_NAME == "pypy":
            return dna.decode("ascii")
        ELSE:
            return dna

    cpdef str translate(
        self,
        object translation_table=None,
        char unknown_residue=b"X",
    ):
        """translate(self, translation_table=None, unknown_residue="X")\n--

        Translate the predicted gene into a protein sequence.

        Arguments:
            translation_table (`int`, optional): An alternative translation
                table to use to translate the gene. Use ``None`` (the
                default) to translate using the translation table this gene
                was found with.
            unknown_residue (`str`): A single character to use for residues
                translated from codons with unknown nucleotides.

        Returns:
            `str`: The proteins sequence as a string using the right
            translation table and the standard single letter alphabet for
            proteins.

        Raises:
            `ValueError`: when ``translation_table`` is not a valid
                genetic code number.

        """
        cdef size_t nucl_length
        cdef size_t prot_length
        cdef size_t i
        cdef size_t j
        cdef int    tt
        cdef object protein
        cdef int    kind
        cdef void*  data
        cdef size_t begin
        cdef size_t end
        cdef char   aa
        cdef _gene* gene        = self.gene
        cdef int    slen        = self.owner.sequence.slen
        cdef int    edge        = self.owner.nodes.nodes[gene.start_ndx].edge
        cdef int    strand      = self.owner.nodes.nodes[gene.start_ndx].strand

        # HACK: support changing the translation table (without allocating a
        #       new a training info structure) by manipulating where the
        #       table would be read from in the fields of the struct
        if translation_table is None:
            tt = self.owner.training_info.tinf.trans_table
        elif translation_table not in _TRANSLATION_TABLES:
            raise ValueError(f"{translation_table} is not a valid translation table index")
        else:
            tt = translation_table

        # compute the right length to hold the protein
        nucl_length = (<size_t> gene.end) - (<size_t> gene.begin) + 1
        prot_length = nucl_length//3
        # create an empty protein string that we can write to
        # with the appropriate functions
        protein = PyUnicode_New(prot_length, 0x7F)
        kind    = PyUnicode_KIND(protein)
        data    = PyUnicode_DATA(protein)

        # compute the offsets in the sequence
        if strand == 1:
            begin = gene.begin - 1
            end = gene.end - 1
        else:
            begin = slen - gene.end
            end = slen - gene.begin

        with nogil:
            for i, j in enumerate(range(begin, end, 3)):
                aa = self.owner.sequence._amino(
                    j,
                    tt,
                    strand=strand,
                    is_init=i==0 and not edge,
                    unknown_residue=unknown_residue
                )
                PyUnicode_WRITE(kind, data, i, aa)

        # return the string containing the protein sequence
        return protein

cdef class Genes:
    """A list of raw genes found by Prodigal in a single sequence.

    Attributes:
        sequence (`pyrodigal.Sequence`): The compressed input sequence for
            which the gene predictions were made.
        training_info (`pyrodigal.TrainingInfo`): A reference to the
            training info these predictions were obtained with.
        nodes (`pyrodigal.Nodes`): A collection of raw nodes found in the
            input sequence.
        meta (`bool`): Whether these genes have been found after a run
            in metagenomic mode, or in single mode.

    .. versionadded:: 0.5.4

    .. versionadded:: 2.0.0
        The ``meta`` attribute.

    """

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self.genes = NULL
        self.capacity = 0
        self.length = 0
        self.meta = False

    def __dealloc__(self):
        PyMem_Free(self.genes)

    def __bool__(self):
        return self.length > 0

    def __len__(self):
        return self.length

    def __getitem__(self, ssize_t index):
        cdef Gene gene
        if index < 0:
            index += <ssize_t> self.length
        if index >= <ssize_t> self.length or index < 0:
            raise IndexError("list index out of range")
        gene = Gene.__new__(Gene)
        gene.owner = self
        gene.gene = &self.genes[index]
        return gene

    cpdef size_t __sizeof__(self):
        return self.capacity * sizeof(_gene) + sizeof(self)

    cpdef dict __getstate__(self):
        cdef size_t         i
        cdef dict           state
        cdef MetagenomicBin mb    = self.training_info.metagenomic_bin

        state = {
            "_num_seq": self._num_seq,
            "meta": self.meta,
            "nodes": self.nodes,
            "sequence": self.sequence,
            "genes": [
                {
                    "begin": self.genes[i].begin,
                    "end": self.genes[i].end,
                    "start_ndx": self.genes[i].start_ndx,
                    "stop_ndx": self.genes[i].stop_ndx,
                }
                for i in range(self.length)
            ]
        }
        if mb is None:
            state["training_info"] =  self.training_info
        else:
            state["metagenomic_bin"] = mb.index

        return state

    cpdef object __setstate__(self, dict state):
        cdef size_t i
        cdef dict   gene
        cdef list   genes = state["genes"]

        # realloc to the exact number of genes
        self.length = self.capacity = len(genes)
        if self.capacity > 0:
            self.genes = <_gene*> PyMem_Realloc(self.genes, self.capacity * sizeof(_gene))
            if self.genes == NULL:
                raise MemoryError("Failed to reallocate gene array")
        else:
            PyMem_Free(self.genes)
            self.genes = NULL

        # copy attributes
        self._num_seq = state["_num_seq"]
        self.meta = state["meta"]
        self.nodes = state["nodes"]
        self.sequence = state["sequence"]

        # copy gene data from the state dictionary
        for i, gene in enumerate(genes):
            self.genes[i].begin = gene["begin"]
            self.genes[i].end = gene["end"]
            self.genes[i].start_ndx = gene["start_ndx"]
            self.genes[i].stop_ndx = gene["stop_ndx"]

        # recover training info
        if "metagenomic_bin" in state:
            self.training_info = METAGENOMIC_BINS[state["metagenomic_bin"]].training_info
        else:
            self.training_info = state["training_info"]

    # --- C interface --------------------------------------------------------

    cdef int _allocate(self, size_t capacity) except 1:
        # record new capacity
        cdef size_t old_capacity = self.capacity
        self.capacity = capacity
        # allocate node array
        self.genes = <_gene*> PyMem_Realloc(self.genes, self.capacity * sizeof(_gene))
        if self.genes == NULL:
            raise MemoryError("Failed to reallocate gene array")
        # clean newly-allocated memory
        if self.capacity > old_capacity:
            memset(&self.genes[old_capacity], 0, (self.capacity - old_capacity) * sizeof(_gene))
        return 0

    cdef inline _gene* _add_gene(
        self,
        const int begin,
        const int end,
        const int start_ndx,
        const int stop_ndx,
    ) nogil except NULL:
        """Add a single gene to the vector, and return a pointer to that gene.
        """
        # reallocate if needed
        if self.length >= self.capacity:
            with gil:
                self._allocate(MIN_GENES_ALLOC if self.capacity == 0 else new_capacity(self.capacity))
        # record gene data
        self.length += 1
        cdef _gene* gene = &self.genes[self.length - 1]
        gene.begin = begin
        gene.end = end
        gene.start_ndx = start_ndx
        gene.stop_ndx = stop_ndx
        return gene

    cdef int _clear(self) nogil except 1:
        """Remove all genes from the vector.
        """
        cdef size_t old_length
        old_length, self.length = self.length, 0
        memset(self.genes, 0, old_length * sizeof(_gene))

    cdef int _extract(self, Nodes nodes, int ipath) nogil except -1:
        """Extract genes from the dynamic programming nodes.
        """
        cdef int  path      = ipath
        cdef int  ng        = 0
        cdef int  begin     = 0
        cdef int  end       = 0
        cdef int  start_ndx = 0
        cdef int  stop_ndx  = 0

        if path == -1:
            return 0
        while nodes.nodes[path].traceb != -1:
            path = nodes.nodes[path].traceb
        while path != -1:
            if nodes.nodes[path].elim == 1:
                pass
            elif nodes.nodes[path].strand == 1:
                if nodes.nodes[path].type != node_type.STOP:
                    begin = nodes.nodes[path].ndx + 1
                    start_ndx = path
                else:
                    end = nodes.nodes[path].ndx + 3
                    stop_ndx = path
                    self._add_gene(begin, end, start_ndx, stop_ndx)
                    ng += 1
            else:
                if nodes.nodes[path].type != node_type.STOP:
                    end = nodes.nodes[path].ndx + 1
                    start_ndx = path
                    self._add_gene(begin, end, start_ndx, stop_ndx)
                    ng += 1
                else:
                    begin = nodes.nodes[path].ndx - 1
                    stop_ndx = path
            path = nodes.nodes[path].tracef

        return ng

    cdef void _tweak_final_starts(
        self,
        Nodes nodes,
        const _training* tinf,
        const int max_sam_overlap,
    ) nogil:

        cdef int    i
        cdef int    j
        cdef int    ndx
        cdef int    mndx
        cdef int    maxndx[2]
        cdef double sc
        cdef double igm
        cdef double tigm
        cdef double maxsc[2]
        cdef double maxigm[2]
        cdef int    nn        = <int> nodes.length
        cdef int    ng        = <int> self.length

        for i in range(ng):

            ndx = self.genes[i].start_ndx
            sc = nodes.nodes[ndx].sscore + nodes.nodes[ndx].cscore
            igm = 0.0

            if i > 0 and nodes.nodes[ndx].strand == 1 and nodes.nodes[self.genes[i-1].start_ndx].strand == 1:
                igm = _intergenic_mod_same(&nodes.nodes[self.genes[i-1].stop_ndx], &nodes.nodes[ndx], tinf.st_wt)
            if i > 0 and nodes.nodes[ndx].strand == 1 and nodes.nodes[self.genes[i-1].start_ndx].strand == -1:
                igm = _intergenic_mod_diff(&nodes.nodes[self.genes[i-1].start_ndx], &nodes.nodes[ndx], tinf.st_wt)
            if i < ng-1 and nodes.nodes[ndx].strand == -1 and nodes.nodes[self.genes[i+1].start_ndx].strand == 1:
                igm = _intergenic_mod_diff(&nodes.nodes[ndx], &nodes.nodes[self.genes[i+1].start_ndx], tinf.st_wt)
            if i < ng-1 and nodes.nodes[ndx].strand == -1 and nodes.nodes[self.genes[i+1].start_ndx].strand == -1:
                igm = _intergenic_mod_same(&nodes.nodes[ndx], &nodes.nodes[self.genes[i+1].stop_ndx], tinf.st_wt)

            # Search upstream and downstream for the #2 and #3 scoring starts
            maxndx[0] = maxndx[1] = -1
            maxsc[0] = maxsc[1] = 0
            maxigm[0] = maxigm[1] = 0
            for j in range(ndx-100, ndx+100):
                if j < 0 or j >= nn or j == ndx:
                    continue
                if nodes.nodes[j].type == node_type.STOP or nodes.nodes[j].stop_val != nodes.nodes[ndx].stop_val:
                    continue

                tigm = 0.0
                if i > 0 and nodes.nodes[j].strand == 1 and nodes.nodes[self.genes[i-1].start_ndx].strand == 1:
                    if nodes.nodes[self.genes[i-1].stop_ndx].ndx - nodes.nodes[j].ndx > max_sam_overlap:
                        continue
                    tigm = _intergenic_mod_same(&nodes.nodes[self.genes[i-1].stop_ndx], &nodes.nodes[j], tinf.st_wt)
                if i > 0 and nodes.nodes[j].strand == 1 and nodes.nodes[self.genes[i-1].start_ndx].strand == -1:
                    if nodes.nodes[self.genes[i-1].start_ndx].ndx - nodes.nodes[j].ndx >= 0:
                        continue
                    tigm = _intergenic_mod_diff(&nodes.nodes[self.genes[i-1].start_ndx], &nodes.nodes[j], tinf.st_wt)
                if i < ng-1 and nodes.nodes[j].strand == -1 and nodes.nodes[self.genes[i+1].start_ndx].strand == 1:
                    if nodes.nodes[j].ndx - nodes.nodes[self.genes[i+1].start_ndx].ndx >= 0:
                        continue
                    tigm = _intergenic_mod_diff(&nodes.nodes[j], &nodes.nodes[self.genes[i+1].start_ndx], tinf.st_wt);
                if i < ng-1 and nodes.nodes[j].strand == -1 and nodes.nodes[self.genes[i+1].start_ndx].strand == -1:
                    if nodes.nodes[j].ndx - nodes.nodes[self.genes[i+1].stop_ndx].ndx > max_sam_overlap:
                        continue
                    tigm = _intergenic_mod_same(&nodes.nodes[j], &nodes.nodes[self.genes[i+1].stop_ndx], tinf.st_wt)

                if maxndx[0] == -1:
                    maxndx[0] = j
                    maxsc[0] = nodes.nodes[j].cscore + nodes.nodes[j].sscore
                    maxigm[0] = tigm
                elif nodes.nodes[j].cscore + nodes.nodes[j].sscore + tigm > maxsc[0]:
                    maxndx[1] = maxndx[0]
                    maxsc[1] = maxsc[0]
                    maxigm[1] = maxigm[0]
                    maxndx[0] = j
                    maxsc[0] = nodes.nodes[j].cscore + nodes.nodes[j].sscore
                    maxigm[0] = tigm
                elif maxndx[1] == -1 or nodes.nodes[j].cscore + nodes.nodes[j].sscore + tigm > maxsc[1]:
                    maxndx[1] = j
                    maxsc[1] = nodes.nodes[j].cscore + nodes.nodes[j].sscore
                    maxigm[1] = tigm

            # Change the start if it's a TTG with better coding/RBS/upstream score
            # Also change the start if it's <=15bp but has better coding/RBS
            for j in range(2):
                mndx = maxndx[j]
                if mndx == -1:
                    continue;

                # Start of less common type but with better coding, rbs, and
                # upstream.  Must be 18 or more bases away from original.
                if (
                        nodes.nodes[mndx].tscore < nodes.nodes[ndx].tscore
                    and maxsc[j]-nodes.nodes[mndx].tscore >= sc-nodes.nodes[ndx].tscore+tinf.st_wt
                    and nodes.nodes[mndx].rscore > nodes.nodes[ndx].rscore
                    and nodes.nodes[mndx].uscore > nodes.nodes[ndx].uscore
                    and nodes.nodes[mndx].cscore > nodes.nodes[ndx].cscore
                    and abs(nodes.nodes[mndx].ndx-nodes.nodes[ndx].ndx) > 15
                ):
                    maxsc[j] += nodes.nodes[ndx].tscore - nodes.nodes[mndx].tscore

                # Close starts.  Ignore coding and see if start has better rbs
                # and type.
                elif(
                      abs(nodes.nodes[mndx].ndx-nodes.nodes[ndx].ndx) <= 15
                  and nodes.nodes[mndx].rscore+ nodes.nodes[mndx].tscore > nodes.nodes[ndx].rscore+nodes.nodes[ndx].tscore
                  and nodes.nodes[ndx].edge == 0
                  and nodes.nodes[mndx].edge == 0
                ):
                  if nodes.nodes[ndx].cscore > nodes.nodes[mndx].cscore:
                      maxsc[j] += nodes.nodes[ndx].cscore - nodes.nodes[mndx].cscore
                  if nodes.nodes[ndx].uscore > nodes.nodes[mndx].uscore:
                      maxsc[j] += nodes.nodes[ndx].uscore - nodes.nodes[mndx].uscore
                  if igm > maxigm[j]:
                      maxsc[j] += igm - maxigm[j]

                else:
                    maxsc[j] = -1000.0

            # Change the gene coordinates to the new maximum.
            mndx = -1;
            for j in range(2):
                if maxndx[j] == -1:
                    continue
                if mndx == -1 and maxsc[j] + maxigm[j] > sc + igm:
                    mndx = j
                elif mndx >= 0 and maxsc[j] + maxigm[j] > maxsc[mndx] + maxigm[mndx]:
                    mndx = j
            if mndx != -1 and nodes.nodes[maxndx[mndx]].strand == 1:
                self.genes[i].start_ndx = maxndx[mndx]
                self.genes[i].begin = nodes.nodes[maxndx[mndx]].ndx+1
            elif mndx != -1 and nodes.nodes[maxndx[mndx]].strand == -1:
                self.genes[i].start_ndx = maxndx[mndx]
                self.genes[i].end = nodes.nodes[maxndx[mndx]].ndx+1

    # --- Python interface ---------------------------------------------------

    cpdef ssize_t write_gff(self, object file, str sequence_id, bint header=True) except -1:
        """write_gff(self, file, sequence_id, header=True)\n--

        Write the genes to ``file`` in General Feature Format.

        Arguments:
            file (`io.TextIOBase`): A file open in text mode where to write
                the features.
            sequence_id (`str`): The identifier of the sequence these
                genes were extracted from. Used in the first column of the
                GFF-formated output.
            header (`bool`): `True` to write a GFF header line,
                `False` otherwise.

        Returns:
            `int`: The number of bytes written to the file.

        .. versionchanged:: 2.0.0
            Replaced optional``prefix`` argument with ``sequence_id``.

        """
        cdef Gene           gene
        cdef int            i
        cdef ssize_t        n    = 0
        cdef MetagenomicBin mb   = self.training_info.metagenomic_bin
        cdef str            run  = "Metagenomic" if self.meta else "Single"
        cdef str            desc = "Ab initio" if mb is None else mb.description

        if header:
            file.write("##gff-version  3\n")
        file.write(
            f"# Sequence Data: "
            f"seqnum={self._num_seq};"
            f"seqlen={len(self.sequence)};"
            f'seqhdr="{sequence_id}"\n'
        )
        file.write(
            f"# Model Data: "
            f"version=pyrodigal.v{__version__};"
            f"run_type={run};"
            f'model="{desc}";'
            f"gc_cont={self.training_info.gc*100:.2f};"
            f"transl_table={self.training_info.translation_table};"
            f"uses_sd={int(self.training_info.uses_sd)}\n"
        )

        for i, gene in enumerate(self):
            n += file.write(sequence_id)
            n += file.write("\t")
            n += file.write("pyrodigal_v")
            n += file.write(__version__)
            n += file.write("\t")
            n += file.write("CDS")
            n += file.write("\t")
            n += file.write(str(gene.begin))
            n += file.write("\t")
            n += file.write(str(gene.end))
            n += file.write("\t")
            n += file.write("{:.1f}".format(gene.sscore + gene.cscore))
            n += file.write("\t")
            n += file.write("+" if gene.strand > 0 else "-")
            n += file.write("\t")
            n += file.write("0")
            n += file.write("\t")
            n += file.write(gene._gene_data(sequence_id))
            n += file.write(";")
            n += file.write(gene._score_data())
            n += file.write("\n")

        return n

    cpdef ssize_t write_genes(self, object file, str sequence_id, object width=70) except -1:
        """write_genes(self, file, sequence_id, width=70)\n--

        Write nucleotide sequences of genes to ``file`` in FASTA format.

        Arguments:
            file (`io.TextIOBase`): A file open in text mode where to write
                the nucleotide sequences.
            sequence_id (`str`): The identifier of the sequence these
                genes were extracted from.
            width (`int`): The width to use to wrap sequence lines. Prodigal
                uses 70 for nucleotide sequences.

        Returns:
            `int`: The number of bytes written to the file.

        .. versionchanged:: 2.0.0
            Replaced optional``prefix`` argument with ``sequence_id``.

        """
        cdef Gene    gene
        cdef int     i
        cdef ssize_t n    = 0

        for i, gene in enumerate(self):
            n += file.write(">")
            n += file.write(sequence_id)
            n += file.write("_")
            n += file.write(str(i+1))
            n += file.write(" # ")
            n += file.write(str(gene.begin))
            n += file.write(" # ")
            n += file.write(str(gene.end))
            n += file.write(" # ")
            n += file.write(str(gene.strand))
            n += file.write(" # ")
            n += file.write(gene._gene_data(self._num_seq))
            n += file.write("\n")
            for line in textwrap.wrap(gene.sequence(), width=width):
                n += file.write(line)
                n += file.write("\n")

        return n

    cpdef ssize_t write_translations(self, object file, str sequence_id, object width=60, object translation_table=None) except -1:
        """write_translations(self, file, sequence_id, width=60, translation_table=None)\n--

        Write protein sequences of genes to ``file`` in FASTA format.

        Arguments:
            file (`io.TextIOBase`): A file open in text mode where to write
                the protein sequences.
            sequence_id (`str`): The identifier of the sequence these
                genes were extracted from.
            width (`int`): The width to use to wrap sequence lines. Prodigal
                uses 60 for protein sequences.
            translation_table (`int`, optional): A different translation to
                use to translation the genes. If `None` given, use the one
                from the training info.

        Returns:
            `int`: The number of bytes written to the file.

        .. versionchanged:: 2.0.0
            Replaced optional``prefix`` argument with ``sequence_id``.

        """
        cdef Gene    gene
        cdef int     i
        cdef ssize_t n    = 0

        if translation_table is not None and translation_table not in _TRANSLATION_TABLES:
            raise ValueError(f"{translation_table} is not a valid translation table index")

        for i, gene in enumerate(self):
            n += file.write(">")
            n += file.write(sequence_id)
            n += file.write("_")
            n += file.write(str(i+1))
            n += file.write(" # ")
            n += file.write(str(gene.begin))
            n += file.write(" # ")
            n += file.write(str(gene.end))
            n += file.write(" # ")
            n += file.write(str(gene.strand))
            n += file.write(" # ")
            n += file.write(gene._gene_data(self._num_seq))
            n += file.write("\n")
            for line in textwrap.wrap(gene.translate(translation_table), width=width):
                n += file.write(line)
                n += file.write("\n")

        return n

    cpdef ssize_t write_scores(self, object file, str sequence_id, bint header=True) except -1:
        """write_scores(self, file, sequence_id, header=True)\n--

        Write the start scores to ``file`` in tabular format.

        Arguments:
            file (`io.TextIOBase`): A file open in text mode where to write
                the features.
            sequence_id (`str`): The identifier of the sequence these
                genes were extracted from.
            header (`bool`): `True` to write a header line, `False` otherwise.

        Returns:
            `int`: The number of bytes written to the file.

        .. versionadded:: 0.7.0

        .. versionadded:: 2.0.0
            The ``sequence_id`` argument.

        """
        cdef size_t     i
        cdef int        rbs_index
        cdef _node*     node
        cdef int        st_type
        cdef ssize_t    n           = 0
        cdef int        prev_stop   = -1
        cdef int        prev_strand = 0
        cdef _training* tinf        = self.training_info.tinf

        cdef char      qt[10]
        cdef double    rbs1
        cdef double    rbs2

        try:
            # Sort and groupd nodes by STOP codon position
            qsort(self.nodes.nodes, self.nodes.length, sizeof(_node), stopcmp_nodes)
            # Write headers if requested
            if header:
                # FIXME: missing some header data
                # Sequence Data: seqnum=1;seqlen=20000;seqhdr="KK037166.1 Kutzneria sp. 744 genomic scaffold supercont1.1, whole genome shotgun sequence"
                # Run Data: version=Prodigal.v2.6.3;run_type=Single;model="Ab initio";gc_cont=66.03;transl_table=11;uses_sd=0
                n += file.write(f'# Sequence Data: seqnum={self._num_seq};seqlen={len(self.sequence)};seqhdr="{sequence_id}"\n')
                n += file.write(f"# Run Data: version=pyrodigal.v{__version__};gc_cont={tinf.gc*100:.2f};transl_table={tinf.trans_table};uses_sd={tinf.uses_sd}\n")
                # write column names
                n += file.write(
                    "Beg\t" "End\t" "Std\t" "Total\t" "CodPot\t" "StrtSc\t"
                    "Codon\t" "RBSMot\t" "Spacer\t" "RBSScr\t" "UpsScr\t"
                    "TypeScr\t" "GCCont\n"
                )
            # Write a line for each start codon, grouped by STOP codon
            for i in range(self.nodes.length):
                node = &self.nodes.nodes[i]
                if node.type == node_type.STOP:
                    continue

                st_type = node_type.STOP if node.edge else node.type
                if node.stop_val != prev_stop or node.strand != prev_strand:
                    prev_stop = node.stop_val
                    prev_strand = node.strand
                    n += file.write("\n")

                if node.strand == 1:
                    n += file.write(f"{node.ndx + 1:d}\t")
                    n += file.write(f"{node.stop_val+3:d}\t")
                    n += file.write("+\t")
                else:
                    n += file.write(f"{node.stop_val - 1:d}\t")
                    n += file.write(f"{node.ndx + 1:d}\t")
                    n += file.write("-\t")

                n += file.write(f"{node.cscore + node.sscore:.2f}\t")
                n += file.write(f"{node.cscore:.2f}\t")
                n += file.write(f"{node.sscore:.2f}\t")
                n += file.write(f"{_NODE_TYPE[st_type]}\t")

                rbs1 = tinf.rbs_wt[node.rbs[0]] * tinf.st_wt
                rbs2 = tinf.rbs_wt[node.rbs[1]] * tinf.st_wt
                if tinf.uses_sd:
                    rbs_index = 0 if rbs1 > rbs2 else 1
                    n += file.write(f"{_RBS_MOTIF[node.rbs[rbs_index]]}\t")
                    n += file.write(f"{_RBS_SPACER[node.rbs[rbs_index]]}\t")
                    n += file.write(f"{node.rscore:.2f}\t")
                else:
                    if tinf.no_mot > -0.5 and rbs1 > rbs2 and rbs1 > node.mot.score * tinf.st_wt:
                        n += file.write(f"{_RBS_MOTIF[node.rbs[0]]}\t")
                        n += file.write(f"{_RBS_SPACER[node.rbs[0]]}\t")
                        n += file.write(f"{node.rscore:.2f}\t")
                    elif tinf.no_mot > -0.5 and rbs2 >= rbs1 and rbs2 > node.mot.score * tinf.st_wt:
                        n += file.write(f"{_RBS_MOTIF[node.rbs[1]]}\t")
                        n += file.write(f"{_RBS_SPACER[node.rbs[1]]}\t")
                        n += file.write(f"{node.rscore:.2f}\t")
                    else:
                        if node.mot.len == 0:
                            n += file.write(f"None\tNone\t{node.rscore:.2f}\t")
                        else:
                            sequence.mer_text(&qt[0], node.mot.len, node.mot.ndx)
                            n += file.write(f"{qt.decode('ascii')}\t{node.mot.spacer:d}bp\t{node.rscore:.2f}\t")

                n += file.write(f"{node.uscore:.2f}\t")
                n += file.write(f"{node.tscore:.2f}\t")
                n += file.write(f"{node.gc_cont:.3f}\n")
            # Write final line and return number of bytes written
            n += file.write("\n")
            return n
        finally:
            # Revert back original node order
            qsort(self.nodes.nodes, self.nodes.length, sizeof(_node), compare_nodes)


# --- Training Info ----------------------------------------------------------

cdef class TrainingInfo:
    """A collection of parameters obtained after training.

    .. versionadded:: 0.5.0

    """

    # --- Class methods ----------------------------------------------------

    @classmethod
    def load(cls, fp):
        """load(cls, fp)\n--

        Load a training info from a file-like handle.

        Arguments:
            fp (file-like object): An file-like handle opened in *binary*
                mode, from which to read the training info.

        Returns:
            `~pyrodigal.TrainingInfo`: The deserialized training info.

        Danger:
            This method is not safe to use across different machines. The
            internal binary structure will be loaded as-is, and because the
            C types can change in size and representation between CPUs and
            OS, the deserialized data may be invalid. This method is only
            provided to load a training info file created by the Prodigal
            binary. For a safe way of sharing and loading a `TrainingInfo`,
            use the `pickle` module.

        Raises:
            `EOFError`: When less bytes than expected could be read from
                the source file handle.

        .. versionadded:: 0.6.4

        """
        cdef ssize_t      n
        cdef object       mem
        cdef char[:]      contents
        cdef TrainingInfo tinf     = cls(50.0)

        if hasattr(fp, "readinto"):
            mem = PyMemoryView_FromMemory(<char*> tinf.tinf, sizeof(_training), MVIEW_WRITE)
            n = fp.readinto(mem)
            if n != sizeof(_training):
                raise EOFError(f"Expected {sizeof(_training)} bytes, only read {n}")
        else:
            contents = fp.read(sizeof(_training))
            if contents.shape[0] != sizeof(_training):
                raise EOFError(f"Expected {sizeof(_training)} bytes, only read {len(contents)}")
            memcpy(&tinf.tinf, &contents[0], sizeof(_training))

        return tinf

    # --- Magic methods ----------------------------------------------------

    def __cinit__(self):
        self.owned = True
        self.meta_index = -1
        self.tinf = NULL

    def __init__(self, double gc, double start_weight=4.35, int translation_table=11):
        if self.tinf != NULL:
            raise RuntimeError("TrainingInfo.__init__ called more than once")
        # reallocate the training info memory, if needed
        self.owned = True
        self.meta_index = -1
        self.tinf = <_training*> PyMem_Malloc(sizeof(_training))
        if self.tinf == NULL:
            raise MemoryError("Failed to allocate training info")
        # clear memory
        memset(self.tinf, 0, sizeof(_training))
        # set the variables
        self.tinf.gc = gc
        self.tinf.st_wt = start_weight
        self.tinf.trans_table = translation_table

    def __dealloc__(self):
        if self.owned:
            PyMem_Free(self.tinf)

    def __repr__(self):
        ty = type(self)
        return "<{}.{} gc={!r} start_weight={!r} translation_table={!r} uses_sd={!r}>".format(
            ty.__module__,
            ty.__name__,
            self.gc,
            self.start_weight,
            self.translation_table,
            self.uses_sd,
        )

    cpdef size_t __sizeof__(self):
        return sizeof(_training) + sizeof(self)

    cpdef dict __getstate__(self):
        """__getstate__(self)\n--
        """
        assert self.tinf != NULL
        cdef int i
        cdef int j
        cdef int k
        return {
            "meta_index": self.meta_index,
            "gc": self.tinf.gc,
            "translation_table": self.tinf.trans_table,
            "start_weight": self.tinf.st_wt,
            "bias": self.bias,
            "type_weights": self.type_weights,
            "uses_sd": self.uses_sd,
            "rbs_wt": [
                self.tinf.rbs_wt[i] for i in range(28)
            ],
            "ups_comp": [
                [self.tinf.ups_comp[i][j] for j in range(4)]
                for i in range(32)
            ],
            "mot_wt": [
                [
                    [self.tinf.mot_wt[i][j][k] for k in range(4096)]
                    for j in range(4)
                ]
                for i in range(4)
            ],
            "no_mot": self.tinf.no_mot,
            "gene_dc": [
                self.tinf.gene_dc[i] for i in range(4096)
            ]
        }

    cpdef object __setstate__(self, dict state):
        """__setstate__(self, state)\n--
        """
        cdef int i
        cdef int j
        cdef int k
        # allocate memory if possible / needed
        self._on_modification()
        if self.tinf == NULL:
            self.__init__(state["gc"])
        # copy data
        self.meta_index = state["meta_index"]
        self.tinf.gc = state["gc"]
        self.tinf.trans_table = state["translation_table"]
        self.tinf.st_wt = state["start_weight"]
        self.tinf.bias = state["bias"]
        self.tinf.type_wt = state["type_weights"]
        self.tinf.uses_sd = state["uses_sd"]
        self.tinf.no_mot = state["no_mot"]
        self.tinf.rbs_wt = state["rbs_wt"]
        self.tinf.ups_comp = state["ups_comp"]
        self.tinf.mot_wt = state["mot_wt"]
        self.tinf.gene_dc = state["gene_dc"]

    # --- Properties -------------------------------------------------------

    @property
    def metagenomic_bin(self):
        """`MetagenomicBin` or `None`: The metagenomic bin of this model.

        .. versionadded:: 2.0.0

        """
        if self.meta_index == -1:
            return None
        return METAGENOMIC_BINS[self.meta_index]

    @property
    def translation_table(self):
        """`int`: The translation table used during training.
        """
        assert self.tinf != NULL
        return self.tinf.trans_table

    @translation_table.setter
    def translation_table(self, int table):
        assert self.tinf != NULL
        if table not in _TRANSLATION_TABLES:
            raise ValueError(f"{table} is not a valid translation table index")
        self._on_modification()
        self.raw.trans_table = table

    @property
    def gc(self):
        """`float`: The GC content of the training sequence, as a fraction.
        """
        assert self.tinf != NULL
        return self.tinf.gc

    @gc.setter
    def gc(self, double gc):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.gc = gc

    @property
    def bias(self):
        """`tuple` of `float`: The GC frame bias for each of the 3 positions.
        """
        assert self.tinf != NULL
        return tuple(self.tinf.bias)

    @bias.setter
    def bias(self, object bias):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.bias = bias

    @property
    def type_weights(self):
        """`tuple` of `float`: The weights for ``ATG``, ``GTG`` and ``TTG``.
        """
        assert self.tinf != NULL
        return tuple(self.tinf.type_wt)

    @type_weights.setter
    def type_weights(self, object type_weights):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.type_wt = type_weights

    @property
    def uses_sd(self):
        """`bool`: `True` if the sequence uses a Shine/Dalgarno motif.
        """
        assert self.tinf != NULL
        return self.tinf.uses_sd

    @uses_sd.setter
    def uses_sd(self, bint uses_sd):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.uses_sd = uses_sd

    @property
    def start_weight(self):
        """`float`: The start score weight to use for the training sequence.
        """
        assert self.tinf != NULL
        return self.tinf.st_wt

    @start_weight.setter
    def start_weight(self, double st_wt):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.st_wt = st_wt

    @property
    def rbs_weights(self):
        """`tuple` of `float`: The weights for RBS scores.

        .. versionadded:: 2.0.0

        """
        assert self.tinf != NULL
        return tuple(self.tinf.rbs_wt)

    @rbs_weights.setter
    def rbs_weights(self, object rbs_weights):
        assert self.tinf != NULL
        self._on_modification()
        self.tinf.rbs_wt = rbs_weights

    @property
    def upstream_compositions(self):
        assert self.tinf != NULL
        return [
            tuple(self.tinf.ups_comp[i][j] for j in range(4))
            for i in range(32)
        ]

    @property
    def motif_weights(self):
        assert self.tinf != NULL
        return [
            [
                [ self.tinf.mot_wt[i][j][k] for k in range(4096) ]
                for j in range(4)
            ]
            for i in range(4)
        ]

    # --- C interface --------------------------------------------------------

    cdef void _on_modification(self) nogil except *:
        """Raise an error when attempting to modify a shared `TrainingInfo`.
        """
        if not self.owned:
            raise RuntimeError("Cannot modify a metagenomic `TrainingInfo` instance")

    @staticmethod
    cdef void _update_motif_counts(double mcnt[4][4][4096], double *zero, Sequence seq, _node* nod, int stage) nogil:
        cdef int     i
        cdef int     j
        cdef int     k
        cdef int     mer
        cdef int     start
        cdef int     spacendx
        cdef _motif* mot      = &nod.mot

        if nod.type == node_type.STOP or nod.edge == 1:
            return
        if mot.len == 0:
            zero[0] += 1.0
            return

        if nod.strand == 1:
            start = nod.ndx
        else:
            start = seq.slen-1-nod.ndx

        # Stage 0:  Count all motifs.
        # If a motif is detected, it is counted for every distance in stage 0.
        # This is done to make sure off-distance good motifs are recognized.
        if stage == 0:
            for i in reversed(range(4)):
                for j in range(start - 18 - i, start - 5 - i):
                    if j < 0:
                        continue
                    mer = _mer_ndx(seq.digits, seq.slen, j, i+3, nod.strand)
                    for k in range(4):
                        mcnt[i][k][mer] += 1.0
        # Stage 1:  Count only the best motif, but also count all its sub-motifs.
        elif stage == 1:
            mcnt[mot.len-3][mot.spacendx][mot.ndx] += 1.0;
            for i in range(mot.len - 3):
                for j in range(start-mot.spacer-mot.len, start-mot.spacer-i-2):
                    if j < 0:
                        continue
                    if j <= start-16-i:
                        spacendx = 3
                    elif j <= start-14-i:
                        spacendx = 2
                    elif j >= start-7-i:
                        spacendx = 1
                    else:
                        spacendx = 0
                    mer = _mer_ndx(seq.digits, seq.slen, j, i+3, nod.strand)
                    mcnt[i][spacendx][mer] += 1.0
        # Stage 2:  Only count the highest scoring motif.
        elif stage == 2:
            mcnt[mot.len-3][mot.spacendx][mot.ndx] += 1.0

    cdef void _calc_dicodon_gene(self, Sequence seq, _node* nodes, int ipath) nogil except *:
        """Compute the dicodon frequency in genes and in the background.

        Stores the log-likelihood of each 6-mer relative to the background.

        """
        cdef int    i
        cdef int    counts[4096]
        cdef double prob[4096]
        cdef double bg[4096]
        cdef int    in_gene      = 0
        cdef int    path         = ipath
        cdef int    left         = -1
        cdef int    right        = -1
        cdef int    glob

        self._on_modification()

        for i in range(4096):
            prob[i] = 0.0
            bg[i] = 0.0

        # get background counts
        # (shortened code from `calc_mer_bg` without malloc)
        glob = 0
        memset(counts, 0, 4096*sizeof(int))
        for i in range(seq.slen - 5):
            counts[_mer_ndx(seq.digits, seq.slen, i, 6,  1)] += 1
            counts[_mer_ndx(seq.digits, seq.slen, i, 6, -1)] += 1
            glob += 2
        for i in range(4096):
            bg[i] = (<double> counts[i]) / (<double> glob)

        # get counts in genes
        glob = 0
        memset(counts, 0, 4096*sizeof(int))
        while path != -1:
            if nodes[path].strand == 1:
                if nodes[path].type == node_type.STOP:
                    in_gene = 1
                    right = nodes[path].ndx+2
                elif in_gene == 1:
                    left = nodes[path].ndx
                    for i in range(left, right-5, 3):
                        counts[_mer_ndx(seq.digits, seq.slen, i, 6, 1)] += 1
                        glob += 1
                    in_gene = 0
            else:
                if nodes[path].type != node_type.STOP:
                    in_gene = -1
                    left = seq.slen - nodes[path].ndx - 1
                elif in_gene == -1:
                    right = seq.slen - nodes[path].ndx + 1
                    for i in range(left, right-5, 3):
                        counts[_mer_ndx(seq.digits, seq.slen, i, 6, -1)] += 1
                        glob += 1
                    in_gene = 0
            path = nodes[path].traceb

        # compute log likelihood
        for i in range(4096):
            prob[i] = (<double> counts[i])/(<double> glob)
            if prob[i] == 0 and bg[i] != 0:
                self.tinf.gene_dc[i] = -5.0;
            elif bg[i] == 0:
                self.tinf.gene_dc[i] = 0.0
            else:
                self.tinf.gene_dc[i] = log(prob[i]/bg[i])
            if self.tinf.gene_dc[i] > 5.0:
                self.tinf.gene_dc[i] = 5.0
            elif self.tinf.gene_dc[i] < -5.0:
                self.tinf.gene_dc[i] = -5.0

    cdef void _count_upstream_composition(self, Sequence seq, int pos, int strand=1) nogil except *:
        cdef int start
        cdef int j
        cdef int i     = 0

        self._on_modification()

        # NOTE: This function is patched not to read out of sequence
        #       boundaries, which can happen in the original Prodigal
        #       code when `count_upstream_composition` is called with
        #       a position less than 45 nucleotides away from the
        #       edges (this can be observed with Valgrind).

        if strand == 1:
            for j in range(1, 3):
                if pos >= j:
                    self.tinf.ups_comp[i][seq.digits[pos-j] & 0b11] += 1
                i += 1
            for j in range(15, 45):
                if pos >= j:
                    self.tinf.ups_comp[i][seq.digits[pos-j] & 0b11] += 1
                i += 1
        else:
            start = seq.slen - 1 - pos
            for j in range(1, 3):
                if pos + j < seq.slen:
                    self.tinf.ups_comp[i][_complement[seq.digits[pos+j]] & 0b11] += 1
                i += 1
            for j in range(15, 45):
                if pos + j < seq.slen:
                    self.tinf.ups_comp[i][_complement[seq.digits[pos+j]] & 0b11] += 1
                i += 1

    cdef void _train_starts_sd(self, Nodes nodes, Sequence seq) nogil except *:
        cdef int phase
        cdef int rbs[3]
        cdef int type[3]
        cdef int bndx[3]
        cdef int max_rb
        cdef double sum
        cdef double rbg[28]
        cdef double rreal[28]
        cdef double best[3]
        cdef double tbg[3]
        cdef double treal[3]
        cdef double sthresh   = 35.0
        cdef double wt        = self.tinf.st_wt

        cdef ssize_t i
        cdef ssize_t j
        cdef ssize_t nn = nodes.length

        self._on_modification()

        # reset training info
        for j in range(3):
            self.tinf.type_wt[j] = 0.0
        for j in range(28):
            self.tinf.rbs_wt[j] = 0.0
        for i in range(32):
            for j in range(4):
                self.tinf.ups_comp[i][j] = 0.0

        # Build the background of random types
        for i in range(3):
            tbg[i] = 0.0
        for i in range(nn):
            if nodes.nodes[i].type == node_type.STOP:
                continue
            tbg[nodes.nodes[i].type] += 1.0
        sum = 0.0
        for i in range(3):
            sum += tbg[i]
        for i in range(3):
            tbg[i] /= sum

        # Iterate 10 times through the list of nodes
        # Converge upon optimal weights for ATG vs GTG vs TTG and RBS motifs
        # (convergence typically takes 4-5 iterations, but we run a few
        # extra to be safe)
        for i in range(10):
            # Recalculate the RBS motif background */
            for j in range(28):
                rbg[j] = 0.0
            for j in range(nn):
                if nodes.nodes[j].type == node_type.STOP or nodes.nodes[j].edge:
                    continue
                if self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] > self.tinf.rbs_wt[nodes.nodes[j].rbs[1]]+1.0 or nodes.nodes[j].rbs[1] == 0:
                    max_rb = nodes.nodes[j].rbs[0]
                elif self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] < self.tinf.rbs_wt[nodes.nodes[j].rbs[1]]-1.0 or nodes.nodes[j].rbs[0] == 0:
                    max_rb = nodes.nodes[j].rbs[1]
                elif nodes.nodes[j].rbs[0] > nodes.nodes[j].rbs[1]:
                    max_rb = nodes.nodes[j].rbs[0]
                else:
                    max_rb = nodes.nodes[j].rbs[1]
                rbg[max_rb] += 1.0;

            sum = 0.0
            for j in range(28):
                sum += rbg[j]
            for j in range(28):
                rbg[j] /= sum

            for j in range(28):
                rreal[j] = 0.0
            for j in range(3):
                treal[j] = 0.0

            # Forward strand pass
            for j in range(3):
                best[j] = 0.0; bndx[j] = -1; rbs[j] = 0; type[j] = 0;
            for j in range(nn):
                if nodes.nodes[j].type != node_type.STOP and nodes.nodes[j].edge:
                    continue
                if nodes.nodes[j].strand == 1:
                    phase = nodes.nodes[j].ndx % 3
                    if nodes.nodes[j].type == node_type.STOP:
                        if best[phase] >= sthresh and nodes.nodes[bndx[phase]].ndx%3 == phase:
                            rreal[rbs[phase]] += 1.0
                            treal[type[phase]] += 1.0
                            if i == 9:
                                self._count_upstream_composition(seq, nodes.nodes[bndx[phase]].ndx, strand=1)
                        best[phase] = 0.0; bndx[phase] = -1; rbs[phase] = 0; type[phase] = 0;
                    else:
                        if self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] > self.tinf.rbs_wt[nodes.nodes[j].rbs[1]]+1.0 or nodes.nodes[j].rbs[1] == 0:
                            max_rb = nodes.nodes[j].rbs[0]
                        elif self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] < self.tinf.rbs_wt[nodes.nodes[j].rbs[1]]-1.0 or nodes.nodes[j].rbs[0] == 0:
                            max_rb = nodes.nodes[j].rbs[1]
                        elif nodes.nodes[j].rbs[0] > nodes.nodes[j].rbs[1]:
                            max_rb = nodes.nodes[j].rbs[0]
                        else:
                            max_rb = nodes.nodes[j].rbs[1]
                        if nodes.nodes[j].cscore + wt*self.tinf.rbs_wt[max_rb] + wt*self.tinf.type_wt[nodes.nodes[j].type] >= best[phase]:
                            best[phase] = nodes.nodes[j].cscore + wt*self.tinf.rbs_wt[max_rb] + wt*self.tinf.type_wt[nodes.nodes[j].type]
                            bndx[phase] = j
                            type[phase] = nodes.nodes[j].type
                            rbs[phase] = max_rb

            # Reverse strand pass
            for j in range(3):
                best[j] = 0.0
                bndx[j] = -1
                rbs[j] = 0
                type[j] = 0
            for j in reversed(range(nn)):
                if nodes.nodes[j].type != node_type.STOP and nodes.nodes[j].edge:
                    continue
                if nodes.nodes[j].strand == -1:
                    phase =  nodes.nodes[j].ndx % 3
                    if nodes.nodes[j].type == node_type.STOP:
                        if best[phase] >= sthresh and nodes.nodes[bndx[phase]].ndx%3 == phase:
                            rreal[rbs[phase]] += 1.0
                            treal[type[phase]] += 1.0
                            if i == 9:
                                self._count_upstream_composition(seq, nodes.nodes[bndx[phase]].ndx, strand=-1);
                        best[phase] = 0.0
                        bndx[phase] = -1
                        rbs[phase] = 0
                        type[phase] = 0
                    else:
                        if self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] > self.tinf.rbs_wt[nodes.nodes[j].rbs[1]] + 1.0 or nodes.nodes[j].rbs[1] == 0:
                            max_rb = nodes.nodes[j].rbs[0]
                        elif self.tinf.rbs_wt[nodes.nodes[j].rbs[0]] < self.tinf.rbs_wt[nodes.nodes[j].rbs[1]] - 1.0 or nodes.nodes[j].rbs[0] == 0:
                            max_rb = nodes.nodes[j].rbs[1]
                        elif nodes.nodes[j].rbs[0] > nodes.nodes[j].rbs[1]:
                            max_rb = nodes.nodes[j].rbs[0]
                        else:
                            max_rb = nodes.nodes[j].rbs[1]
                        if nodes.nodes[j].cscore + wt*self.tinf.rbs_wt[max_rb] + wt*self.tinf.type_wt[nodes.nodes[j].type] >= best[phase]:
                            best[phase] = nodes.nodes[j].cscore + wt*self.tinf.rbs_wt[max_rb] + wt*self.tinf.type_wt[nodes.nodes[j].type]
                            bndx[phase] = j
                            type[phase] = nodes.nodes[j].type
                            rbs[phase] = max_rb

            # Update RBS weights
            sum = 0.0;
            for j in range(28):
                sum += rreal[j]
            if sum == 0.0:
                for j in range(28):
                    self.tinf.rbs_wt[j] = 0.0
            else:
                for j in range(28):
                    rreal[j] /= sum
                    if rbg[j] != 0:
                        self.tinf.rbs_wt[j] = log(rreal[j]/rbg[j])
                    else:
                        self.tinf.rbs_wt[j] = -4.0
                    if self.tinf.rbs_wt[j] > 4.0:
                        self.tinf.rbs_wt[j] = 4.0
                    elif self.tinf.rbs_wt[j] < -4.0:
                        self.tinf.rbs_wt[j] = -4.0

            # Update type weights
            sum = 0.0
            for j in range(3):
                sum += treal[j]
            if sum == 0.0:
                for j in range(3):
                    self.tinf.type_wt[j] = 0.0
            else:
                for j in range(3):
                    treal[j] /= sum;
                    if tbg[j] != 0:
                        self.tinf.type_wt[j] = log(treal[j]/tbg[j])
                    else:
                        self.tinf.type_wt[j] = -4.0
                    if self.tinf.type_wt[j] > 4.0:
                        self.tinf.type_wt[j] = 4.0
                    elif self.tinf.type_wt[j] < -4.0:
                        self.tinf.type_wt[j] = -4.0;
            if sum*2000.0 <= nodes.length:
                sthresh /= 2.0

        # Convert upstream base composition to a log score
        for i in range(32):
            sum = 0.0;
            for j in range(4):
                sum += self.tinf.ups_comp[i][j];
            if sum == 0.0:
                for j in range(4):
                    self.tinf.ups_comp[i][j] = 0.0;
            else:
              for j in range(4):
                  self.tinf.ups_comp[i][j] /= sum
                  if self.tinf.gc <= 0.1:
                      if j == 0 or j == 3:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.90)
                      else:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.10)
                  elif self.tinf.gc >= 0.9:
                      if j == 0 or j == 3:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.10)
                      else:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.90)
                  else:
                      if j == 0 or j == 3:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/(1.0-self.tinf.gc))
                      else:
                          self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/self.tinf.gc)
                  if self.tinf.ups_comp[i][j] > 4.0:
                      self.tinf.ups_comp[i][j] = 4.0
                  if self.tinf.ups_comp[i][j] < -4.0:
                      self.tinf.ups_comp[i][j] = -4.0

    cdef void _train_starts_nonsd(self, Nodes nodes, Sequence seq) nogil except *:
        cdef int i
        cdef int j
        cdef int k
        cdef int l
        cdef int fr
        cdef int stage
        cdef int bndx[3]
        cdef int mgood[4][4][4096]
        cdef double sum
        cdef double ngenes
        cdef double zbg
        cdef double zreal
        cdef double best[3]
        cdef double tbg[3]
        cdef double treal[3]
        cdef double mbg[4][4][4096]
        cdef double mreal[4][4][4096]
        cdef double wt                = self.tinf.st_wt
        cdef double sthresh           = 35.0;
        cdef int    nn                = nodes.length

        self._on_modification()

        for i in range(32):
            for j in range(4):
                self.tinf.ups_comp[i][j] = 0.0

        # Build the background of random types
        for i in range(3):
            self.tinf.type_wt[i] = 0.0
            tbg[i] = 0.0;
        for i in range(nn):
            if nodes.nodes[i].type == node_type.STOP:
                continue
            tbg[nodes.nodes[i].type] += 1.0
        sum = 0.0
        for i in range(3):
            sum += tbg[i]
        for i in range(3):
            tbg[i] /= sum

        # Iterate 20 times through the list of nodes
        # Converge upon optimal weights for ATG vs GTG vs TTG and RBS motifs
        # (convergence typically takes 4-5 iterations, but we run a few
        # extra to be safe)
        for i in range(20):
            # Determine which stage of motif finding we're in */
            if i < 4:
                stage = 0
            elif i < 12:
                stage = 1
            else:
                stage = 2

            # Recalculate the upstream motif background and set 'real' counts to 0
            for j in range(4):
                for k in range(4):
                    for l in range(4096):
                        mbg[j][k][l] = 0.0
            zbg = 0.0
            for j in range(nn):
                if nodes.nodes[j].type == node_type.STOP or nodes.nodes[j].edge:
                    continue
                Node._find_best_upstream_motif(&nodes.nodes[j], seq, self.tinf, stage)
                TrainingInfo._update_motif_counts(mbg, &zbg, seq, &nodes.nodes[j], stage)
            sum = 0.0
            for j in range(4):
                for k in range(4):
                    for l in range(4096):
                        sum += mbg[j][k][l]
            sum += zbg
            for j in range(4):
                for k in range(4):
                    for l in range(4096):
                        mbg[j][k][l] /= sum
            zbg /= sum

            # Reset counts of 'real' motifs/types to 0
            for j in range(4):
                for k in range(4):
                    for l in range(4096):
                        mreal[j][k][l] = 0.0
            zreal = 0.0
            for j in range(3):
                treal[j] = 0.0
            ngenes = 0.0

            # Forward strand pass
            for j in range(3):
                best[j] = 0.0
                bndx[j] = -1
            for j in range(nn):
                if nodes.nodes[j].type != node_type.STOP and nodes.nodes[j].edge:
                    continue
                if nodes.nodes[j].strand == 1:
                    fr = (nodes.nodes[j].ndx)%3;
                    if nodes.nodes[j].type == node_type.STOP:
                        if best[fr] >= sthresh:
                            ngenes += 1.0
                            treal[nodes.nodes[bndx[fr]].type] += 1.0
                            TrainingInfo._update_motif_counts(mreal, &zreal, seq, &nodes.nodes[bndx[fr]], stage)
                            if i == 19:
                                self._count_upstream_composition(seq, nodes.nodes[bndx[fr]].ndx, strand=1)
                        best[fr] = 0.0;
                        bndx[fr] = -1;
                    else:
                        if nodes.nodes[j].cscore + wt*nodes.nodes[j].mot.score + wt*self.tinf.type_wt[nodes.nodes[j].type] >= best[fr]:
                            best[fr] = nodes.nodes[j].cscore + wt*nodes.nodes[j].mot.score + wt*self.tinf.type_wt[nodes.nodes[j].type]
                            bndx[fr] = j

            # Reverse strand pass
            for j in range(3):
                best[j] = 0.0
                bndx[j] = -1
            for j in reversed(range(nn)):
                if nodes.nodes[j].type != node_type.STOP and nodes.nodes[j].edge:
                    continue
                if nodes.nodes[j].strand == -1:
                    fr = (nodes.nodes[j].ndx)%3;
                    if nodes.nodes[j].type == node_type.STOP:
                        if best[fr] >= sthresh:
                            ngenes += 1.0;
                            treal[nodes.nodes[bndx[fr]].type] += 1.0;
                            TrainingInfo._update_motif_counts(mreal, &zreal, seq, &nodes.nodes[bndx[fr]], stage)
                            if i == 19:
                                self._count_upstream_composition(seq, nodes.nodes[bndx[fr]].ndx, strand=-1)
                        best[fr] = 0.0
                        bndx[fr] = -1
                    else:
                        if nodes.nodes[j].cscore + wt*nodes.nodes[j].mot.score + wt*self.tinf.type_wt[nodes.nodes[j].type] >= best[fr]:
                            best[fr] = nodes.nodes[j].cscore + wt*nodes.nodes[j].mot.score + wt*self.tinf.type_wt[nodes.nodes[j].type]
                            bndx[fr] = j

            # Update the log likelihood weights for type and RBS motifs
            if stage < 2:
                node.build_coverage_map(mreal, mgood, ngenes, stage)
            sum = 0.0
            for j in range(4):
                for k in range(4):
                    for l in range(4096):
                        sum += mreal[j][k][l]
            sum += zreal;
            if sum == 0.0:
                for j in range(4):
                    for k in range(4):
                        for l in range(4096):
                            self.tinf.mot_wt[j][k][l] = 0.0
                self.tinf.no_mot = 0.0;
            else:
                for j in range(4):
                    for k in range(4):
                        for l in range(4096):
                            if mgood[j][k][l] == 0:
                                zreal += mreal[j][k][l]
                                zbg += mreal[j][k][l]
                                mreal[j][k][l] = 0.0
                                mbg[j][k][l] = 0.0
                            mreal[j][k][l] /= sum;
                            if mbg[j][k][l] != 0:
                                self.tinf.mot_wt[j][k][l] = log(mreal[j][k][l]/mbg[j][k][l])
                            else:
                                self.tinf.mot_wt[j][k][l] = -4.0
                            if self.tinf.mot_wt[j][k][l] > 4.0:
                                self.tinf.mot_wt[j][k][l] = 4.0
                            elif self.tinf.mot_wt[j][k][l] < -4.0:
                                self.tinf.mot_wt[j][k][l] = -4.0
            zreal /= sum
            if zbg != 0:
                self.tinf.no_mot = log(zreal/zbg)
            else:
                self.tinf.no_mot = -4.0
            if self.tinf.no_mot > 4.0:
                self.tinf.no_mot = 4.0
            elif self.tinf.no_mot < -4.0:
                self.tinf.no_mot = -4.0
            sum = 0.0;
            for j in range(3):
                sum += treal[j]
            if sum == 0.0:
                for j in range(3):
                    self.tinf.type_wt[j] = 0.0
            else:
                for j in range(3):
                    treal[j] /= sum;
                    if tbg[j] != 0:
                        self.tinf.type_wt[j] = log(treal[j]/tbg[j])
                    else:
                        self.tinf.type_wt[j] = -4.0;
                    if self.tinf.type_wt[j] > 4.0:
                        self.tinf.type_wt[j] = 4.0
                    elif self.tinf.type_wt[j] < -4.0:
                        self.tinf.type_wt[j] = -4.0
            if sum * 2000.0 <= nn:
                sthresh /= 2.0

        # Convert upstream base composition to a log score
        for i in range(32):
            sum = 0.0
            for j in range(4):
                sum += self.tinf.ups_comp[i][j]
            if sum == 0.0:
                for j in range(4):
                    self.tinf.ups_comp[i][j] = 0.0
            else:
                for j in range(4):
                    self.tinf.ups_comp[i][j] /= sum
                    if self.tinf.gc <= 0.1:
                        if j == 0 or j == 3:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.90)
                        else:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.10)
                    elif self.tinf.gc >= 0.9:
                        if j == 0 or j == 3:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.10)
                        else:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/0.90)
                    else:
                        if j == 0 or j == 3:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/(1.0-self.tinf.gc));
                        else:
                            self.tinf.ups_comp[i][j] = log(self.tinf.ups_comp[i][j]*2.0/self.tinf.gc);
                    if self.tinf.ups_comp[i][j] > 4.0:
                        self.tinf.ups_comp[i][j] = 4.0
                    elif self.tinf.ups_comp[i][j] < -4.0:
                        self.tinf.ups_comp[i][j] = -4.0


    # --- Python interface ---------------------------------------------------

    cpdef object dump(self, fp):
        """dump(self, fp)\n--

        Write a training info to a file-like handle.

        Arguments:
            fp (file-like object): An file-like handle opened in *binary*
                mode, into which the training info should be written.

        Danger:
            This method is not safe to use across different machines. The
            internal binary structure will be dumped as-is, and because the
            C types can change in size and representation between CPUs and
            OS, the file will not portable. This method is only provided
            to offer the same kind of features as the Prodigal binary. For
            a safe way of storing and sharing a `TrainingInfo`, use the
            `pickle` module.

        .. versionadded:: 0.6.4

        """
        cdef object mem = PyMemoryView_FromMemory(<char*> self.tinf, sizeof(_training), MVIEW_READ)
        fp.write(mem)


# --- Metagenomic Bins -------------------------------------------------------

cdef class MetagenomicBin:
    """A pre-trained collection used to find genes in metagenomic mode.

    Attributes:
        training_info (`~pyrodigal.TrainingInfo`): The training info for
            this metagenomic bin.

    """

    # --- Magic methods ------------------------------------------------------

    def __repr__(self):
        ty = type(self)
        return "<{}.{} index={!r} description={!r}>".format(
            ty.__module__,
            ty.__name__,
            self.index,
            self.description,
        )

    # --- Properties ---------------------------------------------------------

    @property
    def index(self):
        """`int`: The index of this metagenomic bin.
        """
        assert self.bin != NULL
        return self.bin.index

    @property
    def description(self):
        """`str`: A condensed text description for this metagenomic bin.
        """
        assert self.bin != NULL
        return self.bin.desc.decode('ascii')

# Reserve raw C memory for the C structs without allocation
cdef _training _METAGENOMIC_TRAINING_INFO[NUM_META]
cdef _metagenomic_bin _METAGENOMIC_BINS[NUM_META]
cdef ssize_t _i
for _i in range(NUM_META):
    memset(&_METAGENOMIC_BINS[_i], 0, sizeof(_metagenomic_bin))
    _METAGENOMIC_BINS[_i].tinf = &_METAGENOMIC_TRAINING_INFO[_i]
    memset(_METAGENOMIC_BINS[_i].tinf, 0, sizeof(_training))
initialize_metagenomic_bins(_METAGENOMIC_BINS)

# Create a tuple of objects exposing the C metagenomic bins
cdef MetagenomicBin _bin
cdef tuple _m = PyTuple_New(NUM_META)
for _i in range(NUM_META):
    _bin = MetagenomicBin.__new__(MetagenomicBin, )
    _bin.bin = &_METAGENOMIC_BINS[_i]
    _bin.training_info = TrainingInfo.__new__(TrainingInfo)
    _bin.training_info.owned = False
    _bin.training_info.meta_index = _i
    _bin.training_info.tinf = _bin.bin.tinf
    PyTuple_SET_ITEM(_m, _i, _bin)
    Py_INCREF(_bin)
METAGENOMIC_BINS = _m

# --- OrfFinder --------------------------------------------------------------

cdef class OrfFinder:
    """A configurable ORF finder for genomes and metagenomes.

    Attributes:
        meta (`bool`): Whether or not this object is configured to
            find genes using the metagenomic bins or manually created
            training infos.
        closed (`bool`): Whether or not proteins can run off edges when
            finding genes in a sequence.
        mask (`bool`): Prevent genes from running across regions containing
            unknown nucleotides.
        training_info (`~pyrodigal.TrainingInfo`): The object storing the
            training information, or `None` if the object is in metagenomic
            mode or hasn't been trained yet.
        min_gene (`int`): The minimum gene length.
        min_edge_gene (`int`): The minimum edge gene length.
        max_overlap (`int`): The maximum number of nucleotides that can
            overlap between two genes on the same strand.

    """

    # --- Magic methods ------------------------------------------------------

    def __cinit__(self):
        self._num_seq = 1
        self.backend = "detect"

    def __init__(
        self,
        TrainingInfo training_info=None,
        *,
        bint meta=False,
        bint closed=False,
        bint mask=False,
        int min_gene=MIN_GENE,
        int min_edge_gene=MIN_EDGE_GENE,
        int max_overlap=MAX_SAM_OVLP,
        str backend="detect",
    ):
        """__init__(self, training_info=None, *, meta=False, closed=False, mask=False, min_gene=90, min_edge_gene=60, max_overlap=60, backend="detect")\n--

        Instantiate and configure a new ORF finder.

        Arguments:
            training_info (`~pyrodigal.TrainingInfo`, optional): A training
                info instance to use in single mode without having to
                train first.

        Keyword Arguments:
            meta (`bool`): Set to `True` to run in metagenomic mode, using
                a pre-trained profiles for better results with metagenomic
                or progenomic inputs. Defaults to `False`.
            closed (`bool`): Set to `True` to consider sequences ends
                *closed*, which prevents proteins from running off edges.
                Defaults to `False`.
            mask (`bool`): Prevent genes from running across regions
                containing unknown nucleotides. Defaults to `False`.
            min_gene (`int`): The minimum gene length. Defaults to the value
                used in Prodigal.
            min_edge_gene (`int`): The minimum edge gene length. Defaults to
                the value used in Prodigal.
            max_overlap (`int`): The maximum number of nucleotides that can
                overlap between two genes on the same strand. **This must be
                lower or equal to the minimum gene length**.
            backend (`str`): The backend implementation to use for computing
                the connection scoring pre-filter. Leave as ``"detect"`` to
                select the fastest available implementation at runtime.
                *Mostly useful for testing*.

        .. versionadded:: 0.6.4
            The ``training_info`` argument.

        .. versionadded:: 0.7.0
            The ``min_edge``, ``min_edge_gene`` and ``max_overlap`` arguments.

        .. versionadded:: 2.0.0
            The ``backend`` argument.

        """
        if meta and training_info is not None:
            raise ValueError("cannot use a training info in meta mode.")

        if min_gene <= 0:
            raise ValueError("`min_gene` must be strictly positive")
        if min_edge_gene <= 0:
            raise ValueError("`min_edge_gene` must be strictly positive")
        if max_overlap < 0:
            raise ValueError("`max_overlap` must be positive")
        elif max_overlap > min_gene:
            raise ValueError("`max_overlap` must be lower than `min_gene`")

        self.meta = meta
        self.closed = closed
        self.lock = threading.Lock()
        self.mask = mask
        self.training_info = training_info
        self.min_gene = min_gene
        self.min_edge_gene = min_edge_gene
        self.max_overlap = max_overlap
        self.backend = backend

    def __repr__(self):
        cdef list template = []
        if self.training_info is not None:
            template.append(f"training_info={self.training_info!r}")
        if self.meta:
            template.append(f"meta={self.meta!r}")
        if self.closed:
            template.append(f"closed={self.closed!r}")
        if self.mask:
            template.append(f"mask={self.mask!r}")
        if self.min_gene != MIN_GENE:
            template.append(f"min_gene={self.min_gene!r}")
        if self.min_edge_gene != MIN_EDGE_GENE:
            template.append(f"min_edge_gene={self.min_edge_gene!r}")
        if self.max_overlap != MAX_SAM_OVLP:
            template.append(f"max_overlap={self.max_overlap!r}")
        if self.backend != "detect":
            template.append(f"backend={self.backend!r}")
        ty = type(self)
        return "{}.{}({})".format(ty.__module__, ty.__name__, ", ".join(template))

    cpdef dict __getstate__(self):
        """__getstate__(self)\n--
        """
        return {
            "_num_seq": self._num_seq,
            "closed": self.closed,
            "meta": self.meta,
            "mask": self.mask,
            "min_gene": self.min_gene,
            "min_edge_gene": self.min_edge_gene,
            "max_overlap": self.max_overlap,
            "training_info": self.training_info
        }

    cpdef object __setstate__(self, dict state):
        """__setstate__(self, state)\n--
        """
        self.lock = threading.Lock()
        self._num_seq = state["_num_seq"]
        self.closed = state["closed"]
        self.meta = state["meta"]
        self.mask = state["mask"]
        self.min_gene = state["min_gene"]
        self.min_edge_gene = state["min_edge_gene"]
        self.max_overlap = state["max_overlap"]
        self.training_info = state["training_info"]

    # --- C interface --------------------------------------------------------

    cdef int _train(
        self,
        Sequence sequence,
        Nodes nodes,
        ConnectionScorer scorer,
        TrainingInfo tinf,
        bint force_nonsd,
    ) nogil except -1:
        cdef int* gc_frame
        cdef int  ipath
        # find all the potential starts and stops
        nodes._extract(
            sequence,
            tinf.tinf.trans_table,
            closed=self.closed,
            min_gene=self.min_gene,
            min_edge_gene=self.min_edge_gene
        )
        nodes._sort()
        scorer._index(nodes)
        # scan all the ORFs looking for a potential GC bias in a particular
        # codon position, in order to acquire a good initial set of genes
        gc_frame = sequence._max_gc_frame_plot(_WINDOW)
        if not gc_frame:
            raise MemoryError()
        node.record_gc_bias(gc_frame, nodes.nodes, nodes.length, tinf.tinf)
        free(gc_frame)
        # do an initial dynamic programming routine with just the GC frame bias
        # used as a scoring function.
        nodes._record_overlapping_starts(tinf.tinf, False, self.max_overlap)
        ipath = nodes._dynamic_programming(tinf.tinf, scorer, final=False)
        # gather dicodon statistics for the training set
        tinf._calc_dicodon_gene(sequence, nodes.nodes, ipath)
        nodes._raw_coding_score(sequence, tinf.tinf)
        # determine if this organism uses Shine-Dalgarno and score the node
        nodes._rbs_score(sequence, tinf.tinf)
        tinf._train_starts_sd(nodes, sequence)
        if force_nonsd:
            tinf.tinf.uses_sd = False
        else:
            node.determine_sd_usage(tinf.tinf)
        if not tinf.tinf.uses_sd:
            tinf._train_starts_nonsd(nodes, sequence)
        # return 0 on success
        return 0

    cdef int _find_genes_single(
        self,
        Sequence sequence,
        TrainingInfo tinf,
        ConnectionScorer scorer,
        Nodes nodes,
        Genes genes,
    ) nogil except -1:
        cdef int ipath
        # find all the potential starts and stops, and sort them
        nodes._extract(
            sequence,
            tinf.tinf.trans_table,
            closed=self.closed,
            min_gene=self.min_gene,
            min_edge_gene=self.min_edge_gene
        )
        nodes._sort()
        scorer._index(nodes)
        # second dynamic programming, using the dicodon statistics as the
        # scoring function
        nodes._reset_scores()
        nodes._score(sequence, tinf.tinf, closed=self.closed, is_meta=False)
        nodes._record_overlapping_starts(tinf.tinf, True, self.max_overlap)
        ipath = nodes._dynamic_programming(tinf.tinf, scorer, final=True)
        # eliminate eventual bad genes in the nodes
        if nodes.length > 0:
            dprog.eliminate_bad_genes(nodes.nodes, ipath, tinf.tinf)
        # record genes
        genes._extract(nodes, ipath)
        genes._tweak_final_starts(nodes, tinf.tinf, self.max_overlap)
        # NOTE: In the original Prodigal code, the gene data would be
        #       recorded here, but since we build the gene data string
        #       on request we don't have to pre-build them here.
        return 0

    cdef int _find_genes_meta(
        self,
        Sequence sequence,
        ConnectionScorer scorer,
        Nodes nodes,
        Genes genes,
    ) nogil except -1:
        cdef int          i
        cdef double       low
        cdef double       high
        cdef int          ipath
        cdef _training*   tinf
        cdef int          tt        = -1
        cdef int          max_phase = 0
        cdef double       max_score = -100.0

        # compute the min/max acceptable gc for the sequence to only
        # use appropriate metagenomic bins
        low = fmin(0.65, 0.88495*sequence.gc - 0.0102337)
        high = fmax(0.35, 0.86596*sequence.gc + 0.1131991)

        # check which of the metagenomic bins gets the best results
        for i in range(NUM_META):
            # check which of the metagenomic bins gets the best results
            if _METAGENOMIC_BINS[i].tinf.gc < low or _METAGENOMIC_BINS[i].tinf.gc > high:
                continue
            # record the training information for the current bin
            tinf = _METAGENOMIC_BINS[i].tinf
            # recreate the node list if the translation table changed
            if tinf.trans_table != tt:
                tt = tinf.trans_table
                nodes._clear()
                nodes._extract(
                    sequence,
                    tinf.trans_table,
                    closed=self.closed,
                    min_gene=self.min_gene,
                    min_edge_gene=self.min_edge_gene
                )
                nodes._sort()
                scorer._index(nodes)
            # compute the score for the current bin
            nodes._reset_scores()
            nodes._score(sequence, tinf, closed=self.closed, is_meta=True)
            nodes._record_overlapping_starts(tinf, True, self.max_overlap)
            ipath = nodes._dynamic_programming(tinf, scorer, final=True)
            # update genes if the current bin had a better score
            if nodes.length > 0 and ipath >= 0 and nodes.nodes[ipath].score > max_score:
                # record best phase and score
                max_phase = i
                max_score = nodes.nodes[ipath].score
                # eliminate eventual bad genes in the nodes
                dprog.eliminate_bad_genes(nodes.nodes, ipath, tinf)
                # clear the gene array
                genes._clear()
                # extract the genes from the dynamic programming array
                genes._extract(nodes, ipath)
                genes._tweak_final_starts(nodes, tinf, self.max_overlap)
                # NOTE: In the original Prodigal code, the gene data would be
                #       recorded here, but since we build the gene data string
                #       on request we don't have to pre-build them here.

        # recover the nodes corresponding to the best run
        tinf = _METAGENOMIC_BINS[max_phase].tinf
        nodes._clear()
        nodes._extract(
            sequence,
            tinf.trans_table,
            closed=self.closed,
            min_gene=self.min_gene,
            min_edge_gene=self.min_edge_gene
        )
        nodes._sort()
        # rescore nodes
        scorer._index(nodes)
        nodes._reset_scores()
        nodes._score(sequence, tinf, closed=self.closed, is_meta=True)

        # return the max phase on success
        return max_phase

    # --- Python interface ---------------------------------------------------

    cpdef Genes find_genes(self, object sequence):
        """find_genes(self, sequence)\n--

        Find all the genes in the input DNA sequence.

        Arguments:
            sequence (`str` or buffer): The nucleotide sequence to use,
                either as a string of nucleotides, or as an object
                implementing the buffer protocol. Letters not corresponding
                to an usual nucleotide (not any of "ATGC") will be ignored.

        Returns:
            `~pyrodigal.Genes`: A list of all the genes found in the input.

        Raises:
            `MemoryError`: When allocation of an internal buffers fails.
            `RuntimeError`: On calling this method without having called
                `~Pyrodigal.train` before while in *single* mode.
            `TypeError`: When ``sequence`` does not implement the buffer
                protocol.

        """
        cdef int              n
        cdef int              phase
        cdef Sequence         seq
        cdef TrainingInfo     tinf
        cdef ConnectionScorer scorer = ConnectionScorer(backend=self.backend)
        cdef Genes            genes  = Genes.__new__(Genes)
        cdef Nodes            nodes  = Nodes.__new__(Nodes)

        # check argument values
        if not self.meta and self.training_info is None:
            raise RuntimeError("cannot find genes without having trained in single mode")

        # convert the input to a `Sequence` object
        seq = Sequence(sequence, mask=self.mask)

        # extract the current sequence index
        with self.lock:
            genes._num_seq = self._num_seq
            self._num_seq += 1

        # find genes with the right mode
        if self.meta:
            with nogil:
                phase = self._find_genes_meta(seq, scorer, nodes, genes)
            tinf = METAGENOMIC_BINS[phase].training_info
        else:
            tinf = self.training_info
            with nogil:
                self._find_genes_single(
                    seq,
                    tinf,
                    scorer,
                    nodes,
                    genes,
                )

        # return the predicted genes
        genes.sequence = seq
        genes.nodes = nodes
        genes.training_info = tinf
        genes.meta = self.meta
        return genes

    def train(
        self,
        object sequence,
        *sequences,
        bint force_nonsd=False,
        double start_weight=4.35,
        int translation_table=11
    ):
        """train(self, sequence, *sequences, force_nonsd=False, start_weight=4.35, translation_table=11)\n--

        Search parameters for the ORF finder using a training sequence.

        If more than one sequence is provided, it is assumed that they are
        different contigs part of the same genome. Like in the original
        Prodigal implementation, they will be merged together in a single
        sequence joined by ``TTAATTAATTAA`` linkers.

        Arguments:
            sequence (`str` or buffer): The nucleotide sequence to use,
                either as a string of nucleotides, or as an object
                implementing the buffer protocol.

        Keyword Arguments:
            force_nonsd (`bool`, optional): Set to ``True`` to bypass the
                heuristic algorithm that tries to determine if the organism
                the training sequence belongs to uses a Shine-Dalgarno motif
                or not.
            start_weight (`float`, optional): The start score weight to use.
                The default value has been manually selected by the Prodigal
                authors as an appropriate value for 99% of genomes.
            translation_table (`int`, optional): The translation table to
                use. Check the `Wikipedia <https://w.wiki/47wo>`_ page
                listing all genetic codes for the available values.

        Returns:
            `~pyrodigal.TrainingInfo`: The resulting training info, which
            can be saved to disk and used later on to create a new
            `~pyrodigal.OrfFinder` instance.

        Raises:
            `MemoryError`: When allocation of an internal buffers fails.
            `RuntimeError`: When calling this method while in *metagenomic*
                mode.
            `TypeError`: When ``sequence`` does not implement the buffer
                protocol.
            `ValueError`: When ``translation_table`` is not a valid genetic
                code number, or when ``sequence`` is too short to train.

        """
        cdef Sequence         seq
        cdef int              slen
        cdef TrainingInfo     tinf
        cdef Nodes            nodes  = Nodes()
        cdef ConnectionScorer scorer = ConnectionScorer(backend=self.backend)

        # Check arguments
        if self.meta:
            raise RuntimeError("cannot use training sequence in metagenomic mode")
        if translation_table not in _TRANSLATION_TABLES:
            raise ValueError(f"{translation_table} is not a valid translation table index")

        # extract sequence
        if isinstance(sequence, Sequence):
            if sequences:
                raise NotImplementedError("cannot use more than one `Sequence` object in `OrfFinder.train`")
            seq = sequence
        elif isinstance(sequence, str):
            if sequences:
                sequence = "TTAATTAATTAA".join(itertools.chain([sequence], sequences, [""]))
            seq = Sequence(sequence, mask=self.mask)
        else:
            if sequences:
                sequence = b"TTAATTAATTAA".join(itertools.chain([sequence], sequences, [b""]))
            seq = Sequence(sequence, mask=self.mask)

        # check sequence length
        if seq.slen < _MIN_SINGLE_GENOME:
            raise ValueError(
                f"sequence must be at least {_MIN_SINGLE_GENOME} characters ({seq.slen} found)"
            )
        elif seq.slen < _IDEAL_SINGLE_GENOME:
            warnings.warn(
                f"sequence should be at least {_IDEAL_SINGLE_GENOME} characters ({seq.slen} found)"
            )

        # build training info
        tinf = TrainingInfo(seq.gc, start_weight, translation_table)
        with nogil:
            self._train(
                seq,
                nodes,
                scorer,
                tinf,
                force_nonsd,
            )

        # store it, using a lock to avoid race condition if there is
        # currently a `find_genes` call going on in a different thread
        with self.lock:
            self.training_info = tinf

        return tinf
