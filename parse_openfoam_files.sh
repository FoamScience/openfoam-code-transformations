#!/usr/bin/bash

echo "" > quickfix
echo "" > ctors
function parse_ctors() {
    out=$(tree-sitter-graph --allow-parse-errors ctorTemplateArgs.tsg $1 --scope "source.cpp" 2> /dev/null)
    if [[ -n $out ]]; then
        echo "$out" | \
            awk '/col:/ {col=$2} /ctor:/ {ctor=""; for(i=2;i<=NF;i++)ctor = ctor " "  $i} /line:/ {line=$2; print file ":" line ":" col ":" ctor}' \
            file="$1" | \
            sort -k 2,2 -t':'
        echo "filename: $1" >> ctors
        echo "$out" >> ctors
    else
        echo "did not find any ctors with template args in $1" >&2
    fi
}
export -f parse_ctors
find "$1" -not -path "*/lnInclude/*" -name "*.H" -exec bash -c 'parse_ctors "$0"' {} \; | tee quickfix
