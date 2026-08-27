#!/usr/bin/env fsh

# Generate build/relibc-doc and build/relibc-doc.tar.gz.

^rm -rf build/relibc-doc build/relibc-doc.tar.gz
^make ri.relibc-doc DESTDIR=./build/relibc-doc
^tar -czvf ./build/relibc-doc.tar.gz ./build/relibc-doc/usr/share/doc/relibc/ || exit
exit 0
