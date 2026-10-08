// Ordinary QLang decimal arithmetic. No raw storage or host Number parser.
// Base 10^7 limbs keep all integer intermediates exact in binary64.
let decimalBig = (n) -> {
  let a = [];
  while n > 0 { let d = n % 10000000; a[a.length] = d; n = (n - d) / 10000000; };
  if a.length == 0 { a[0] = 0; };
  a;
};
let decimalCopy = (a) -> {
  let out = []; let i = 0;
  while i < a.length { out[i] = a[i]; i = i + 1; };
  out;
};
let decimalMultiply = (a, m) -> {
  let carry = 0; let i = 0; let length = a.length;
  while i < length {
    let value = a[i] * m + carry; let digit = value % 10000000;
    a[i] = digit; carry = (value - digit) / 10000000; i = i + 1;
  };
  if carry > 0 { a[a.length] = carry; };
  a;
};
let decimalAdd = (a, b) -> {
  let length = a.length; if b.length > length { length = b.length; };
  let out = []; let carry = 0; let i = 0;
  while i < length {
    let value = carry;
    if i < a.length { value = value + a[i]; };
    if i < b.length { value = value + b[i]; };
    let digit = value % 10000000;
    out[i] = digit; carry = (value - digit) / 10000000; i = i + 1;
  };
  if carry > 0 { out[out.length] = carry; };
  out;
};
let decimalCompare = (a, b) -> {
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
let decimalSubtract = (a, b) -> {
  let borrow = 0; let i = 0;
  while i < a.length {
    let value = a[i] - borrow;
    if i < b.length { value = value - b[i]; };
    borrow = 0;
    if value < 0 { value = value + 10000000; borrow = 1; };
    a[i] = value; i = i + 1;
  };
  while a.length > 1 && a[a.length - 1] == 0 { a.remove(a.length - 1); };
  a;
};
// The rounded mantissa is an exact integer. Subnormals receive one final
// multiplication; normal factors are exact powers of two. Unary minus retains
// a zero sign supplied by the input text.
let decimalCompose = (mantissa, biasedExponent, negative) -> {
  let value = 0;
  if biasedExponent == 0 { value = mantissa * 5e-324; }
  else if biasedExponent == 2047 { value = 1e308 * 1e308; }
  else {
    let factor = 1; let exponent = biasedExponent - 1023;
    while exponent > 0 { factor = factor * 2; exponent = exponent - 1; };
    while exponent < 0 { factor = factor / 2; exponent = exponent + 1; };
    value = (1 + mantissa / 4503599627370496) * factor;
  };
  if negative { -value; } else { value; };
};
let decimalNumber = (r, decimal, negative, digits) -> {
  if r.length == 1 && r[0] == 0 { return decimalCompose(0, 0, negative); };
  if decimal + digits > 310 { return decimalCompose(0, 2047, negative); };
  if decimal + digits < -325 { return decimalCompose(0, 0, negative); };
  let s = decimalBig(1);
  while decimal >= 7 { decimalMultiply(r, 10000000); decimal = decimal - 7; };
  while decimal > 0 { decimalMultiply(r, 10); decimal = decimal - 1; };
  while decimal <= -7 { decimalMultiply(s, 10000000); decimal = decimal + 7; };
  while decimal < 0 { decimalMultiply(s, 10); decimal = decimal + 1; };
  let exponent = 0;
  let chunk = decimalMultiply(decimalCopy(s), 8388608);
  while decimalCompare(r, chunk) >= 0 {
    s = chunk; chunk = decimalMultiply(decimalCopy(s), 8388608); exponent = exponent + 23;
  };
  chunk = decimalMultiply(decimalCopy(r), 8388608);
  while decimalCompare(chunk, s) < 0 {
    r = chunk; chunk = decimalMultiply(decimalCopy(r), 8388608); exponent = exponent - 23;
  };
  let twice = decimalMultiply(decimalCopy(s), 2);
  while decimalCompare(r, twice) >= 0 {
    s = twice; twice = decimalMultiply(decimalCopy(s), 2); exponent = exponent + 1;
  };
  while decimalCompare(r, s) < 0 { decimalMultiply(r, 2); exponent = exponent - 1; };
  if exponent > 1023 { return decimalCompose(0, 2047, negative); };
  if exponent < -1075 { return decimalCompose(0, 0, negative); };
  if exponent == -1075 {
    let mantissa = 0;
    if decimalCompare(r, s) > 0 { mantissa = 1; };
    return decimalCompose(mantissa, 0, negative);
  };
  let bits = 53;
  if exponent < -1022 { bits = exponent + 1075; };
  let mantissa = 0;
  let i = 0;
  while i < bits {
    mantissa = mantissa * 2;
    if decimalCompare(r, s) >= 0 { decimalSubtract(r, s); mantissa = mantissa + 1; };
    i = i + 1;
    if i < bits { decimalMultiply(r, 2); };
  };
  let round = decimalCompare(decimalMultiply(r, 2), s);
  if round > 0 || (round == 0 && mantissa % 2 == 1) { mantissa = mantissa + 1; };
  if exponent < -1022 {
    if mantissa == 4503599627370496 { return decimalCompose(0, 1, negative); };
    return decimalCompose(mantissa, 0, negative);
  };
  if mantissa == 9007199254740992 { mantissa = mantissa / 2; exponent = exponent + 1; };
  if exponent > 1023 { return decimalCompose(0, 2047, negative); };
  decimalCompose(mantissa - 4503599627370496, exponent + 1023, negative);
};
export { decimalBig, decimalAdd, decimalMultiply, decimalNumber };
