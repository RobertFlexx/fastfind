#!/bin/sh
set -eu
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/opt/tribblix/bin:$PATH"
case "${1:?platform required}" in
  dragonflybsd) pkg install -y gcc gmake ;;
  solaris|omnios|openindiana|netbsd) : ;; # Images include a compiler and make.
  tribblix)
    zap install TRIBv-gcc14 TRIBdev-build-gnu-make TRIBsys-header \
      TRIBdev-linker TRIBdev-gnu-binutils TRIBdev-object-file TRIBsys-lib-c-runtime
    ;;
  linux) : ;; # Used to validate the native C pipeline locally.
  *) echo 'unsupported native platform' >&2; exit 2 ;;
esac
