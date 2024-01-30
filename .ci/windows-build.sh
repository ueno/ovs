#!/bin/bash
set -ev

export PATH="/c/Python37;$PATH"

CONFIGURATION=$1

cd /c/openvswitch_compile

./boot.sh
./configure CC=build-aux/cccl LD="$(which link)" \
    LIBS="-lws2_32 -lShlwapi -liphlpapi -lwbemuuid -lole32 -loleaut32" \
    --prefix=C:/openvswitch/usr --localstatedir=C:/openvswitch/var \
    --sysconfdir=C:/openvswitch/etc --with-pthread=c:/PTHREADS-BUILT/ \
    --enable-ssl --with-openssl=C:/OpenSSL-Win64 \
    --with-vstudiotarget="${CONFIGURATION}"

make -j 4
make datapath_windows_analyze
make install
make windows_installer
