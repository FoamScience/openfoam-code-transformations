# Unattended transformations of OpenFOAM code

This repository showcases how `tree-sitter` can be used to perform some code transformation
tasks on OpenFOAM code base efficiently.

## Idea

I need to make the code compliant with C++20 standard; in particular, we're not allowed to
supply template arguments for class template constructors anymore:
```cpp
template<class T>
class A {
    A<T>(); // will not compile with g++ when c++20 stdlib is linked
}
```

## So, AWK?

To identify all the places where this happens, awk can(?) be sufficient:
```bash
find /usr/lib/openfoam/openfoam2312/src/ \
    -not -path "*/lnInclude/*" \
    -name "*.H" \
    -exec awk '/^\s*class [[:alpha:]]*/{cl=$2;} cl != "" && cl != "|"  && match($0, "^\\s*" cl "<.*>\\s*\\(") {print $0 " // ----- " cl}' {} \;
```

Which will report the following (a similar query for destructors can be constructed too):
```cpp
DiagonalMatrix<Type>(const label n, const Foam::zero); // ----- DiagonalMatrix
DiagonalMatrix<Type>(const label n, const Type& val); // ----- DiagonalMatrix
DiagonalMatrix<Type>(const Matrix<Form, Type>& mat); // ----- DiagonalMatrix
Compound<T>(const Compound<T>&) = delete; // ----- Compound
    UIndirectList<T>(list.values(), list.addressing()) // ----- UIndirectList
```

Notice that the last one (`UIndirectList` line) must not be considered, because
it's not a constructor declaration but we cannot differentiate it just with regular expressions!

> [!WARNING]
> Following compiler errors obviously works better, but I'm not sure I'm ready to sit through
> OpenFOAM compiling from scratch while the **recompilation is not actually necessary**.

## A more reliable approach

It's always better to parse the code's AST rather than relying on single-line regular expressions
(and not having to care about comments for example).

### Pre-requisites

We need to install `tree-sitter` and `tree-sitter-cpp` to parse C++ code, we need NodeJS for this.
And we also need to install `tree-sitter-graph` to easily process the AST through queries (which is a Rust project):
```bash
npm install -g tree-sitter-cli tree-sitter-cpp
cargo install --features cli tree-sitter-graph
```

Then point tree-sitter to your node_modules folder so it can find the parsers
in `~/.config/tree-sitter/config.json`:
```json
{
    "parser-directories": [
        "/home/<user>/node_modules"
    ]
}
```

### AST queries

We want to cover three cases:
- Constructors with template arguments
- Copy and Move constructors with template arguments
- Destructors with template arguments

With the `tree-sitter-cpp` package, writing queries for the first two cases is easy. We just look
for declarations inside class template declarations that look like constructors (no return type):
```
;; extracting constructors which have template arguments
(template_declaration 
    parameters: (template_parameter_list)
    (class_specifier 
      name: (_) @name
      body: (field_declaration_list 
        (_)*
        (declaration 
          declarator: (function_declarator 
            declarator: (template_function 
              name: (identifier) @ctorname
              arguments: (template_argument_list) @args)
            parameters: (parameter_list) @params) @ctor)
))) {
    node @ctor.node
    attr (@ctor.node) ctor = (format "{}{}{}" (source-text @ctorname) (source-text @args) (source-text @params))
    attr (@ctor.node) classname = (source-text @name)
    attr (@ctor.node) line = (plus 1 (start-row @args))
    attr (@ctor.node) col = (plus 1 (start-column @args))
}
```
Running `tree-sitter-graph` with this query will return something like:
```
node 0
  classname: "DiagonalMatrix"
  col: 32
  ctor: "DiagonalMatrix<Type>(const label n)"
  line: 86
node 1
  classname: "DiagonalMatrix"
  col: 23
  ctor: "DiagonalMatrix<Type>(const label n, const Foam::zero)"
  line: 89
node 2
  classname: "DiagonalMatrix"
  col: 23
  ctor: "DiagonalMatrix<Type>(const label n, const Type& val)"
  line: 92
```
we can then process this to produce a QuickFix list pointing to where the not-needed arguments are.

For destructors it's a bit different as `tree-sitter-cpp` cannot actually parse declarations that look like:
```cpp
template<class Type>
class A{
    ~A<Type>();
};
```
But it provides us with an Error node that we can use to identify the destructor:
```
;; extracting destructors with template arguments
(ERROR
    (virtual)?
    (destructor_name (_)@ctorname)
    (_)*
) @ctor {
    node @ctor.node
    attr (@ctor.node) ctor = (source-text @ctor)
    attr (@ctor.node) classname = (source-text @ctorname)
    attr (@ctor.node) line = (plus 1 (start-row @ctorname))
    attr (@ctor.node) col = (plus 1 (end-column @ctorname))
}
```
Note that most OpenFOAM files will not be parsed correctly since the lines `TypeName("className");`
make no sense to `tree-sitter-cpp` but tree-sitter is fail-tolerant and we can still continue parsing past that point.

I usually like to send `tree-sitter-graph` output to awk so I can produce a (Vim)
QuickFix list with filenames, line numbers and columns ready to apply the changes.
```bash
./parse_openfoam_files.sh $FOAM_SRC # May take some time, produces ctors and quickfix files
vim +'cfile quickfix' # Open the quickfix list
# now inside vim
(vim)> :cdo! norm da<           # watch the magic happen, with confidence
(vim)> :cdo! norm w             # write the changed files
# done
```

Look at [`parse_openfoam_files.sh`](parse_openfoam_files.sh) for inspiration.

### Benefits?

- May not be huge in this particular case since it's only around 10 changes
- But you can imagine how porting code can become a breeze
