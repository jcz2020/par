/* _loader.c - Auditwheel linkage shim for par_capi.so's DT_NEEDED graph.
 *
 * Why this file exists:
 *   par_runtime is a pure-Python package that loads par_capi.so via ctypes.
 *   auditwheel's dependency scanner only follows DT_NEEDED entries from
 *   CPython extension modules — it does NOT inspect libraries loaded via
 *   ctypes.CDLL (pypa/auditwheel#197). Without this shim, auditwheel
 *   produces wheels missing GMP and sqlite3.
 *
 * How it works:
 *   The shim is a real CPython extension module that links against
 *   par_capi.so at build time, producing a DT_NEEDED entry. auditwheel
 *   then sees: par_runtime._loader -> par_capi -> libgmp, libsqlite3.
 *
 * The exposed function `probe()` calls par_health() to prevent the linker
 * from discarding the par_capi reference as dead code.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

extern void par_health(void);

static PyObject*
par_loader_probe(PyObject* self, PyObject* args) {
    (void)self; (void)args;
    par_health();
    return PyLong_FromLong(0);
}

static PyMethodDef methods[] = {
    {"probe", par_loader_probe, METH_NOARGS,
     "Internal auditwheel linkage probe. Do not call from user code."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    "_loader",
    "Internal auditwheel linkage shim.",
    -1,
    methods
};

PyMODINIT_FUNC
PyInit__loader(void) {
    return PyModule_Create(&module_def);
}
