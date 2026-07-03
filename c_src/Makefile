# Builds priv/xet_nif.so. Driven by the rebar3 pre_hooks in rebar.config.

BASEDIR := $(abspath $(CURDIR)/..)
PRIV ?= $(BASEDIR)/priv
NIF := $(PRIV)/xet_nif.so

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

CC ?= cc
CFLAGS ?= -O3
CFLAGS += -std=c11 -fPIC -Wall -Wextra -I$(ERTS_INCLUDE_DIR) -I$(CURDIR)/blake3

ifeq ($(UNAME_S),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

SRCS := xet_nif.c \
	xet_blake3.c \
	xet_lz4.c \
	xet_gearhash.c \
	blake3/blake3.c \
	blake3/blake3_dispatch.c \
	blake3/blake3_portable.c \
	lz4/lz4.c \
	lz4/lz4hc.c \
	lz4/lz4frame.c \
	lz4/xxhash.c

ifneq (,$(filter $(UNAME_M),arm64 aarch64))
SRCS += blake3/blake3_neon.c
CFLAGS += -DBLAKE3_USE_NEON=1
else ifneq (,$(filter $(UNAME_M),x86_64 amd64))
SRCS += blake3/blake3_sse2.c blake3/blake3_sse41.c blake3/blake3_avx2.c blake3/blake3_avx512.c
else
CFLAGS += -DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512
endif

# Vendored sources: keep our warning level, silence upstream-only noise.
blake3/%.o: CFLAGS += -Wno-unused-function
lz4/%.o: CFLAGS += -Wno-unused-function

CFLAGS += -I$(CURDIR)/lz4

blake3/blake3_sse2.o: CFLAGS += -msse2
blake3/blake3_sse41.o: CFLAGS += -msse4.1
blake3/blake3_avx2.o: CFLAGS += -mavx2
blake3/blake3_avx512.o: CFLAGS += -mavx512f -mavx512vl

OBJS := $(SRCS:.c=.o)

all: $(NIF)

$(NIF): $(OBJS)
	@mkdir -p $(PRIV)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(NIF)

.PHONY: all clean
