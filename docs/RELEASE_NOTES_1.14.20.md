# Termatica 1.14.20

Termatica 1.14.20 fixes update installation failures caused by an incorrectly packaged ad-hoc signature in 1.14.19.

## Update signature fix

- Public ZIP and DMG packages are again signed with the stable Termatica Release Signing certificate.
- The built-in updater's pinned designated requirement now validates the downloaded application successfully.
- Users who saw `termatica update: signature verification failed: codesign exited with status 3` can rerun `t u`; no configuration changes or manual cleanup are required.

## Release protection

- `make package` now selects the pinned release identity instead of inheriting the development ad-hoc signature.
- Packaging verifies the certificate fingerprint and bundle identifier before creating the ZIP, DMG, and checksum assets.
- Local development builds can remain ad-hoc signed, while production packaging fails closed if the release identity is unavailable.

## Compatibility

The release remains a universal macOS 13+ application with native x86_64 and arm64 slices. The full updater test, signature requirement check, architecture verification, and package checksum validation passed before publication.
