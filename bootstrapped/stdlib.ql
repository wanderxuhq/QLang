// QLang Standard Library - Ultra simplified version
// Note: do NOT shadow the built-in std (keep native implementations like
// Number.toString / Type.of); only add methods missing from the Rust std (String.toChars)

let Array = {
  length: (arr) -> {
    let count = 0;
    let i = 0;
    while i < arr.length {
      count = count + 1;
      i = i + 1;
    }
    count;
  },
  get: (arr) -> (idx) -> {
    let len = arr.length;
    let i = idx;
    if i < 0 { i = len + i; }
    if i < 0 { null; }
    else if i >= len { null; }
    else {
      let j = 0;
      let result = null;
      while j < len {
        if j == i { result = arr[j]; }
        j = j + 1;
      }
      result;
    };
  },
  push: (arr) -> (elem) -> {
    arr[arr.length] = elem;
    arr;
  },
  reverse: (arr) -> {
    let len = arr.length;
    let result = [];
    let i = 0;
    while i < len {
      result[i] = arr[len - 1 - i];
      i = i + 1;
    }
    result;
  },
  indexOf: (arr) -> (elem) -> {
    let found = -1;
    let i = 0;
    while i < arr.length {
      if arr[i] == elem { found = i; }
      i = i + 1;
    }
    found;
  },
  includes: (arr) -> (elem) -> {
    let found = false;
    let i = 0;
    while i < arr.length {
      if arr[i] == elem { found = true; }
      i = i + 1;
    }
    found;
  },
};

let String = {
  toChars: (s) -> {
    let parts = [];
    let i = 0;
    while i < s.length {
      parts[parts.length] = s[i];
      i = i + 1;
    }
    parts;
  },
  length: (s) -> {
    let len = 0;
    let i = 0;
    while i < s.length {
      len = len + 1;
      i = i + 1;
    }
    len;
  },
  includes: (s) -> (sub) -> {
    let found = false;
    let i = 0;
    while i < s.length {
      let match = true;
      let j = 0;
      while j < sub.length {
        if i + j >= s.length { match = false; }
        else if s[i + j] != sub[j] { match = false; }
        j = j + 1;
      }
      if match { found = true; }
      i = i + 1;
    }
    found;
  },
  repeat: (s) -> (n) -> {
    let result = "";
    let i = 0;
    while i < n {
      result = result + s;
      i = i + 1;
    }
    result;
  },
  trim: (s) -> {
    let start = 0;
    while start < s.length {
      if s[start] == " " { start = start + 1; }
      else { start = s.length; };
    }
    let end = s.length;
    while end > start {
      if s[end - 1] == " " { end = end - 1; }
      else { end = 0; };
    }
    let result = "";
    let i = start;
    while i < end {
      result = result + s[i];
      i = i + 1;
    }
    result;
  },
  split: (s) -> (sep) -> {
    // Handle empty separator - return array of single characters
    if sep.length == 0 {
      let parts = [];
      let i = 0;
      while i < s.length {
        parts[parts.length] = s[i];
        i = i + 1;
      }
      parts;
    } else {
      let parts = [];
      let current = "";
      let i = 0;
      while i < s.length {
        let match = true;
        let j = 0;
        while j < sep.length {
          if i + j >= s.length { match = false; }
          else if s[i + j] != sep[j] { match = false; }
          j = j + 1;
        }
        if match {
          parts[parts.length] = current;
          current = "";
          i = i + sep.length;
        } else {
          current = current + s[i];
          i = i + 1;
        }
      }
      parts[parts.length] = current;
      parts;
    }
  },
  toString: (v) -> {
    if v == null { "null"; }
    else if v == true { "true"; }
    else if v == false { "false"; }
    else { v; };
  },
};

let Object = {
  keys: (obj) -> { [] },
  get: (obj) -> (key) -> obj[key],
  set: (obj) -> (key) -> (val) -> { obj[key] = val; obj; },
  values: (obj) -> { [] },
  merge: (a) -> (b) -> { a; },
};

let Math = {
  sqrt: (n) -> { if n < 0 { 0; } else { n; }; },
  abs: (n) -> { if n < 0 { 0 - n; } else { n; }; },
  pow: (base) -> (exp) -> {
    let result = 1;
    let i = 0;
    while i < exp {
      result = result * base;
      i = i + 1;
    }
    result;
  },
  PI: 3.14159,
};

let Number = {
  isFinite: (n) -> n.type == "Number",
  isNaN: (n) -> n.type != "Number",
  parseFloat: (s) -> {
    let result = 0;
    let i = 0;
    let hasDecimal = false;
    let decimalDiv = 1;
    while i < s.length {
      let c = s[i];
      let digit = 0;
      if c == "0" { digit = 0; }
      else if c == "1" { digit = 1; }
      else if c == "2" { digit = 2; }
      else if c == "3" { digit = 3; }
      else if c == "4" { digit = 4; }
      else if c == "5" { digit = 5; }
      else if c == "6" { digit = 6; }
      else if c == "7" { digit = 7; }
      else if c == "8" { digit = 8; }
      else if c == "9" { digit = 9; }
      else if c == "." { digit = -1; }
      else { digit = -2; }
      if digit >= 0 {
        if hasDecimal { decimalDiv = decimalDiv * 10; }
        result = result * 10 + digit;
      } else if digit == -1 {
        hasDecimal = true;
      }
      i = i + 1;
    }
    if hasDecimal { result / decimalDiv; } else { result; }
  },
};

let Type = {
  of: (v) -> {
    if v == null { "Null"; }
    else if v.type == "Number" { "Number"; }
    else if v.type == "String" { "String"; }
    else if v.type == "Array" { "Array"; }
    else if v.type == "Object" { "Object"; }
    else if v.type == "Function" { "Function"; }
    else { "Unknown"; };
  },
};

let JSON = {
  stringify: (v) -> std.String.toString(v),
  parse: (s) -> s,
};

let Boolean = {
  of: (v) -> {
    if v == null { false; }
    else if v == 0 { false; }
    else if v == "" { false; }
    else if v == false { false; }
    else { true; };
  },
};

let fs = {
  readFileText: (path) -> "",
};

// Only add methods missing from the Rust std
std.String.toChars = String.toChars;
std.String.repeat = String.repeat;

export std;
