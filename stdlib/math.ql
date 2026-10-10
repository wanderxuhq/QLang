// Math algorithms expressed in ordinary QLang. The only runtime primitives are
// the frexp/ldexp binary64 representation mechanisms (std.Number.frexp/ldexp);
// variadic max/min dispatch and entropy-backed random stay runtime mechanisms.
let absolute = (n: Number) -> {
  if n == 0 { 0; } else if n < 0 { -n; } else { n; };
};
let truncate = (n: Number) -> {
  let magnitude = absolute(n);
  // Multiplication retains the input's zero sign without inspecting its bytes.
  if magnitude < 1 { return n * 0; };
  if magnitude >= 4503599627370496 || n != n { return n; };
  n | 0;
};
let finiteNumber = (n) -> n == n && n - n == 0;
let nanNumber = () -> { let overflow = 1e308 * 1e308; overflow - overflow; };
let infiniteNumber = () -> 1e308 * 1e308;
let signedInfinity = (negative) -> { let inf = infiniteNumber(); if negative { -inf; } else { inf; }; };
let signedZero = (negative) -> { if negative { -0; } else { 0; }; };
// -0 survives frexp untouched, but no comparison, and no division (which is an
// error here), separates it from 0. The runtime's Number.toString is the only
// oracle available inside the library, and it renders a negative zero as "-0".
let hasNegativeSign = (n) -> {
  if n < 0 { return true; };
  if n == 0 { return std.Number.toString(n) == "-0"; };
  false;
};
let roundValue = (n) -> {
  if !finiteNumber(n) || absolute(n) >= 4503599627370496 { return n; };
  let t = truncate(n);
  if absolute(n - t) >= 0.5 { if n < 0 { t - 1; } else { t + 1; }; } else { t; };
};
let normalized = (n) -> std.Number.frexp(n);
let scaleByPowerOfTwo = (n) -> (e) -> std.Number.ldexp(n)(e);
// Two binary64 components retain cancellation/product residuals. Dekker split
// inputs here are bounded by log/exp range checks, avoiding split overflow.
let ddAdd = (a, b) -> {
  let s = a[0] + b[0]; let v = s - a[0];
  let e = ((a[0] - (s - v)) + (b[0] - v)) + a[1] + b[1];
  let hi = s + e; [hi, e - (hi - s)];
};
let ddMul = (a, b) -> {
  let p = a[0] * b[0];
  let ca = 134217729 * a[0]; let ah = ca - (ca - a[0]); let al = a[0] - ah;
  let cb = 134217729 * b[0]; let bh = cb - (cb - b[0]); let bl = b[0] - bh;
  let e = (((ah * bh - p) + ah * bl) + al * bh) + al * bl;
  e = e + a[0] * b[1] + a[1] * b[0] + a[1] * b[1];
  let hi = p + e; [hi, e - (hi - p)];
};
let ddDiv = (a, b) -> {
  let q = a[0] / b[0]; let product = ddMul(b, [q, 0]);
  let rest = ddAdd(a, [-product[0], -product[1]]);
  ddAdd([q, 0], [(rest[0] + rest[1]) / b[0], 0]);
};
// log(m) = 2*atanh((m-1)/(m+1)), with |z| < .172 after reduction.
let logarithm = (n) -> {
  let parts = normalized(n); let m = parts[0]; let e = parts[1];
  if m > 1.4142135623730951 { m = m / 2; e = e + 1; };
  let z = ddDiv(ddAdd([m, 0], [-1, 0]), ddAdd([m, 0], [1, 0]));
  let z2 = ddMul(z, z); let sum = z; let term = z; let k = 3;
  while k <= 43 { term = ddMul(term, z2); sum = ddAdd(sum, ddDiv(term, [k, 0])); k = k + 2; };
  ddAdd(ddMul([e, 0], [0.6931471805599453, 0.000000000000000023190468138462996]), ddMul([2, 0], sum));
};
let exponential = (n) -> {
  if n[0] > 710 { return signedInfinity(false); };
  if n[0] < -746 { return 0; };
  let k = roundValue(n[0] / 0.6931471805599453);
  let shift = ddMul([-k, 0], [0.6931471805599453, 0.000000000000000023190468138462996]);
  let r = ddAdd(n, shift); let sum = [1, 0]; let term = [1, 0]; let i = 1;
  while i <= 24 { term = ddDiv(ddMul(term, r), [i, 0]); sum = ddAdd(sum, term); i = i + 1; };
  scaleByPowerOfTwo(sum[0] + sum[1])(k);
};
// Integral powers retain a normalized significand and a separate exponent,
// so neither squaring nor reciprocal formation over/underflows prematurely.
let integerPower = (m, e, b) -> {
  let base = [m, 0]; let exponent = absolute(b); let be = e;
  if b < 0 { base = ddDiv([1, 0], base); be = -be; };
  if base[0] < 1 { base = ddMul(base, [2, 0]); be = be - 1; };
  let result = [1, 0]; let re = 0;
  while exponent > 0 {
    if exponent % 2 == 1 {
      result = ddMul(result, base); re = re + be;
      if result[0] >= 2 { result = ddMul(result, [0.5, 0]); re = re + 1; };
    };
    exponent = truncate(exponent / 2);
    if exponent > 0 {
      base = ddMul(base, base); be = be * 2;
      if base[0] >= 2 { base = ddMul(base, [0.5, 0]); be = be + 1; };
    };
  };
  if re > 1023 { return signedInfinity(false); };
  if re < -1075 { return 0; };
  scaleByPowerOfTwo(result[0] + result[1])(re);
};
let squareRoot = (n: Number) -> {
  if !(n >= 0) { return std.Error.raise("TypeMismatch", "Math.sqrt expects non-negative Number", null); };
  if n == 0 || !finiteNumber(n) { return n; };
  let parts = normalized(n); let m = parts[0]; let e = parts[1];
  if e % 2 != 0 { m = m * 2; e = e - 1; };
  let x = (m + 1) / 2; let i = 0;
  while i < 7 { x = (x + m / x) / 2; i = i + 1; };
  scaleByPowerOfTwo(x)(e / 2);
};
let power = (a: Number) -> {
  (b: Number) -> {
    if b == 0 || a == 1 { return 1; };
    if a != a || b != b { return nanNumber(); };
    let magnitude = absolute(a);
    if !finiteNumber(b) {
      if magnitude == 1 { return 1; };
      if (magnitude > 1) == (b > 0) { return signedInfinity(false); };
      return 0;
    };
    let integral = truncate(b) == b;
    let odd = integral && b % 2 != 0;
    let negative = hasNegativeSign(a) && odd;
    if magnitude == 0 {
      if b < 0 { return signedInfinity(negative); };
      return signedZero(negative);
    };
    if !finiteNumber(a) {
      if b < 0 { return signedZero(negative); };
      return signedInfinity(negative);
    };
    if a < 0 && !integral { return nanNumber(); };
    if b == 0.5 { return squareRoot(a); };
    if b == -0.5 { return 1 / squareRoot(a); };
    let result = 0;
    if integral && absolute(b) <= 64 {
      let parts = normalized(magnitude);
      result = integerPower(parts[0], parts[1], b);
    } else {
      let parts = normalized(magnitude);
      if parts[0] == 1 && integral {
        let exponent = parts[1] * b;
        if exponent > 1023 { result = signedInfinity(false); }
        else if exponent < -1074 { result = 0; }
        else { result = scaleByPowerOfTwo(1)(exponent); };
      } else {
        let log = logarithm(magnitude); let rough = b * log[0];
        if rough > 710 { result = signedInfinity(false); }
        else if rough < -746 { result = 0; }
        else { result = exponential(ddMul([b, 0], log)); };
      };
    };
    if negative { -result } else { result };
  };
};
// Payne-Hanek reduction: multiply the exact 53-bit significand by a 1216-bit
// fixed-point 2/pi constant. Base-65536 products/carries stay exact in binary64.
let twoOverPi = [27563, 64635, 12358, 22019, 23816, 8077, 24497, 27643, 37610, 35410, 14839, 15623, 61819, 60389, 47815, 29991, 59949, 40543, 16230, 20294, 2487, 10187, 32463, 27958, 27935, 23050, 4491, 61231, 38927, 56837, 38911, 8184, 10299, 48633, 24459, 40068, 14836, 33619, 54841, 14737, 32321, 46175, 28710, 59804, 17540, 11963, 13813, 59522, 42814, 45353, 60188, 65053, 37404, 2513, 12010, 1609, 53984, 16973, 28218, 46884, 50529, 57019, 25515, 65105, 36929, 15427, 38297, 56162, 56768, 62772, 22481, 64551, 5417, 20036, 33646, 41721];
let mathBit = (a, position) -> {
  let offset = position % 16; let index = (position - offset) / 16;
  if index >= a.length { return 0; };
  if (a[index] & scaleByPowerOfTwo(1)(offset)) != 0 { 1 } else { 0 };
};
let reduceAngle = (n) -> {
  if n <= 0.7853981633974483 { return [n, 0]; };
  let parts = normalized(n); let m = parts[0] * 4503599627370496;
  let shift = 1268 - parts[1]; let chunks = [];
  while m > 0 { let d = m & 65535; chunks.add(d); m = (m - d) / 65536; };
  let product = []; let i = 0;
  while i < twoOverPi.length + 5 { product.add(0); i = i + 1; };
  i = 0;
  while i < chunks.length {
    let carry = 0; let j = 0;
    while j < twoOverPi.length {
      let v = product[i + j] + chunks[i] * twoOverPi[j] + carry;
      let low = v & 65535; product[i + j] = low; carry = (v - low) / 65536; j = j + 1;
    };
    product[i + j] = carry; i = i + 1;
  };
  let quadrant = mathBit(product, shift) + 2 * mathBit(product, shift + 1);
  let up = mathBit(product, shift - 1) == 1;
  if up { quadrant = (quadrant + 1) % 4; };
  let offset = shift % 16; let top = (shift - offset) / 16;
  let remainder = []; let carry = 1; i = 0;
  while i <= top {
    let mask = 65535; if i == top { mask = scaleByPowerOfTwo(1)(offset) - 1; };
    let value = 0; if i < product.length { value = product[i] & mask; };
    if up {
      value = mask - value + carry;
      if value > mask { value = value - mask - 1; carry = 1; } else { carry = 0; };
    };
    remainder.add(value); i = i + 1;
  };
  while top > 0 && remainder[top] == 0 { top = top - 1; };
  let fraction = 0; i = top;
  while i >= 0 && i >= top - 4 {
    fraction = fraction + scaleByPowerOfTwo(remainder[i])(16 * i - shift); i = i - 1;
  };
  if up { fraction = -fraction; };
  [fraction * 1.5707963267948966 + fraction * 0.00000000000000006123233995736766, quadrant];
};
let trig = (n, cosine) -> {
  if !finiteNumber(n) { return nanNumber(); };
  if n == 0 { if cosine { return 1; } else { return n; }; };
  let reduced = reduceAngle(absolute(n)); let r = reduced[0]; let q = reduced[1];
  let sine = r; let cosineValue = 1; let st = r; let ct = 1; let k = 1;
  while k <= 12 {
    st = -st * r * r / ((2 * k) * (2 * k + 1)); sine = sine + st;
    ct = -ct * r * r / ((2 * k - 1) * (2 * k)); cosineValue = cosineValue + ct;
    k = k + 1;
  };
  let result = 0;
  if cosine {
    if q == 0 { result = cosineValue; } else if q == 1 { result = -sine; }
    else if q == 2 { result = -cosineValue; } else { result = sine; };
  } else {
    if q == 0 { result = sine; } else if q == 1 { result = cosineValue; }
    else if q == 2 { result = -sine; } else { result = -cosineValue; };
    if n < 0 { result = -result; };
  };
  result;
};
let MathLibrary = {
  PI: 3.141592653589793,
  E: 2.718281828459045,
  abs: (n: Number) -> absolute(n),
  trunc: (n: Number) -> truncate(n),
  floor: (n: Number) -> {
    let t = truncate(n); if n < t { t - 1; } else { t; };
  },
  ceil: (n: Number) -> {
    let t = truncate(n); if n > t { t + 1; } else { t; };
  },
  round: (n: Number) -> roundValue(n),
  sqrt: squareRoot,
  pow: power,
  sin: (n: Number) -> trig(n, false),
  cos: (n: Number) -> trig(n, true)
};
export { MathLibrary };
