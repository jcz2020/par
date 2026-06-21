"""setup.py - conditional C extension build for auditwheel linkage.

The extension is built only when par_capi.so is present at par_runtime/lib/.
Pure-Python source installs (no .so) skip it. This keeps `pip install` from
an sdist working on machines without OCaml.

For the wheel build, use `pip wheel . --no-build-isolation` so the build
runs in-place and can locate the just-built par_capi.so. PEP 517 isolated
builds copy the source tree to a temp dir and miss gitignored artifacts
like par_capi.so.
"""
import os
from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext


def _has_capi():
    here = Path(__file__).resolve().parent
    return (here / "par_runtime" / "lib" / "par_capi.so").exists()


class _skip_when_no_capi(build_ext):
    def run(self):
        if not self.extensions:
            return
        super().run()


setup_kwargs = {}

if _has_capi() and os.environ.get("PAR_SKIP_LOADER") != "1":
    setup_kwargs["ext_modules"] = [
        Extension(
            name="par_runtime._loader",
            sources=["par_runtime/_loader.c"],
            # -l:PAR_capi.so (with colon) tells ld to use the exact filename
            # rather than auto-prepending 'lib'. par_capi.so lacks the lib
            # prefix by OCaml convention.
            extra_link_args=[
                "-Lpar_runtime/lib",
                "-l:par_capi.so",
                "-Wl,-rpath,$ORIGIN",
            ],
        )
    ]
    setup_kwargs["cmdclass"] = {"build_ext": _skip_when_no_capi}


setup(**setup_kwargs)
