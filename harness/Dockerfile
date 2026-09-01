# The emacs-harness image plus the one thing jsonyter's profile needs on
# top of it: the real `jsonyter' Python bridge.
#
# Almost every scenario runs against `eh-fake-bridge' and needs none of
# this (emacs-harness DESIGN 9.2).  The exceptions are the saves: a
# notebook is written by the bridge's own `write_notebook', so what a
# save produces is a file the *backend* wrote, and no fixture can stand
# in for it.  Those scenarios are gated on `:needs (:executable
# "jsonyter")' and skip legibly in an image without this layer.
#
# The Python package handles .ipynb locally, so this starts no kernel and
# needs no Jupyter server.
#
# Build with the emacs-harness image as the base:
#
#   docker build -t emacs-harness:ci -f <harness>/container/Dockerfile <harness>
#   docker build -t jsonyter-harness --build-arg BASE=emacs-harness:ci harness

ARG BASE=emacs-harness:dev
FROM ${BASE}

# Pinned: an unpinned bridge means a jsonyter.el CI run can go red
# because somebody else released, which is a failure that teaches
# nothing and blocks a pull request that changed none of it.
ARG JSONYTER_VERSION=1.0.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip \
    && pip3 install --no-cache-dir --break-system-packages \
         "jsonyter==${JSONYTER_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Fail the build rather than the suite: without this, a bad version pin
# or a pip that quietly installed nothing shows up much later as every
# save scenario reporting `skipped', which reads like a deliberate
# choice rather than a broken image.
RUN jsonyter --help >/dev/null
