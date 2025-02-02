import configparser
import functools
import glob
import multiprocessing.pool
import os
import platform
import re
import subprocess
import sys

import setuptools
import setuptools.extension
from distutils import log
from distutils.errors import CompileError
from distutils.command.clean import clean as _clean
from setuptools.command.build_ext import build_ext as _build_ext
from setuptools.command.build_clib import build_clib as _build_clib
from setuptools.command.sdist import sdist as _sdist
from setuptools.extension import Library

try:
    from Cython.Build import cythonize
except ImportError as err:
    cythonize = err


# --- Utils ------------------------------------------------------------------

def _eprint(*args, **kwargs):
    print(*args, **kwargs, file=sys.stderr)

def _patch_osx_compiler(compiler, machine):
    # On newer OSX, Python has been compiled as a universal binary, so
    # it will attempt to pass universal binary flags when building the
    # extension. This will not work because the code makes use of CPU
    # specific SIMD extensions.
    for tool in ("compiler", "compiler_so", "linker_so"):
        flags = getattr(compiler, tool)
        i = next((i for i in range(1, len(flags)) if flags[i-1] == "-arch" and flags[i] != machine), None)
        if i is not None:
            flags.pop(i)
            flags.pop(i-1)

def _detect_target_machine(platform):
    if platform == "win32":
        return "x86"
    return platform.rsplit("-", 1)[-1]

def _detect_target_cpu(platform):
    machine = _detect_target_machine(platform)
    if re.match("^mips", machine):
        return "mips"
    elif re.match("^(aarch64|arm64)$", machine):
        return "aarch64"
    elif re.match("^arm", machine):
        return "arm"
    elif re.match("(x86_64)|(x86)|(AMD64|amd64)|(^i.86$)", machine):
        return "x86"
    elif re.match("^(powerpc|ppc)", machine):
        return "ppc"
    return None

def _detect_target_system(platform):
    if platform.startswith("win"):
        return "windows"
    elif platform.startswith("macos"):
        return "macos"
    elif platform.startswith("linux"):
        return "linux_or_android"
    elif platform.startswith("freebsd"):
        return "freebsd"
    return None


# --- Commands ------------------------------------------------------------------

class Extension(setuptools.extension.Extension):

    def __init__(self, *args, **kwargs):
        self._needs_stub = False
        self.platform_sources = kwargs.pop("platform_sources", {})
        super().__init__(*args, **kwargs)


# --- Commands ------------------------------------------------------------------

class sdist(_sdist):
    """A `sdist` that generates a `pyproject.toml` on the fly.
    """

    def run(self):
        # build `pyproject.toml` from `setup.cfg`
        c = configparser.ConfigParser()
        c.add_section("build-system")
        c.set("build-system", "requires", str(self.distribution.setup_requires))
        c.set("build-system", 'build-backend', '"setuptools.build_meta"')
        with open("pyproject.toml", "w") as pyproject:
            c.write(pyproject)
        # run the rest of the packaging
        _sdist.run(self)


class build_ext(_build_ext):
    """A `build_ext` that disables optimizations if compiled in debug mode.
    """

    # --- Compatibility with `setuptools.Command`

    user_options = _build_ext.user_options + [
        ("disable-avx2", None, "Force compiling the extension without AVX2 instructions"),
        ("disable-sse2", None, "Force compiling the extension without SSE2 instructions"),
        ("disable-mmx", None, "Force compiling the extension without MMX instructions"),
        ("disable-neon", None, "Force compiling the extension without NEON instructions"),
    ]

    def initialize_options(self):
        _build_ext.initialize_options(self)
        self.disable_avx2 = False
        self.disable_sse2 = False
        self.disable_neon = False
        self.disable_mmx  = False
        self.target_machine = None
        self.target_system = None
        self.target_cpu = None

    def finalize_options(self):
        _build_ext.finalize_options(self)
        # detect platform options
        self.target_machine = _detect_target_machine(self.plat_name)
        self.target_system = _detect_target_system(self.plat_name)
        self.target_cpu = _detect_target_cpu(self.plat_name)
        # record SIMD-specific options
        self._simd_supported = dict(AVX2=False, SSE2=False, NEON=False, MMX=False)
        self._simd_defines = dict(AVX2=[], SSE2=[], NEON=[], MMX=[])
        self._simd_flags = dict(AVX2=[], SSE2=[], NEON=[], MMX=[])
        self._simd_disabled = {
            "AVX2": self.disable_avx2,
            "SSE2": self.disable_sse2,
            "NEON": self.disable_neon,
            "MMX": self.disable_mmx,
        }
        # transfer arguments to the build_clib method
        self._clib_cmd = self.get_finalized_command("build_clib")
        self._clib_cmd.debug = self.debug
        self._clib_cmd.force = self.force
        self._clib_cmd.verbose = self.verbose
        self._clib_cmd.define = self.define
        self._clib_cmd.include_dirs = self.include_dirs
        self._clib_cmd.compiler = self.compiler
        self._clib_cmd.parallel = self.parallel
        self._clib_cmd.plat_name = self.plat_name
        self._clib_cmd.target_machine = self.target_machine
        self._clib_cmd.target_system = self.target_system
        self._clib_cmd.target_cpu = self.target_cpu

    # --- Autotools-like helpers ---

    def _check_simd_generic(self, name, flags, program):
        _eprint('checking whether compiler can build', name, 'code', end="... ")

        base = "have_{}".format(name)
        testfile = os.path.join(self.build_temp, "{}.c".format(base))
        binfile = self.compiler.executable_filename(base, output_dir=self.build_temp)
        objects = []

        self.mkpath(self.build_temp)
        with open(testfile, "w") as f:
            f.write(program)

        try:
            self.mkpath(self.build_temp)
            objects = self.compiler.compile([testfile], extra_preargs=flags)
            self.compiler.link_executable(objects, base, extra_preargs=flags, output_dir=self.build_temp)
            subprocess.run([binfile], check=True)
        except CompileError:
            _eprint("no")
            return False
        except (subprocess.SubprocessError, OSError):
            _eprint("yes, but cannot run code")
            return True  # assume we are cross-compiling, and still build
        else:
            if not flags:
                _eprint("yes")
            else:
                _eprint("yes, with {}".format(" ".join(flags)))
            return True
        finally:
            os.remove(testfile)
            for obj in filter(os.path.isfile, objects):
                os.remove(obj)
            if os.path.isfile(binfile):
                os.remove(binfile)

    def _avx2_flags(self):
        if self.compiler.compiler_type == "msvc":
            return ["/arch:AVX2"]
        return ["-mavx", "-mavx2"]

    def _check_avx2(self):
        return self._check_simd_generic(
            "AVX2",
            self._avx2_flags(),
            program="""
                #include <immintrin.h>
                int main(int argc, char *argv[]) {{
                    __m256i a = _mm256_set1_epi16(-1);
                            a = _mm256_abs_epi16(a);
                    short   x = _mm256_extract_epi16(a, 1);
                    return (x == 1) ? 0 : 1;
                }}
            """,
        )

    def _sse2_flags(self):
        if self.compiler.compiler_type == "msvc":
            return ["/arch:SSE2"]
        return ["-msse", "-msse2"]

    def _check_sse2(self):
        return self._check_simd_generic(
            "SSE2",
            self._sse2_flags(),
            program="""
                #include <emmintrin.h>
                int main(int argc, char *argv[]) {{
                    __m128i a = _mm_set1_epi16(-1);
                            a = _mm_and_si128(a, a);
                    short   x = _mm_extract_epi16(a, 1);
                    return (x == -1) ? 0 : 1;
                }}
            """,
        )

    def _neon_flags(self):
        return ["-mfpu=neon"] if self.target_cpu == "arm" else []

    def _check_neon(self):
        return self._check_simd_generic(
            "NEON",
            self._neon_flags(),
            program="""
                #include <arm_neon.h>
                int main(int argc, char *argv[]) {{
                    int16x8_t a = vdupq_n_s16(-1);
                              a = vabsq_s16(a);
                    short     x = vgetq_lane_s16(a, 1);
                    return (x == 1) ? 0 : 1;
                }}
            """,
        )
    
    def _mmx_flags(self):
        return []

    def _check_mmx(self):
        return self._check_simd_generic(
            "MMX",
            self._mmx_flags(),
            program="""
                #include <mmintrin.h>
                int main(int argc, char *argv[]) {{
                    __m64 a = _mm_set1_pi16(1);
                    short x = (short) _m_to_int(a);
                    return (x == 1) ? 0 : 1;
                }}
            """,
        )

    # --- Build code ---

    def build_simd_code(self, ext):
        # build platform-specific code
        for simd, sources in ext.platform_sources.items():
            if self._simd_supported[simd] and not self._simd_disabled[simd]:
                objects = [
                    os.path.join(self.build_temp, s.replace(".c", self.compiler.obj_extension))
                    for s in sources
                ]
                for source, object in zip(sources, objects):
                    self.make_file(
                        [source],
                        object,
                        self.compiler.compile,
                        (
                            [source],
                            self.build_temp,
                            ext.define_macros + self._simd_defines[simd],
                            ext.include_dirs,
                            self.debug,
                            ext.extra_compile_args + self._simd_flags[simd],
                            None,
                            ext.depends
                        )
                    )
                ext.extra_objects.extend(objects)
                if simd == "NEON" or simd == "AVX2":
                    ext.extra_link_args.extend(self._simd_flags[simd])

    def build_extension(self, ext):
        # show the compiler being used
        _eprint("building", ext.name, "for", self.plat_name, "with", self.compiler.compiler_type, "compiler")
        # add debug symbols if we are building in debug mode
        if self.debug:
            if self.compiler.compiler_type in {"unix", "cygwin", "mingw32"}:
                ext.extra_compile_args.append("-g")
            elif self.compiler.compiler_type == "msvc":
                ext.extra_compile_args.append("/Z7")
            if sys.implementation.name == "cpython":
                ext.define_macros.append(("CYTHON_TRACE_NOGIL", 1))
        else:
            ext.define_macros.append(("CYTHON_WITHOUT_ASSERTIONS", 1))
        # remove universal binary CFLAGS from the compiler if any
        if self.target_system == "macos":
            _patch_osx_compiler(self.compiler, self.target_machine)
        # update link and include directories
        for name in ext.libraries:
            lib = self._clib_cmd.get_library(name)
            libfile = self.compiler.library_filename(
                lib.name, output_dir=self._clib_cmd.build_clib
            )
            ext.depends.append(libfile)
            ext.extra_objects.append(libfile)
        # build platform-specific code
        self.build_simd_code(ext)
        # build the rest of the extension as normal
        _build_ext.build_extension(self, ext)

    def build_extensions(self):
        # check `cythonize` is available
        if isinstance(cythonize, ImportError):
            raise RuntimeError("Cython is required to run `build_ext` command") from cythonize

        # compile the C library if not done already
        if not self.distribution.have_run.get("build_clib", False):
            self._clib_cmd.run()

        # use debug directives with Cython if building in debug mode
        cython_args = {
            "include_path": ["include"],
            "compiler_directives": {
                "cdivision": True,
                "nonecheck": False,
            },
            "compile_time_env": {
                "SYS_IMPLEMENTATION_NAME": sys.implementation.name,
                "SYS_VERSION_INFO_MAJOR": sys.version_info.major,
                "SYS_VERSION_INFO_MINOR": sys.version_info.minor,
                "SYS_VERSION_INFO_MICRO": sys.version_info.micro,
                "TARGET_CPU": self.target_cpu,
                "TARGET_SYSTEM": self.target_system,
                "AVX2_BUILD_SUPPORT": False,
                "NEON_BUILD_SUPPORT": False,
                "SSE2_BUILD_SUPPORT": False,
                "MMX_BUILD_SUPPORT": False,
            }
        }
        if self.force:
            cython_args["force"] = True
        if self.debug:
            cython_args["annotate"] = True
            cython_args["compiler_directives"]["cdivision_warnings"] = True
            cython_args["compiler_directives"]["warn.undeclared"] = True
            cython_args["compiler_directives"]["warn.unreachable"] = True
            cython_args["compiler_directives"]["warn.maybe_uninitialized"] = True
            cython_args["compiler_directives"]["warn.unused"] = True
            cython_args["compiler_directives"]["warn.unused_arg"] = True
            cython_args["compiler_directives"]["warn.unused_result"] = True
            cython_args["compiler_directives"]["warn.multiple_declarators"] = True
        else:
            cython_args["compiler_directives"]["boundscheck"] = False
            cython_args["compiler_directives"]["wraparound"] = False

        # check if we can build platform-specific code
        if self.target_cpu == "x86":
            if not self._simd_disabled["AVX2"] and self._check_avx2():
                cython_args["compile_time_env"]["AVX2_BUILD_SUPPORT"] = True
                self._simd_supported["AVX2"] = True
                self._simd_flags["AVX2"].extend(self._avx2_flags())
                self._simd_defines["AVX2"].append(("__AVX2__", 1))
            if not self._simd_disabled["SSE2"] and self._check_sse2():
                cython_args["compile_time_env"]["SSE2_BUILD_SUPPORT"] = True
                self._simd_supported["SSE2"] = True
                self._simd_flags["SSE2"].extend(self._sse2_flags())
                self._simd_defines["SSE2"].append(("__SSE2__", 1))
            if not self._simd_disabled["MMX"] and self._check_mmx():
                cython_args["compile_time_env"]["MMX_BUILD_SUPPORT"] = True
                self._simd_supported["MMX"] = True
                self._simd_flags["MMX"].extend(self._mmx_flags())
                self._simd_defines["MMX"].append(("__MMX__", 1))
        elif self.target_cpu == "arm" or self.target_cpu == "aarch64":
            if not self._simd_disabled["NEON"] and self._check_neon():
                cython_args["compile_time_env"]["NEON_BUILD_SUPPORT"] = True
                self._simd_supported["NEON"] = True
                self._simd_flags["NEON"].extend(self._neon_flags())
                self._simd_defines["NEON"].append(("__ARM_NEON__", 1))

        # cythonize the extensions (retaining platform-specific sources)
        platform_sources = [ext.platform_sources for ext in self.extensions]
        self.extensions = cythonize(self.extensions, **cython_args)
        for ext, plat_src in zip(self.extensions, platform_sources):
            ext.platform_sources = plat_src

        # build the extensions as normal
        _build_ext.build_extensions(self)


class build_clib(_build_clib):
    """A custom `build_clib` that splits the `training.c` file from Prodigal.
    """

    # --- Compatibility with `setuptools.Command`

    user_options = _build_clib.user_options + [
        ("parallel", "j", "number of parallel build jobs"),
    ]

    def initialize_options(self):
        _build_clib.initialize_options(self)
        self.parallel = None
        self.target_machine = None
        self.target_system = None
        self.target_cpu = None

    def finalize_options(self):
        _build_clib.finalize_options(self)
        if self.parallel is not None:
            self.parallel = int(self.parallel)
        # detect platform options
        self.target_machine = _detect_target_machine(self.plat_name)
        self.target_system = _detect_target_system(self.plat_name)
        self.target_cpu = _detect_target_cpu(self.plat_name)

    # --- Autotools-like helpers ---

    def _check_function(self, funcname, header, args="()"):
        _eprint('checking whether function', repr(funcname), 'is available', end="... ")

        base = "have_{}".format(funcname)
        testfile = os.path.join(self.build_temp, "{}.c".format(base))
        binfile = self.compiler.executable_filename(base, output_dir=self.build_temp)
        objects = []

        with open(testfile, "w") as f:
            f.write("""
                #include <{}>
                int main(int argc, char *argv[]) {{
                    {}{};
                    return 0;
                }}
            """.format(header, funcname, args))
        try:
            objects = self.compiler.compile([testfile], debug=self.debug)
            self.compiler.link_executable(objects, base, output_dir=self.build_temp)
        except CompileError:
            _eprint("no")
            return False
        else:
            _eprint("yes")
            return True
        finally:
            os.remove(testfile)
            for obj in filter(os.path.isfile, objects):
                os.remove(obj)
            if os.path.isfile(binfile):
                os.remove(binfile)

    # --- Compatibility with base `build_clib` command ---

    def check_library_list(self, libraries):
        pass

    def get_library_names(self):
        return [ lib.name for lib in self.libraries ]

    def get_source_files(self):
        return [ source for lib in self.libraries for source in lib.sources ]

    def get_library(self, name):
        return next(lib for lib in self.libraries if lib.name == name)

    # --- Compatibility with `setuptools.Command`

    def finalize_options(self):
        _build_clib.finalize_options(self)
        # extract the training file and the temporary folder where to split
        # the training profiles
        lib = self.libraries[0]
        self.training_file = next(s for s in lib.sources if os.path.basename(s) == "training.c")
        self.training_temp = os.path.join(self.build_temp, "training")

    # --- Build code ---

    def _write_source_split(self, training_temp, index, lines):
        filename = os.path.join(training_temp, "training{:02}.c".format(index))
        with open(filename, "wb") as dst:
            if index != 0:
                dst.write(b'#include "training.h"\n')
            dst.writelines(lines)
        lines.clear()

    def _split_training_source(self, training_file, training_temp):
        self.mkpath(training_temp)
        with open(training_file, "rb") as src:
            lines = []
            index = 0
            for line in src:
                if line.startswith(b"void initialize_metagenome"):
                    self._write_source_split(training_temp, index, lines)
                    index += 1
                if line.lstrip().startswith(b"struct _training"):
                    line = line.replace(b"struct _training", b"static const struct _training")
                lines.append(line)
            self._write_source_split(training_temp, index, lines)

    def build_libraries(self, libraries):
        # split the huge `training.c` file in small chunks with individual
        # functions so that it can compile even on low-memory machines
        self.make_file(
            [self.training_file],
            self.training_temp,
            self._split_training_source,
            (self.training_file, self.training_temp)
        )

        # detect if a custom file needs to be included for `cpu_features`
        impl_path = os.path.join(
            "vendor", 
            "cpu_features", 
            "src", 
            "impl_{}_{}.c".format(self.target_cpu, self.target_system)
        )
        if os.path.exists(impl_path):
            self.get_library("cpu_features").sources.append(impl_path)

        # check for functions required for libcpu_features on OSX
        if self.target_system == "macos":
            _patch_osx_compiler(self.compiler, self.target_machine)
            if self._check_function("sysctlbyname", "sys/sysctl.h", args="(NULL, NULL, 0, NULL, 0)"):
                self.compiler.define_macro("HAVE_SYSCTLBYNAME", 1)

        # build each library only if the sources are outdated
        self.mkpath(self.build_clib)
        for library in libraries:
            libname = self.compiler.library_filename(library.name, output_dir=self.build_clib)
            self.make_file(library.sources, libname, self.build_library, (library,))

    def build_library(self, library):
        # show the compiler being used
        _eprint("building", library.name, "for", self.plat_name, "with", self.compiler.compiler_type, "compiler")

        # add debug flags if we are building in debug mode
        if self.debug:
            if self.compiler.compiler_type in {"unix", "cygwin", "mingw32"}:
                library.extra_compile_args.append("-g")
            elif self.compiler.compiler_type == "msvc":
                library.extra_compile_args.append("/Z7")

        # store compile args
        compile_args = (
            self.build_temp,
            library.define_macros,
            library.include_dirs,
            self.debug,
            library.extra_compile_args,
            None,
            library.depends,
        )

        # manually prepare sources and get the names of object files
        sources = library.sources.copy()
        if library.name == "prodigal":
            sources.remove(self.training_file)
            sources.extend(sorted(glob.iglob(os.path.join(self.training_temp, "*.c"))))
        objects = [
            os.path.join(self.build_temp, s.replace(".c", self.compiler.obj_extension))
            for s in sources
        ]

        # compile outdated files in parallel
        with multiprocessing.pool.ThreadPool(self.parallel) as pool:
            pool.starmap(
                functools.partial(self._compile_file, compile_args=compile_args),
                zip(sources, objects)
            )

        # link into a static library
        libfile = self.compiler.library_filename(
            library.name,
            output_dir=self.build_clib,
        )
        self.make_file(
            objects,
            libfile,
            self.compiler.create_static_lib,
            (objects, library.name, self.build_clib, None, self.debug)
        )

    def _compile_file(self, source, object, compile_args):
        self.make_file(
            [source],
            object,
            self.compiler.compile,
            ([source], *compile_args)
        )


class clean(_clean):
    """A `clean` that removes intermediate files created by Cython.
    """

    def run(self):

        source_dir = os.path.join(os.path.dirname(__file__), "pyrodigal")

        patterns = ["*.html"]
        if self.all:
            patterns.extend(["*.so", "*.c"])

        for pattern in patterns:
            for file in glob.glob(os.path.join(source_dir, pattern)):
                log.info("removing {!r}".format(file))
                os.remove(file)

        _clean.run(self)

# --- Setup ---------------------------------------------------------------------

setuptools.setup(
    libraries=[
        Library(
            "prodigal",
            sources=[
                os.path.join("vendor", "Prodigal", "{}.c".format(base))
                for base in [
                    "bitmap",
                    "dprog",
                    "gene",
                    "metagenomic",
                    "node",
                    "sequence",
                    "training"
                ]
            ],
            include_dirs=[os.path.join("vendor", "Prodigal")]
        ),
        Library(
            "cpu_features",
            sources=list(filter(os.path.exists, [
                os.path.join("vendor", "cpu_features", "src", "{}.c".format(base))
                for base in ["filesystem", "stack_line_reader", "string_view"]
            ])),
            include_dirs=[os.path.join("vendor", "cpu_features", "include")],
            define_macros=[("STACK_LINE_READER_BUFFER_SIZE", 1024)]
        ),
    ],
    ext_modules=[
        Extension(
            "pyrodigal._pyrodigal",
            sources=[
                "pyrodigal/_pyrodigal.pyx",
                "pyrodigal/impl/generic.c"
            ],
            platform_sources={
                "AVX2": ["pyrodigal/impl/avx.c"],
                "NEON": ["pyrodigal/impl/neon.c"],
                "SSE2": ["pyrodigal/impl/sse.c"],
                "MMX": ["pyrodigal/impl/mmx.c"],
            },
            include_dirs=[
                "pyrodigal",
                os.path.join("vendor", "Prodigal"),
                os.path.join("vendor", "cpu_features", "include"),
            ],
            libraries=[
                "prodigal",
                "cpu_features",
            ],
        ),
    ],
    cmdclass={
        "sdist": sdist,
        "build_ext": build_ext,
        "build_clib": build_clib,
        "clean": clean
    }
)
