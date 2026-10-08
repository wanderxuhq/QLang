import ./decimal.ql;
import ./string.ql;
let decimalDigits = {"0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9};
let decimalDigit = (c) -> { let digit = decimalDigits[c]; if isError(digit) { -1; } else { digit; }; };
let invalidNumber = () -> { let overflow = 1e308 * 1e308; overflow - overflow; };
let parseDecimal = (text) -> {
  if !String.check(text) { return invalidNumber(); };
  text = StringLibrary.trim(text);
  let length = text.length; let i = 0; let negative = false;
  if i < length && (text[i] == "-" || text[i] == "+") { negative = text[i] == "-"; i = i + 1; };
  // Preserve the existing accepted spellings without new globals or coercion.
  if i < length && (text[i] == "i" || text[i] == "I" || text[i] == "n" || text[i] == "N") {
    let word = "";
    while i < length { word = word + text[i]; i = i + 1; };
    word = StringLibrary.toLowerCase(word);
    if word == "inf" || word == "infinity" {
      let result = 1e308 * 1e308; if negative { return -result; } else { return result; };
    };
    return invalidNumber();
  };
  let value = decimalBig(0); let digits = 0; let seen = false; let any = false; let decimal = 0;
  while i < length && decimalDigit(text[i]) >= 0 {
    let d = decimalDigit(text[i]); value = decimalAdd(decimalMultiply(value, 10), decimalBig(d));
    any = true; if d != 0 { seen = true; }; if seen { digits = digits + 1; }; i = i + 1;
  };
  if i < length && text[i] == "." {
    i = i + 1;
    while i < length && decimalDigit(text[i]) >= 0 {
      let d = decimalDigit(text[i]); value = decimalAdd(decimalMultiply(value, 10), decimalBig(d));
      any = true; if d != 0 { seen = true; }; if seen { digits = digits + 1; };
      decimal = decimal - 1; i = i + 1;
    };
  };
  if !any { return invalidNumber(); };
  if i < length && (text[i] == "e" || text[i] == "E") {
    i = i + 1; let negativeExponent = false;
    if i < length && (text[i] == "-" || text[i] == "+") { negativeExponent = text[i] == "-"; i = i + 1; };
    if i >= length || decimalDigit(text[i]) < 0 { return invalidNumber(); };
    let exponent = 0;
    while i < length && decimalDigit(text[i]) >= 0 {
      if exponent < length + 400 { exponent = exponent * 10 + decimalDigit(text[i]); }; i = i + 1;
    };
    if negativeExponent { decimal = decimal - exponent; } else { decimal = decimal + exponent; };
  };
  if i != length { return invalidNumber(); };
  decimalNumber(value, decimal, negative, digits);
};
let NumberLibrary = {
  parseFloat: parseDecimal,
  isNaN: (n) -> { if Number.check(n) { n != n; } else { false; }; },
  isFinite: (n) -> { if Number.check(n) { n == n && n - n == 0; } else { false; }; }
};
export { NumberLibrary };
