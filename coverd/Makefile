# Type Cover fold helper. `make` builds the daemon, `make check` runs the
# tests. Installing is done by ../install.sh --with-fold-helper.
CC ?= cc
HARDEN := -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fstack-clash-protection \
	-fPIE $(shell $(CC) -fcf-protection -E -x c /dev/null >/dev/null 2>&1 && echo -fcf-protection)
WARN := -Wall -Wextra -Werror -Wformat=2 -Wformat-security -Wshadow -Wconversion \
	-Wno-sign-conversion -Wstrict-prototypes -Wmissing-prototypes -Wvla
CFLAGS := -std=c11 -O2 -g $(WARN) $(HARDEN)
LDFLAGS := -pie -Wl,-z,relro,-z,now,-z,noexecstack

all: gimbal-sp4-coverd

gimbal-sp4-coverd: gimbal-sp4-coverd.c coverd.c coverd.h
	$(CC) $(CFLAGS) -o $@ gimbal-sp4-coverd.c coverd.c $(LDFLAGS)

test_coverd: test_coverd.c coverd.c coverd.h
	$(CC) $(CFLAGS) -o $@ test_coverd.c coverd.c $(LDFLAGS)

check: gimbal-sp4-coverd test_coverd
	./test_coverd testdata/typecover-045e-07e8.rdesc

clean:
	rm -f gimbal-sp4-coverd test_coverd

.PHONY: all check clean
