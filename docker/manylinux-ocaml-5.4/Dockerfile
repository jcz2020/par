FROM quay.io/pypa/manylinux_2_28_x86_64:latest

LABEL org.opencontainers.image.title="par-manylinux-ocaml-5.4"
LABEL org.opencontainers.image.description="Build environment for par_runtime manylinux_2_28_x86_64 wheels"
LABEL org.opencontainers.image.source="https://github.com/jcz2020/par"

# AlmaLinux 8 userland with GCC 14, glibc 2.28, auditwheel, patchelf.
# We add OCaml 5.4 + PAR's system deps (GMP, sqlite).

# --- System dependencies ----------------------------------------------------
# gmp-devel: libgmp.so.10 (par_capi.so hard dep)
# sqlite-devel: libsqlite3.so.0 (par_capi.so hard dep via sqlite3-ocaml)
# python3-devel: needed for manylinux' pypa-provided Python headers
# xz-devel, openssl-devel: transitive deps for opam-installed packages
RUN dnf install -y \
        gmp-devel \
        sqlite-devel \
        python3-devel \
        xz-devel \
        openssl-devel \
        make \
        git \
    && dnf clean all

# --- opam binary ------------------------------------------------------------
# manylinux_2_28 does not ship opam. Install the prebuilt binary.
ARG OPAM_VERSION=2.4.1
RUN curl -fsSL -o /usr/local/bin/opam \
        "https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/opam-${OPAM_VERSION}-x86_64-linux" \
    && chmod 755 /usr/local/bin/opam \
    && opam init --disable-sandboxing --bare -y

# --- OCaml 5.4.0 compiler ---------------------------------------------------
# Compiles from source via opam. ~5-8 min on cold cache.
# This is a layer that will be cached across builds.
RUN opam switch create par 5.4.0 -y \
    && eval $(opam env --switch=par) \
    && opam install -y dune

# Default shell when running the image: OCaml env pre-loaded
ENV OPAM_SWITCH=par
ENV PATH=/root/.opam/par/bin:${PATH}
ENV OCAMLLIB=/root/.opam/par/lib/ocaml
