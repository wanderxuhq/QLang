# QLang

A dynamically-typed programming language written in Rust, featuring self-hosting capability.

## Features

- **Dynamic typing with optional annotations** - No type declarations required; `let x: Number = 42` annotations are runtime-checked (types are first-class values, see [Type System](#type-system))
- **First-class functions** - Functions are first-class citizens with closures
- **Lexical scoping** - Proper variable scoping with closures
- **Rich standard library** - Math, String, Array, Object, JSON, and more
- **Tree-walk interpreter** - Easy to understand and modify
- **Self-hosted** - Can interpret QLang code written in QLang

## Installation

```bash
cargo build --release
```

The executable will be at `target/release/qlang`.

## Usage

```bash
cargo run -- example.ql
```

Or after building:

```bash
./target/release/qlang example.ql
```

## Language Syntax

### Comments

Single-line comments start with `//`:

```qlang
// This is a comment
let x = 42  // Inline comment
```

### Identifiers

Identifiers start with a letter or underscore, followed by letters, digits, or underscores:

```qlang
let name = "Alice"
let _private = 123
let myVar123 = true
```

### Keywords

Reserved words that cannot be used as identifiers:

```
let, if, else, while, return, import, export, true, false, null
```

### Variables and Values

Variables are declared with `let` and are immutable by default:

```qlang
let x = 42              // Number
let name = "Alice"      // String
let flag = true         // Boolean
let empty = null        // Null (absence of value)
```

Reassignment is possible for existing variables:

```qlang
let x = 42
x = 100  // Reassign to new value
```

Type annotations are optional and checked at runtime when they appear —
declaration, call entry, and reassignment. See [Type System](#type-system).

### Data Types

#### Numbers

All numbers are f64 (64-bit floating point):

```qlang
let n = 3.14
let integer = 42
let negative = -10
let scientific = 1.5e-10
let hex = 0xff          // 255 (parsed as decimal, hex is just notation)
let infinity = Infinity // predefined global (shadowable)
let nan_val = std.Number.isNaN(NaN)   // true
```

Number literals can be:
- Integers: `42`, `-10`, `0`
- Decimals: `3.14`, `-0.5`
- Scientific: `1.5e10`, `2e-5`

#### Strings

Strings are enclosed in double or single quotes:

```qlang
let s = "Hello, World!"
let single = 'Single quotes also work'
let empty = ""
let with_quote = "He said, \"Hello!\""
let with_newline = "Line 1\nLine 2"
let with_tab = "Col1\tCol2"
```

Escape sequences:
- `\n` - Newline
- `\t` - Tab
- `\r` - Carriage return
- `\\` - Backslash
- `\"` - Double quote
- `\'` - Single quote

String concatenation uses `+`:

```qlang
let greeting = "Hello" + ", " + "World!"  // "Hello, World!"
```

#### Booleans

```qlang
let yes = true
let no = false
```

#### Arrays

Arrays are ordered lists of values:

```qlang
let arr = [1, 2, 3, 4, 5]
let mixed = [1, "two", true, null]
let nested = [[1, 2], [3, 4]]
let empty = []
```

#### Objects

Objects are key-value maps (JSON5 style). Use `:` to set fields, and `,` to separate fields:

```qlang
let person = { name: "Alice", age: 30 }
let empty = {}
let nested = { outer: { inner: "value" } }
let with_spaces = { name: "Bob", age: 25 };
```

> **Note:** the old `{ key = value }` syntax was removed in favor of JSON5's `key: value`. Keys may be identifiers, keywords, quoted strings, or numbers; trailing commas are allowed; `{ name }` shorthand (QLang extension) still works. `{ x: Number }` means field `x` with the *value* of variable `Number` — which, since the type-system round, is the `Number` type object.

Object field access uses dot notation:

```qlang
let name = person.name      // "Alice"
person.age = 31             // Update field
```

#### Null

`null` is the **single empty value** — type `Null`, value `null`. There is no
separate `void`: a function without a return statement yields `null`, and
`std.Type.of(null)` returns the `Null` type value. The empty block expression
`{}` also evaluates to `null`. `Null` is the unit type (its only value is
`null`) — not the bottom type (`Never`), which is reserved for functions that
never return (e.g. `exit`).

```qlang
let nothing = null
let alsoNothing = () -> { 1; }  // empty return → null
```

`??` only falls back on **error values** — a `null` left operand passes through
untouched (`null ?? 42` is `null`, not `42`). There is no null-coalescing:
`null` is a legitimate value, and failure is represented by error values, not
by `null`.

### Operators

#### Arithmetic Operators

```qlang
let sum = 1 + 2        // Addition: 3
let diff = 5 - 3       // Subtraction: 2
let prod = 4 * 2       // Multiplication: 8
let quot = 10 / 4      // Division: 2.5
let rem = 7 % 3        // Modulo: 1
let neg = -x           // Negation (unary)
```

All arithmetic operations on numbers return a number. Operations on strings with `+` concatenate.

#### Comparison Operators

```qlang
let eq = 1 == 1        // Equal: true
let ne = 1 != 2        // Not equal: true
let lt = 1 < 2         // Less than: true
let le = 1 <= 2        // Less than or equal: true
let gt = 2 > 1         // Greater than: true
let ge = 2 >= 1        // Greater than or equal: true
```

Comparison operators return booleans.

#### Logical Operators

```qlang
let and = true && false   // Logical AND: false
let or = true || false    // Logical OR: true
let not = !true           // Logical NOT: false
```

Short-circuit evaluation: `&&` returns the first falsy value, `||` returns the first truthy value.

#### Bitwise Operators

```qlang
let band = 5 & 3          // Bitwise AND: 1 (0101 & 0011 = 0001)
let bor = 5 | 3           // Bitwise OR: 7 (0101 | 0011 = 0111)
let bxor = 5 ^ 3          // Bitwise XOR: 6 (0101 ^ 0011 = 0110)
```

#### Propagation and Fallback Operators

`?` (postfix propagate) and `??` (binary fallback) handle error values — the
core of QLang's error-value semantics. See [Error values](#error-values) for
the full model, rules, and examples.

### Blocks and Scope

Code blocks are enclosed in `{}` and create a new scope:

```qlang
let outer = 1;
{
    let inner = 2;
    println(outer);   // 1 (can access outer)
    println(inner);   // 2
};
// println(inner);   // Error: inner is not defined
```

### Functions

#### Function Definition

Functions are defined with `->` (arrow):

```qlang
// Single parameter without parentheses
let addOne = x -> x + 1

// Multiple parameters (require parentheses)
let add = (a, b) -> a + b

// Three parameters
let sum = (a, b, c) -> a + b + c

// No parameters
let getFive = () -> 5

// Multi-statement body (requires block)
let greet = (name) -> {
    let message = "Hello, " + name;
    return message;
}
```

#### Function Call

```qlang
let result = add(1, 2)           // 3
let doubled = addOne(5)          // 6
let five = getFive()             // 5
```

#### Curried Functions

Functions can return functions, enabling currying:

```qlang
let addN = (n) -> {
    let x = n;
    return (m) -> x + m;
};

let add5 = addN(5);
let result = add5(3);            // 8

// One-liner curried function
let multiply = (a) -> (b) -> a * b
let double = multiply(2);
double(5);                       // 10
```

#### Closures

Functions capture their environment:

```qlang
let makeCounter = () -> {
    let count = 0;
    return () -> {
        count = count + 1;
        return count;
    };
};

let counter = makeCounter();
counter();  // 1
counter();  // 2
counter();  // 3
```

### Control Flow

#### If Statement

The `if` statement executes code based on a condition. Use blocks `{ }` for code bodies:

```qlang
if condition {
    // code when true
};

if x > 0 {
    "positive"
} else if x < 0 {
    "negative"
} else {
    "zero"
};
```

**Important**: The entire if statement ends with a semicolon `;`.

The condition can be any expression. Truthy values are:
- Numbers other than 0
- Non-empty strings
- `true`
- Arrays and objects (always truthy)

Falsy values are:
- `0`, `-0`
- `""` (empty string)
- `false`
- `null`

#### While Loop

```qlang
let i = 0;
while i < 10 {
    println(i);
    i = i + 1;
}
```

#### Return Statement

Use `return` to exit a function early with a value:

```qlang
let abs = (n) -> {
    if n < 0 {
        return -n;
    }
    return n;
};

abs(-5);  // 5
abs(3);   // 3
```

### Assignment

Variables can be reassigned:

```qlang
let x = 42;
x = 100;  // Reassign
```

Assignment targets:
- Simple identifier: `x = 42`
- Member access: `obj.field = value`
- Index access: `arr[0] = value`

### Member and Index Access

```qlang
let obj = { name: "Alice", age: 30 };
println(obj.name);         // Member access: "Alice"

let arr = [10, 20, 30];
println(arr[0]);           // Index access (0-based): 10
arr[0] = 5;                // Index assignment
```

### Import and Export

#### Import

```qlang
// Import from another file (no quotes needed)
import ./utils.ql

// Import with path
import ./lib/math.ql
import ../shared/utils.ql
```

Imported modules are searched relative to the importing file.

#### Export

```qlang
// Export from a module
export { myFunction, myVariable }

// Export a single item
export { myFunction }
```

### Global Functions

```qlang
print("Hello")        // Print without newline
println("Hello")      // Print with newline
debug(value)          // Debug print with Rust debug format
input()               // Read line from stdin (returns string)
```

### Command-Line Arguments

Arguments after the script path are exposed as the global `args` array:

```bash
cargo run -- my_script.ql foo bar
```

```qlang
args.length     // 2
args[0]         // "foo"
args[1]         // "bar"
```

## Statement Terminators

Most statements end with a semicolon `;`:

```qlang
let x = 42;
println(x);
add(1, 2);
```

Blocks `{ }` do not need trailing semicolons within them, but the statement containing the block does:

```qlang
if condition {
    println("yes");
};  // Semicolon here

while i < 10 {
    i = i + 1;
};  // Semicolon here
```

## Object vs Block Syntax

QLang uses context to distinguish between object literals and code blocks:

**Object Literal** (in expression context, after `=`):
```qlang
let obj = { name: "Alice", age: 30 };
return { status: "ok" };
```

**Code Block** (after `if`, `while`, `->`):
```qlang
if x > 0 {
    println("positive");
};

let foo = () -> {
    let y = 1;
    return y;
};
```

## JSON5 Value Syntax

Value literals follow [JSON5](https://json5.org/), plus QLang extensions:

**Numbers** — hex, leading/trailing decimal points, exponents, signs, Infinity/NaN:
```qlang
let a = 0xFF;          // 255
let b = .5;            // 0.5
let c = 5.;            // 5.0
let d = 1e30;          // exponent
let e = +5;            // unary plus
let f = Infinity;      // predefined global (shadowable)
let g = -Infinity;     // via unary minus
let h = NaN;
```

**Strings** — single or double quotes, full JSON5 escapes:
```qlang
let s1 = "line1 \
line2";        // backslash line continuation
let s2 = "\x41B\u{43}";  // "ABC" (hex / 4-digit / codepoint escapes)
let s3 = '\u{1F600}';         // 😀 (single quotes too)
```
QLang extensions kept: `${...}` interpolation and `\$` `\{` `\}` escapes. Raw newlines inside strings, unknown escapes, and unterminated strings are errors.

**Objects** — `key: value` with identifier / keyword / quoted-string / number keys, trailing commas, and `{ name }` shorthand (extension):
```qlang
let o = { if: 1, "a b": 2, 0: 3, name, };
```

**Arrays** — trailing commas allowed: `[1, 2, 3,]`.

**Comments** — `//` and `/* ... */` are allowed anywhere (already supported).

The old `{ key = value }` object syntax and in-object type annotations (`{ x: Number }`) were removed — `{ x: Number }` now means field `x` with the *value* of variable `Number`.

## Standard Library

### Math Module

```qlang
std.Math.PI              // 3.141592653589793
std.Math.E               // 2.718281828459045

std.Math.sqrt(16)        // 4
std.Math.floor(4.7)      // 4
std.Math.ceil(4.2)       // 5
std.Math.round(4.5)      // 5
std.Math.trunc(4.7)      // 4
std.Math.abs(-42)        // 42
std.Math.pow(2)(3)       // 8 (curried: pow(2)(3) = 2^3)
std.Math.max(1, 2, 3)    // 3
std.Math.min(1, 2, 3)    // 1
std.Math.random()        // Random number in [0, 1)
std.Math.sin(0)          // 0 (radians)
std.Math.cos(0)          // 1
```

### Array Module

```qlang
let arr = [1, 2, 3, 4, 5]

// Query operations
std.Array.length(arr)                  // 5
std.Array.includes(arr)(3)             // true (curried)
std.Array.indexOf(arr)(4)              // 3 (first index of 4, -1 if not found)
std.Array.lastIndexOf(arr)(2)          // 1
std.Array.includes(arr)(10)            // false

// Modification (most return new arrays)
std.Array.push(arr)(6)                 // [1, 2, 3, 4, 5, 6]
std.Array.pop(arr)                     // [1, 2, 3, 4]
std.Array.shift(arr)                   // [2, 3, 4, 5]
std.Array.unshift(arr)(0)              // [0, 1, 2, 3, 4, 5]
std.Array.concat(arr)([6, 7])          // [1, 2, 3, 4, 5, 6, 7]
std.Array.slice(arr)(1, 3)             // [2, 3] (from index 1, up to but not including 3)
std.Array.reverse(arr)                 // [5, 4, 3, 2, 1]

// Index-based access
std.Array.get(arr)(0)                  // 1 (curried getter)
std.Array.set(arr)(0)(10)              // Set index 0 to 10

// Higher-order functions
std.Array.map(arr)(x -> x * 2)         // [2, 4, 6, 8, 10]
std.Array.filter(arr)(x -> x > 2)      // [3, 4, 5]
std.Array.reduce(arr)(0)((acc, x) -> acc + x)  // 15
std.Array.reduce(arr)(1)((acc, x) -> acc * x)  // 120
std.Array.find(arr)(x -> x > 3)        // 4 (first matching element)
std.Array.findIndex(arr)(x -> x > 3)   // 3 (first matching index)
std.Array.every(arr)(x -> x > 0)       // true (all match?)
std.Array.some(arr)(x -> x > 4)        // true (any match?)
std.Array.forEach(arr)(x -> println(x)) // Side effects
std.Array.includes(arr)(x -> x == 3)   // true (predicate form)
```

### String Module

```qlang
let s = "Hello, World!"
let empty = ""

// Query operations
std.String.length(s)                       // 13
std.String.includes(s)("World")            // true (curried)
std.String.indexOf(s)("World")             // 7 (position, -1 if not found)
std.String.lastIndexOf(s)("l")             // 10
std.String.startsWith(s)("Hello")          // true
std.String.endsWith(s)("!")                // true
std.String.charAt(s)(0)                    // "H"
std.String.codePointAt(s)(0)               // 72 (Unicode code point)
std.String.localeCompare("a")("b")         // -1 (a < b)
std.String.search(s)("[0-9]+")             // 11 (regex search)
std.String.match(s)("[a-z]+")              // ["ello"] (regex match)

// Transformation
std.String.toUpperCase(s)                  // "HELLO, WORLD!"
std.String.toLowerCase(s)                  // "hello, world!"
std.String.trim("  hello  ")               // "hello"
std.String.repeat(s)(2)                    // "Hello, World!Hello, World!"
std.String.padStart(s)(20)(" ")            // "       Hello, World!"
std.String.padEnd(s)(20)(" ")              // "Hello, World!       "
std.String.replace(s)("World")("QLang")    // "Hello, QLang!"
std.String.split("a,b,c")(",")             // ["a", "b", "c"]
std.String.substring(s)(0, 5)              // "Hello" (from, length)
std.String.substr(s)(7, 5)                 // "World" (start, length)
std.String.normalize(s)                    // NFC normalized form

// Conversion
std.String.toString(123)                   // "123"
std.String.fromCodePoint(72)               // "H"
```

### Object Module

```qlang
let obj = { name: "Alice", age: 30 }

// Query operations
std.Object.keys(obj)                       // ["name", "age"]
std.Object.values(obj)                     // ["Alice", 30]
std.Object.entries(obj)                    // [["name", "Alice"], ["age", 30]]
std.Object.get(obj)("name")                // "Alice" (curried)
std.Object.has(obj)("name")                // true
std.Object.hasOwn(obj)("name")             // true (own property only)
std.Object.propertyIsEnumerable(obj)("name") // true

// Modification (mutates in place)
std.Object.set(obj)("name")("Bob")         // Returns mutated obj
std.Object.delete(obj)("age")              // Returns mutated obj
std.Object.assign(obj)({ city: "NYC" })   // Merge objects, returns mutated obj

// Object behavior
std.Object.freeze(obj)                     // Make immutable
std.Object.seal(obj)                       // Prevent add/delete properties
std.Object.isFrozen(obj)                   // true
std.Object.isSealed(obj)                   // true
std.Object.is(obj1)(obj2)                 // false (reference equality)
std.Object.valueOf(obj)                    // obj itself

// Prototype operations
std.Object.create({ proto: "parent" })    // Create with prototype
std.Object.getPrototypeOf(obj)            // {} (default prototype)
std.Object.setPrototypeOf(obj)({ proto: "parent" })

// String representation
std.Object.toString(obj)                   // "[object Object]"
std.Object.toLocaleString(obj)            // "[object Object]"

let obj2 = { valueOf: () -> 42 };
std.Object.valueOf(obj2)                   // 42 (if valueOf defined)
```

### JSON Module

```qlang
let obj = {name: "Alice", age: 30, active: true}

// Serialize to JSON string
let json = std.JSON.stringify(obj)
// {"name":"Alice","age":30,"active":true}

// Parse JSON string
let parsed = std.JSON.parse(json)
// {name: "Alice", age: 30, active: true}
```

### Number Module

```qlang
std.Number.toString(123)                 // "123"
std.Number.isNaN(NaN)                    // true
std.Number.isFinite(1)                   // true
std.Number.parseFloat("3.14")            // 3.14
std.Number.parseFloat("not a number")    // NaN (a plain Number, not an error value)
```

## Type System

QLang's type system is **types as data** (an Idris-style foundation): a type
value is an ordinary object whose core field is `check` — a predicate deciding
"does `v` belong to this type?". Types participate in computation like any
other value (passed, stored, compared); there is no separate compile-time
phase. `let x: T = v` checks at declaration time, `(a: T) -> ...` checks at
call entry, and reassigning an annotated binding re-checks. A declaration
without an initializer (`let x;` / `let x: T;`) creates an **uninitialized**
binding: the first assignment initializes it, and assignment checks fire only
when an annotation is present. Unannotated code is fully dynamic with zero
overhead.

### Type values and `check`

- A type value is an object with a callable `check` field. The membership test
  is `T.check(v)` (mirroring `isError(v)`): `Number.check(42)` is `true`,
  `Number.check("a")` is `false`.
- A type value itself is **not callable** — `Number(42)` is an error
  (`Not callable`). The exceptions are the type **constructors** `Array` and
  `Object`, which are functions (below).
- Types have **no names** — `Number`, `String`, ... are just globals pointing
  at type values, exactly like any other binding. Error messages quote the
  annotation text you wrote.
- The type universe is closed at one level: `std.Type.of(Number)` → `std.Type`
  and `std.Type.of(std.Type)` → `std.Type` (`Type : Type`).

### Built-in type constants

| Constant | `check` semantics |
|---|---|
| `Number` | value is a Number |
| `String` | value is a String |
| `Boolean` | value is a Boolean |
| `Null` | value is `null` |
| `AnyArray` | value is an array (any elements) — what `std.Type.of` returns for arrays |
| `AnyObject` | value is an object **and not a type value** (types are their own category) — what `std.Type.of` returns for objects |
| `Function` | value is a function |
| `Any` | always `true` (top type) |
| `Never` | always `false` (bottom type) |
| `Error` | value is an error value (`isError`); its member `raise` builds error values (see [Error values](#error-values)) |
| `std.Type` | "is `v` a type value?" — one object with two identities: type value and module (below) |
| `Array` / `Object` | **type constructors** (functions), not type values themselves; `Array(Number)` builds an array type (below) |

### std.Type (module and type value)

`std.Type` is a single object with two identities: as a type value its `check`
answers "is `v` a type?"; as a module it provides the operations

```qlang
std.Type.check(Number)      // true  — Number is a type value
std.Type.check(42)          // false — 42 is not
std.Type.of(42)             // Number   (the type VALUE, not the string "Number")
std.Type.of("hello")        // String
std.Type.of([1, 2, 3])      // AnyArray
std.Type.of({})             // AnyObject
std.Type.of(true)           // Boolean
std.Type.of(null)           // Null
std.Type.of(x -> x)         // Function
std.Type.of(Number)         // std.Type
std.Type.make((v) -> v > 0) // { check: (v) -> v > 0 }  — a user type
```

**`std.Type.of` returns type values, not strings** — a breaking change from the
old string-returning `Type.of` (migrate comparisons like
`std.Type.of(x) == "Number"` to `std.Type.of(x) == Number`).

There is no global `Type` alias — the annotation form is `std.Type`:
`let T: std.Type = Number`.

### Type constructors: `Array(x)` / `Object(x)`

`Array` and `Object` are **functions (constructors)** taking exactly **one**
argument, whose type is a *union* of allowed forms (union members are mutually
exclusive — a number is not a type value and vice versa); the member that
matches decides the semantics. Invalid forms are rejected at construction time
with an error value (never silently).

**`Array(x)` — argument is `Number | Type | [Type] | {length, element}`:**

| Matching member | Semantics | `check` |
|---|---|---|
| `Number` (length `n`) | fixed-length array, any elements | array && `length == n` |
| `Type` (`T`) | any length, every element of `T` | array && every element passes `T.check` |
| `[Type]` (`[T1, T2, ...]`) | fixed length `n`, per-position element types | `length == n` && per-position checks |
| `{length, element}` | fixed length + element type combined | array && `length == n` && every element passes `element.check` |

The members are self-describing: `[Type]` is `Array(std.Type)` and
`{length, element}` is `Object({length: Number, element: std.Type})`.

**`Object(x)` — argument is `Type | shape object`:**

| Matching member | Semantics | `check` |
|---|---|---|
| `Type` (`T`) | object whose **keys** are all of `T` — `Object(String)` ≡ `AnyObject` (any keys); `Object(Number)` requires numeric keys | non-type object && every key passes `T.check` |
| shape object (schema) | record type, e.g. `Object({name: String, age: Number})` | non-type object && every schema field exists and passes its check — **required fields are a subset; extra fields are allowed** |

The whole Object family (`AnyObject` and every `Object(x)` product) excludes
type objects: a type value is never an "object" for type purposes.

### User-defined types (canonical forms)

```qlang
// Union type — the canonical 3-line form (no std.Type.union built-in needed)
let Union = (A, B) -> std.Type.make((v) -> A.check(v) || B.check(v))
let NumOrStr = Union(Number, String)

// Custom predicate type
let Positive = std.Type.make((v) -> v > 0)

// Dependent types fall out naturally: a type constructor is just a function
// returning a type object (Cayenne/CoC path — types are terms)
let Vect = (n) -> std.Type.make((v) -> std.Type.of(v) == AnyArray && v.length == n)
let x: Vect(3) = [1, 2, 3]
```

User types are ordinary data: not protected, breakable at your own risk
(overwriting `check` stops them from being a type).

### Annotations

```qlang
let x: Number = 42            // let annotation — the value is checked NOW
let f = (a: Number) -> ...    // param annotation — evaluated at definition,
                              // checked on every COMPLETED call
let x: Number = 42
x = "a"                       // reassignment re-checks the annotated binding

let y;                        // declare without an initializer ("uninitialized")
y = 42                        // first assignment initializes; no annotation,
                              //   so no check
let z: Number;                // annotated uninitialized declaration
z = 42                        // first assignment initializes and re-checks
z = "a"                       //   → TypeCheck error value
```

- The annotation is a **full expression**, evaluated where it appears:
  `Number`, `Error`, `std.Type.make(...)`, `Vect(3)`, `Union(A, B)`,
  `Array(Number)`, `Array(3)`, `Object({name: String})` are all valid.
- Checking fires only at the three trigger points; a failed check produces a
  `TypeCheck` error value (below), never a crash.
- A declaration without an initializer is allowed: `let x;` (no annotation) or
  `let x: T;` (the annotation is evaluated and validated at declaration, but
  there is no value to check yet). The binding is **uninitialized** until the
  first assignment — reading it yields an `Uninitialized` error value (see
  [Error values](#error-values)), never `null`.
- **`null` is not a value of any type unless that type explicitly allows it.**
  Among the built-ins only `Null` and `Any` accept `null`
  (`Number.check(null)` is `false`, so `let x: Number = null` is a `TypeCheck`
  error). A user type opts in via its `check` — e.g.
  `std.Type.make((v) -> v == null || v > 0)` — and a `check` without a `null`
  branch rejects `null` like any other value.
- Curried calls defer checks to the **completing** call: on
  `(a: Number, b: Number) -> ...`, `f("x")` is a legal partial application
  (returns a curried function, no error), and the final call re-checks all
  parameters — including ones bound earlier (`f("x")(1)` fails).
- Error values are exempted on the interpreter's internal check path and on
  the built-in checks / `std.Type.of` (diagnostic exemption):
  `Number.check(1 / 0)` is `false`, `Any.check(1 / 0)` is `true`. Composite
  and user checks are **not** exempted — an error argument to
  `Array(Positive).check` follows the normal error-argument rules.

### TypeCheck error semantics

A failed check produces a **`TypeCheck` error value** — a distinct kind from
`TypeMismatch` — which flows through `?` / `??` / `isError` like any error:

```qlang
let x: Number = "a";
x.type      // "TypeCheck"
x.message   // 'value of type "String" does not match the annotated type "Number"'
```

- If the check itself errors, the check **fails** — an error never masquerades
  as a pass: with `let Bad = std.Type.make((v) -> 1 / 0); let x: Bad = 5`, the
  binding holds the check's own error value directly (`x.type` is
  `"DivisionByZero"` — no wrapping, no added `cause`), so the annotated
  binding never passes. To assert the annotation failed, use `isError(x)` or
  inspect `x.type`'s kind.
- If the checked value is an error value (e.g. `let x: Number = risky()`), the
  `TypeCheck` error chains it as `cause`, keeping the root cause visible.
- An annotation that is not a type value — a plain value, or a shadowed
  constant — yields `TypeCheck: type annotation is not a type value`.

### Shadowing and protected members

- Names can be shadowed: `let Number = 42` is legal (like `Infinity`/`NaN`).
  After that, `let y: Number = 5` evaluates the annotation to `42` →
  `TypeCheck` error value. Shadowing is local, visible, and recoverable — it
  cannot silently corrupt the type mechanism (unlike overwriting `check`).
- The built-in type objects' core members — `check`, `raise`, `of`, `make` —
  are **protected**: writing them aborts the program (host) / propagates a
  Custom error (boot). This prevents one accidental write from destroying the
  type mechanism.
- Free member mounts are still allowed: `Number.myHelper = 1` works — built-in
  types are protected, not sealed.

**Migration notes from the type-system round:**

- `Error("msg")` no longer exists — `Error` is now the error *type object*
  `{ check, raise }`, and building an error value is `Error.raise("msg")`
  (with cause: `Error.raise("msg", cause)`). The boot's internal 3-argument
  `std.Error.raise(kind, message, cause)` is unchanged.
- `std.Type.of` returns type values (see above).

## Project Structure

```
qlang/
├── src/
│   ├── main.rs           # CLI entry point
│   ├── lib.rs            # Library interface
│   ├── ast.rs            # Abstract Syntax Tree definitions
│   ├── lexer.rs          # Tokenizer
│   ├── parser.rs         # Parser
│   ├── interpreter.rs    # Tree-walk interpreter
│   ├── value.rs          # Runtime value types
│   ├── environment.rs    # Variable scope/environment
│   ├── token.rs          # Token definitions
│   ├── error.rs          # Error types
│   ├── stdlib/
│   │   └── mod.rs        # Standard library
│   └── ...
├── bootstrapped/         # QLang implemented in QLang
│   ├── main.ql           # Exports runSource / main (library entry)
│   ├── run_file.ql       # Run a file through the bootstrapped interpreter
│   ├── demo.ql           # Built-in demo
│   ├── lexer.ql / parser.ql / interpreter.ql
│   ├── ast.ql / environment.ql / tokens.ql / stdlib.ql
│   └── ...
├── demo/
│   └── test.ql           # Demo programs
├── verify_bootstrap.ql   # Bootstrapped semantics assertions (33 checks)
├── test_fix_regression.ql / test_json5_*.ql   # Regression tests
├── difftest.py           # Differential test harness (165 cases + 78 V8-referenced)
├── fuzzexpr.py           # Random expression fuzzing with a Python oracle (390 cases)
├── Cargo.toml
└── README.md
```

## Self-Hosting

QLang can interpret itself: the `bootstrapped/` directory contains a full
lexer, parser, and interpreter written in QLang, executed by the Rust host.

Run the built-in demo through the bootstrapped interpreter:

```bash
cargo run -- bootstrapped/demo.ql
```

Run any QLang file with the bootstrapped interpreter (path relative to the
working directory):

```bash
cargo run -- bootstrapped/run_file.ql my_program.ql
```

Verify the bootstrapped interpreter's execution semantics (33 assertions
covering arithmetic, control flow, closures, objects, strings, native calls,
and more):

```bash
cargo run -- verify_bootstrap.ql
```

## Differential Testing

`difftest.py` runs the same QLang source through both the Rust host
interpreter and the bootstrapped interpreter and asserts identical results —
165 cases: 114 safe cases (batch-run), 26 risky cases (isolated processes,
capturing exit codes and stderr), and 25 complex multi-feature cases. Safe
cases include 24 error-value cases (e01-e24) exercising `?`, `??`, `isError`,
error chains inside functions, and the error kind of a recursion-guard
`StackOverflow`, plus 36 annotation/type-system cases (t01-t37) covering
annotation checks (let/params/reassignment), shadowing, the `Array`/`Object`
constructors, free member mounts on type objects, and the currying ×
annotation interaction (checks deferred to the completing call). Risky cases
r22-r25 and r27-r35 (13 cases) cover erroring expressions that escape to the
top level (division by zero, negative-wrap out-of-bounds, `UndefinedField`,
`TypeMismatch`, argument rejection, stack overflow, and the `??`-vs-`?`
interaction of r34); p1/p2 assert that protected members are not writable; r35
pins the spec's "no global `Type`" (the boot's former bare-`Type` seeding was
removed in Task 12). Both sides must produce the same result — or the same
error.

### Error values

**Errors are data, not control flow.** Runtime errors — type mismatches,
out-of-bounds indexing, missing fields, division by zero, recursion overflow,
user-raised — produce an `Error` **value**: a first-class value of its own
type that flows through expressions like any other data. Nothing "throws" or
terminates the program; an error is handled (`?`, `??`, `isError`) the moment
the code chooses to handle it, and execution continues. There is no try/catch.

An error value carries structured diagnostics:

```qlang
Error {
  type:    "TypeMismatch" | "IndexOutOfBounds" | "UndefinedField"
           | "UndefinedVariable" | "Uninitialized" | "DivisionByZero"
           | "StackOverflow" | "Error" (user) | ...   // other kinds:
           // "NotCallable", "ArityMismatch", "CannotIndex", "NotAnObject"
  message: "human-readable description"
           // e.g. Uninitialized: 'variable "x" is declared but not initialized'
  line / col:  where the error was produced
  stack:   [{ fn, line, col }, ...]   // user function frames only
  cause:   Error | null               // root-cause chain
}
```

Errors are produced automatically by erroring operations, or explicitly via
the `Error` type object's `raise` member (type-system round: `Error("msg")`
was replaced by `Error.raise("msg")` — see [Type System](#type-system)):
`Error.raise("msg")` builds one (kind `"Error"`), and
`Error.raise("msg", cause)` attaches a root cause. There is no throw/raise
keyword — `return Error.raise("...")` is how you raise one (Go-style).

| Situation | Result |
|---|---|
| `1 + "a"`, `-true` type mismatch | `TypeMismatch` error value (no coercion; use `std.Number.toString` for explicit conversion) |
| `arr[10]`, `"abc"[9]` out of bounds | `IndexOutOfBounds` error value |
| `arr[-1]` / `"abc"[-1]` negative index | wraps to `len + i` (deliberate QLang extension, unchanged) |
| negative index out of range (`arr[-3]`) | `IndexOutOfBounds` error value |
| `obj.x` / `obj["x"]` missing field **read** | `UndefinedField` error value (the old null-probe asymmetry is gone: dot and bracket are both strict) |
| `obj.x = v` write to a missing field | creates the field (unchanged, JS-compatible) |
| `1 / 0`, `0 / 0` | `DivisionByZero` error value (no more silent IEEE inf/NaN) |
| undefined variable (host) | `UndefinedVariable` error value |
| read `x` after `let x;` (declared, not yet assigned) | `Uninitialized` error value |
| recursion depth limit | `StackOverflow` error value — recoverable |

> Only division by an exact zero is an error. IEEE overflow (e.g. `1e300 * 10`
> → `Infinity`) keeps IEEE semantics, as in Python and Rust.

> A binding has three states: **undefined** (never declared →
> `UndefinedVariable`), **uninitialized** (`let x;` declared without an
> initializer → `Uninitialized`), and **initialized** (has a value, which may
> itself be `null` — explicit `null` is a legitimate value, distinct from the
> uninitialized state).

**Handling operators.**

- `?` — postfix **propagation** (Rust convention): `let x = risky() ?` — if the
  expression is an error value, the current function returns it; otherwise the
  value passes through. At top level an unhandled error prints the full
  diagnostic to stderr and the process exits 1.
- `??` — binary **fallback** (C# convention): `let y = risky() ?? 42` — if the
  left side is an error value, evaluate the right side as the default. `??` has
  the lowest precedence (below `||`) and is left-associative, so the default
  eats the whole right expression: `risky() ?? 42 + 1` is
  `risky() ?? (42 + 1)`; parenthesize to truncate (`(risky() ?? 42) + 1`).
  `a ?? b ?? c` = `(a ?? b) ?? c` (fallback cascades).

```qlang
// std.String.at(s, i) returns an IndexOutOfBounds error value for
// out-of-range indices — a real error source; nothing is thrown
let first = (s) -> {
    let c = std.String.at(s, 0);
    if isError(c) { return Error.raise("empty string", c); }   // wrap with cause
    return c;
};

let greeting = first("hi") ?? "?";   // "h" — value passes through
let missing = first("") ?? "?";      // "?" — ?? catches the wrapped error

let e = std.String.at("abc", 5);     // IndexOutOfBounds error value
isError(e)          // true
e.type              // "IndexOutOfBounds"
e.message           // "index 5 out of bounds for length 3"

let wrapped = first("");             // Error.raise("empty string", cause)
wrapped.type        // "Error"
wrapped.cause.type  // "IndexOutOfBounds"

let propagate = (s) -> { std.String.at(s, 9) ? };  // ? returns the error
isError(propagate("x"))              // true
```

**Three zones of error use.** Error values are legal in exactly three places:

| Zone | Allowed | Examples |
|---|---|---|
| Propagation | `?`, `??`, `isError()`, `return` | `let x = risky() ?` |
| Read | the error's **own** fields — `.type`, `.message`, `.cause`, `.line`, `.col`; `print` / `println` | `e.message` is an ordinary string |
| Forbidden | arithmetic, comparison, indexing, member access, serialization, and **function arguments** | `db.insert(err)` produces a *new* error; the function never runs |

Operations that consume an error's *value* — unary and binary arithmetic,
comparison, bitwise, `&&` / `||` with an error on the left, and passing an
error as a function argument — produce a **new error that chains the original
as `cause`**, so the root cause stays visible and error values can never cross
a user-function boundary into a database or other external system. Structural
reads do not chain: reading an unknown field of an error value (`err.foo`)
yields a bare `UndefinedField`, and indexing it (`err[0]`) a bare
`CannotIndex`. Only the diagnostic natives may receive error values:
`print` / `println`, `isError`, `Error.raise`, `std.Error.raise`,
`std.Error.toString`, `std.Type.of`, and the built-in type checks
(`Number.check` etc.). Full diagnostics render with
positions and the cause chain (the stack frame is appended at top level):

```
TypeMismatch: cannot apply addition to Number and Error (at line 5, col 12)
  └─ caused by: IndexOutOfBounds: index 10 out of bounds for length 3 (at line 2, col 7)
    at <fn> (line 5, col 12)
```

**Known asymmetries** (both implementations agree; kept on the ledger):

- `!err` is `false` — error values are truthy (`is_truthy(Error)` is `true`),
  so `!` is not an error test.
- `x && err` returns the bare `err` (logical operators pass an evaluated right
  operand through), while `x + err` wraps it in a new error with `cause`.
- `(Error.raise("boom") ?) ?? 42` propagates to top level instead of falling back:
  `??` catches only *error values*, not the internal propagation signal that
  `?` raises (that signal has already left the expression when `??` would
  apply).

**Known boundaries** (self-hosting milestones, tracked separately):

- The bootstrapped interpreter has no `exit` primitive: an unhandled top-level
  error — bare (e.g. a program ending in `1 / 0;`) or `?`-raised — prints its
  diagnostic via `std.Error.toString` and exits 0, where the host prints the
  full diagnostic and exits 1.
- The host's `import` merges only the imported file's exports: an unhandled
  top-level error in the imported file (bare or `?`-raised) is silently
  discarded — its diagnostic is never printed. The bootstrapped interpreter
  does not support importing user code (a nested `import` raises an explicit
  `NotImplemented` error value); undefined variables are reported as
  `UndefinedVariable` error values, matching the host.
- Top-level assignment to an undefined variable: the host terminates with an
  `Undefined variable` error, while the bootstrapped interpreter silently
  ignores it.

Under error-value semantics the two implementations render errors differently
— the host prints a multi-line diagnostic with positions; the boot renders its
wrapped error values via `std.Error.toString` (its AST carries no spans) — so
error comparisons are canonicalized by `norm_err()`, which strips position
info and collapses every rendering to a single token. Non-error values still
must match byte-for-byte, and `==` stays type-strict value/reference equality
(`1 == "1"` is `false`; two distinct array literals are never equal).

### Node.js reference (V8)

The host and boot implementations are not independent (the bootstrapped
interpreter runs on the host), so a third, truly independent reference is used:
QLang semantics are JS-flavored, and for the overlapping subset the same
program is run under Node.js/V8. 78 cases are compared three-way (host, boot,
node) and must all match. Cases where QLang deliberately diverges from JS
(negative index wrapping, error values — QLang returns error values where JS
throws) are excluded; the JS translations
(`->` → `=>`, `==` → `===`, block bodies get explicit `return`, ...) are
curated in `NODE_CASES`. The section is skipped automatically if `node` is not
on `PATH`.

```bash
python3 difftest.py
```

### Random expression fuzzing

`fuzzexpr.py` generates random expression trees (fully parenthesized, so the
parse is forced) and computes the expected value independently in Python
(IEEE-754 f64, matching the host's number semantics) — then runs every
expression through host, boot, and the oracle and requires all three to agree.
It also generates unparenthesized operator chains whose expected grouping is
derived from the language's precedence table (in `CHAIN_CASES`), which catches
precedence/associativity drift in either parser. Default: 390 cases per seed;
pass a `--seed` to vary (CI can sweep several).

```bash
python3 fuzzexpr.py            # seed 1
python3 fuzzexpr.py --seed 42  # different random cases
```

## Examples

See the `demo/` and `test_*.ql` files for example programs.

## License

MIT
