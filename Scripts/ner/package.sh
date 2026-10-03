#!/bin/bash
# Compile the exported model and pack what privmask installs into
# share/privmask/ner (#46). Run after Scripts/ner/export.py.
#
#   Scripts/ner/package.sh [version]     # version defaults to 1
#
# The tarball goes to a release of its own (ner-model-<version>), not to each
# privmask release: training runs here, not in CI.
set -euo pipefail
VERSION="${1:-1}"
EXPORT=.build/ner/export
rm -rf "$EXPORT/ner.mlmodelc"
xcrun coremlcompiler compile "$EXPORT/ner.mlpackage" "$EXPORT" >/dev/null
OUT=".build/ner/privmask-ner-${VERSION}.tar.gz"
# No ._ files or extended attributes in the tarball: Homebrew would install them.
COPYFILE_DISABLE=1 tar -czf "$OUT" --no-xattrs -C "$EXPORT" ner.mlmodelc tokenizer.json words.txt names.txt
du -h "$OUT"
shasum -a 256 "$OUT"
