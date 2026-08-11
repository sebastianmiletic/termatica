#!/bin/zsh
/Applications/kitty.app/Contents/MacOS/kitten __benchmark__ --render --repetitions 3 ascii unicode unique_unicode csi images long_escape_codes > '/Users/sebastianmiletic/Coding/Termatica/benchmarks/2026-08-11-v1.9.0-matrix/ghostty-render.txt' 2>&1; exit
