# zlib header fixtures

Unmodified `zlib.h` and `zconf.h` from zlib **1.3.1**, upstream tag `v1.3.1`:

- https://github.com/madler/zlib/blob/v1.3.1/zlib.h
- https://github.com/madler/zlib/blob/v1.3.1/zconf.h

Copyright and the zlib license are preserved in the headers. These files are
third-party fixtures, not MoonBind implementation code.

The native integration check generates bindings from these headers and calls
`adler32` in the system zlib library. CI installs `zlib1g-dev` for that purpose.

Generation uses `Z_SOLO=1`, zlib's standalone header configuration, so the
parser does not need host-specific POSIX headers. The selected `adler32`
declaration has the same ABI in the system zlib library. This test covers
that checksum interface, not zlib's filesystem APIs or every configuration.
