// Regenerate or verify the 1216-bit 2/pi table used by stdlib/math.ql's
// Payne-Hanek reducer (`let twoOverPi = [...]`, 76 base-65536 limbs).
//
// Build (from the repo root, as the checker runs it):
//   target/tools/build aot/generate_math_constants.ql -o /tmp/gen_math \
//     --compiler target/selfhost/stage2 \
//     --stdlib-object <stdlib-object-dir>/stdlib.o
//
//   /tmp/gen_math          -> print the `let twoOverPi = [...]` literal
//   /tmp/gen_math --check  -> compare stdlib/math.ql; exit 0 on match, 1 with a diff
//   /tmp/gen_math --check --table <file>   (compare another copy; run from repo root)
//
// pi comes from Machin's formula (16*atan(1/5) - 4*atan(1/239)) evaluated twice,
// with 450 and 500 decimal digits of fixed-point precision; the two results must
// agree (the precision guard). With M = 10^P and piFixed = floor(pi * M),
//   V = floor(2 * 2^1216 * M / piFixed)  ~=  floor(2 * 2^1216 / pi)
// because the relative error of piFixed (about 10^-P) shifts V by far less than
// one unit. V's base-65536 digits are the table; the 77th quotient must be 0.
//
// Magnitudes are stdlib/decimal.ql's little-endian base-10^7 limbs (all integer
// intermediates stay exact in binary64); comparison/subtraction/division are
// local because decimal.ql only exports arithmetic.
import ../stdlib/decimal.ql;

let decimalLimbBase = 10000000;
let tableBits = 1216;
let tableLimbs = 76;
let guardDigitsLow = 450;
let guardDigitsHigh = 500;
let tablePath = "stdlib/math.ql";

let fail = (message) -> {
  assert(false, "generate_math_constants: " + message);
  0;
};
let bigCopy = (a) -> {
  let out = []; let i = 0;
  while i < a.length { out[i] = a[i]; i = i + 1; };
  out;
};
let bigTrim = (a) -> {
  while a.length > 1 && a[a.length - 1] == 0 { a.remove(a.length - 1); };
  a;
};
let bigIsZero = (a): Boolean -> a.length == 1 && a[0] == 0;
let bigCompare = (a, b): Number -> {
  if a.length < b.length { return -1; };
  if a.length > b.length { return 1; };
  let i = a.length - 1;
  while i >= 0 {
    if a[i] < b[i] { return -1; };
    if a[i] > b[i] { return 1; };
    i = i - 1;
  };
  0;
};
let bigAdd = (a, b) -> decimalAdd(a, b);
let bigMulSmall = (a, m) -> decimalMultiply(bigCopy(a), m);
// Requires |a| >= |b| and returns a non-negative magnitude.
let bigSub = (a, b) -> {
  let out = []; let borrow = 0; let i = 0;
  while i < a.length {
    let value = a[i] - borrow;
    if i < b.length { value = value - b[i]; };
    borrow = 0;
    if value < 0 { value = value + decimalLimbBase; borrow = 1; };
    out[i] = value;
    i = i + 1;
  };
  bigTrim(out);
};
// a*m + add, both small (magnitude); one pass plus the carry limbs.
let bigShiftAdd = (a, m, add) -> {
  let out = []; let carry = add; let i = 0;
  while i < a.length {
    let value = a[i] * m + carry;
    let digit = value % decimalLimbBase;
    out[i] = digit;
    carry = (value - digit) / decimalLimbBase;
    i = i + 1;
  };
  while carry > 0 {
    let digit = carry % decimalLimbBase;
    out[out.length] = digit;
    carry = (carry - digit) / decimalLimbBase;
  };
  bigTrim(out);
};
// [quotient, remainder] for a positive small divisor (carry fits exactly in f64).
let bigDivSmall = (a, m) -> {
  let q = []; let i = 0;
  while i < a.length { q[i] = 0; i = i + 1; };
  let remainder = 0;
  i = a.length - 1;
  while i >= 0 {
    let current = remainder * decimalLimbBase + a[i];
    let whole = current - current % m;
    q[i] = whole / m;
    remainder = current - whole;
    i = i - 1;
  };
  [bigTrim(q), remainder];
};
// Schoolbook long division: one decimal digit of the dividend per step, so each
// quotient digit is at most 9 and the remainder stays below the divisor.
let bigDiv = (a, b) -> {
  let quotient = [0];
  let remainder = [0];
  let i = a.length - 1;
  while i >= 0 {
    let limb = a[i];
    let digits = [];
    let k = 0;
    while k < 7 {
      let d = limb % 10;
      digits[k] = d;
      limb = (limb - d) / 10;
      k = k + 1;
    };
    let j = 6;
    while j >= 0 {
      remainder = bigShiftAdd(remainder, 10, digits[j]);
      let digit = 0;
      while bigCompare(remainder, b) >= 0 { remainder = bigSub(remainder, b); digit = digit + 1; };
      quotient = bigShiftAdd(quotient, 10, digit);
      j = j - 1;
    };
    i = i - 1;
  };
  [bigTrim(quotient), bigTrim(remainder)];
};
let bigPowerOfTen = (digits) -> {
  let out = decimalBig(1); let i = 0;
  while i < digits { out = decimalMultiply(out, 10); i = i + 1; };
  out;
};
// atan(1/n) * scale, scaled fixed point; terms are truncated toward zero.
let bigAtanInverse = (n, scale) -> {
  let power = n * n;
  let term = bigDivSmall(scale, n)[0];
  let total = bigCopy(term);
  let k = 3;
  let running = !bigIsZero(term);
  while running {
    term = bigDivSmall(term, power)[0];
    if bigIsZero(term) { running = false; }
    else {
      let part = bigDivSmall(term, k)[0];
      if k % 4 == 3 { total = bigSub(total, part); }
      else { total = bigAdd(total, part); };
      k = k + 2;
    };
  };
  total;
};
let bigPi = (scale) -> {
  let fifth = bigAtanInverse(5, scale);
  let small = bigAtanInverse(239, scale);
  bigSub(bigMulSmall(fifth, 16), bigMulSmall(small, 4));
};
// floor(2 * 2^1216 * 10^digits / pi) in base-65536 limbs (least significant first).
let twoOverPiLimbs = (digits) -> {
  let scale = bigPowerOfTen(digits);
  // bigPi only reads the scale, but the numerator below doubles it in place.
  let pi = bigPi(scale);
  let numerator = scale;
  let i = 0;
  while i < tableBits + 1 { numerator = decimalMultiply(numerator, 2); i = i + 1; };
  let value = bigDiv(numerator, pi)[0];
  let limbs = [];
  i = 0;
  while i < tableLimbs {
    let step = bigDivSmall(value, 65536);
    limbs[limbs.length] = step[1];
    value = step[0];
    i = i + 1;
  };
  assert(bigIsZero(value),
         "generate_math_constants: table overflow at " + std.Number.toString(digits) + " guard digits");
  limbs;
};
let sameLimbs = (a, b) -> {
  if a.length != b.length { return false; };
  let i = 0;
  while i < a.length {
    if a[i] != b[i] { return false; };
    i = i + 1;
  };
  true;
};
let quoteLimbs = (limbs) -> {
  let tokens = []; let i = 0;
  while i < limbs.length { tokens[tokens.length] = std.Number.toString(limbs[i]); i = i + 1; };
  "let twoOverPi = [" + std.String.join(tokens)(", ") + "];";
};
let isDigit = (c) -> c == "0" || c == "1" || c == "2" || c == "3" || c == "4" ||
               c == "5" || c == "6" || c == "7" || c == "8" || c == "9";
// Pull the existing literal's limb tokens out of stdlib/math.ql.
let readTableTokens = (path) -> {
  let text = std.fs.readFileText(path);
  if isError(text) { fail("cannot read " + path + ": " + text.message); };
  // Search the whole text so a wrapped literal still parses.
  let parts = std.String.split(text)("let twoOverPi");
  if parts.length < 2 { fail("no `let twoOverPi` literal in " + path); };
  let tail = parts[1];
  let open = -1; let close = -1; let i = 0;
  while i < tail.length {
    if open < 0 {
      if tail[i] == "[" { open = i; };
    } else if close < 0 && tail[i] == "]" { close = i; };
    i = i + 1;
  };
  if open < 0 || close < open { fail("malformed `let twoOverPi` literal in " + path); };
  let tokens = []; let token = "";
  i = open + 1;
  while i < close {
    let c = tail[i];
    if isDigit(c) { token = token + c; }
    else {
      if token != "" { tokens[tokens.length] = token; token = ""; };
    };
    i = i + 1;
  };
  if token != "" { tokens[tokens.length] = token; };
  tokens;
};
let checkTable = (limbs) -> {
  let expected = quoteLimbs(limbs);
  let tokens = readTableTokens(tablePath);
  let differences = 0; let i = 0;
  while i < tableLimbs {
    let seen = "<missing>";
    if i < tokens.length { seen = tokens[i]; };
    if seen != std.Number.toString(limbs[i]) {
      if differences < 20 {
        println("limb[" + std.Number.toString(i) + "]: " + tablePath + " has " + seen +
                ", generator has " + std.Number.toString(limbs[i]));
      };
      differences = differences + 1;
    };
    i = i + 1;
  };
  if tokens.length != tableLimbs {
    println("limb count: " + tablePath + " has " + std.Number.toString(tokens.length) +
            ", generator has " + std.Number.toString(tableLimbs));
  };
  if differences > 0 || tokens.length != tableLimbs {
    println("generated: " + expected);
    fail("table is stale (" + std.Number.toString(differences) + " limbs differ)");
  };
  println("twoOverPi: " + std.Number.toString(tableLimbs) + " limbs match " + tablePath);
  0;
};

let check = false;
let i = 0;
while i < args.length {
  if args[i] == "--check" { check = true; }
  else if args[i] == "--table" {
    i = i + 1;
    if i >= args.length { fail("--table needs a path"); };
    tablePath = args[i];
  }
  else { fail("unknown argument: " + args[i]); };
  i = i + 1;
};
let low = twoOverPiLimbs(guardDigitsLow);
let high = twoOverPiLimbs(guardDigitsHigh);
assert(sameLimbs(low, high),
       "generate_math_constants: Machin pi precision guard failed (" +
       std.Number.toString(guardDigitsLow) + " vs " + std.Number.toString(guardDigitsHigh) + " digits)");
if check { checkTable(low); } else { println(quoteLimbs(low)); };
0;
