// Portable QLang algorithms. No LLVM, raw memory or host String algorithms.
import ./unicode_data.ql;

let requireString = (s, name) -> {
  if !String.check(s) { return std.Error.raise("TypeMismatch", name + " expects String", null); };
  s;
};
let finite = (n: Number): Boolean -> n == n && n - n == 0;
let propertyTable = (chunks) -> {
  let table = {}; let i = 0;
  while i < chunks.length {
    let chunk = chunks[i]; let j = 0; let size = chunk.length;
    while j < size { table[chunk[j]] = true; j = j + 1; };
    i = i + 1;
  };
  table;
};
let mappingTable = (chunks) -> {
  let table = {}; let i = 0;
  while i < chunks.length {
    let chunk = chunks[i]; let j = 0; let size = chunk.length;
    while j < size {
      let key = chunk[j]; j = j + 1; let value = "";
      while chunk[j] != "|" { value = value + chunk[j]; j = j + 1; };
      table[key] = value; j = j + 1;
    };
    i = i + 1;
  };
  table;
};
// Private immutable tables are built only when that operation needs them.
let upperMap = null;
let lowerMap = null;
let cased = null;
let ignorable = null;
let whitespace = null;
let has = (table, c): Boolean -> !isError(table[c]);
// Migration debt: this function can return the Error from requireString, so a
// `: String` annotation would be a lie. It stays unannotated until the corpus
// is migrated to Result return types (see docs/rust-error-model.md).
let casing = (s, up) -> {
  s = requireString(s, if up { "String.toUpperCase" } else { "String.toLowerCase" })?;
  if up && upperMap == null { upperMap = mappingTable(unicodeData.upper); };
  if !up && lowerMap == null { lowerMap = mappingTable(unicodeData.lower); };
  if !up && cased == null { cased = propertyTable(unicodeData.cased); ignorable = propertyTable(unicodeData.ignorable); };
  let map = if up { upperMap } else { lowerMap };
  let out = ""; let i = 0; let previousCased = false; let length = s.length;
  while i < length {
    let c = s[i]; let mapped = map[c];
    if !up && c == "Σ" {
      let next = i + 1;
      while next < length && has(ignorable, s[next]) { next = next + 1; };
      let followingCased = next < length && has(cased, s[next]);
      mapped = if previousCased && !followingCased { "ς" } else { "σ" };
    } else if isError(mapped) { mapped = c; };
    out = out + mapped;
    if !up && !has(ignorable, c) { previousCased = has(cased, c); };
    i = i + 1;
  };
  out;
};
let matches = (s, size, at, pattern, width): Boolean -> {
  if at + width > size { return false; };
  let j = 0;
  while j < width {
    if s[at + j] != pattern[j] { return false; };
    j = j + 1;
  };
  true;
};
let StringLibrary = {
  length: (s) -> { s = requireString(s, "String.length")?; s.length; },
  concat: (a, b) -> { a = requireString(a, "String.concat")?; b = requireString(b, "String.concat")?; a + b; },
  toString: (v) -> `${v}`,
  trim: (s) -> {
    s = requireString(s, "String.trim")?;
    if whitespace == null { whitespace = propertyTable(unicodeData.space); };
    let start = 0; let end = s.length;
    while start < end && has(whitespace, s[start]) { start = start + 1; };
    while end > start && has(whitespace, s[end - 1]) { end = end - 1; };
    let out = "";
    while start < end { out = out + s[start]; start = start + 1; };
    out;
  },
  toUpperCase: (s) -> casing(s, true),
  toLowerCase: (s) -> casing(s, false),
  includes: (s) -> {
    s = requireString(s, "String.includes")?;
    (pattern) -> {
      if !String.check(pattern) { return false; };
      let i = 0; let size = s.length; let width = pattern.length;
      while i <= size - width {
        if matches(s, size, i, pattern, width) { return true; };
        i = i + 1;
      };
      false;
    };
  },
  startsWith: (s) -> {
    s = requireString(s, "String.startsWith")?;
    (pattern) -> String.check(pattern) && matches(s, s.length, 0, pattern, pattern.length);
  },
  endsWith: (s) -> {
    s = requireString(s, "String.endsWith")?;
    (pattern) -> {
      if !String.check(pattern) { return false; };
      let size = s.length; let width = pattern.length;
      width <= size && matches(s, size, size - width, pattern, width);
    };
  },
  replace: (s) -> {
    s = requireString(s, "String.replace")?;
    (from) -> (to) -> {
      if !String.check(from) || !String.check(to) { return s; };
      let out = ""; let i = 0; let size = s.length; let width = from.length;
      if width == 0 {
        out = to;
        while i < size { out = out + s[i] + to; i = i + 1; };
      } else {
        while i < size {
          if matches(s, size, i, from, width) { out = out + to; i = i + width; }
          else { out = out + s[i]; i = i + 1; };
        };
      };
      out;
    };
  },
  split: (s) -> {
    s = requireString(s, "String.split")?;
    (separator) -> {
      if !String.check(separator) { return [s]; };
      let parts = []; let part = ""; let i = 0; let size = s.length; let width = separator.length;
      if width == 0 {
        parts[parts.length] = "";
        while i < size { parts[parts.length] = s[i]; i = i + 1; };
      } else {
        while i < size {
          if matches(s, size, i, separator, width) {
            parts[parts.length] = part; part = ""; i = i + width;
          } else { part = part + s[i]; i = i + 1; };
        };
      };
      parts[parts.length] = part;
      parts;
    };
  },
  repeat: (s) -> {
    s = requireString(s, "String.repeat")?;
    (count) -> {
      if !Number.check(count) { return s; };
      if !finite(count) || count < 0 || count % 1 != 0 {
        return std.Error.raise("RangeError", "String.repeat expects a finite non-negative integer count", null);
      };
      if s.length == 0 || count == 0 { return ""; };
      // Portable implementation resource bound, in Unicode scalars, before concatenation.
      if count > 16777216 / s.length {
        return std.Error.raise("RangeError", "String.repeat result exceeds 16777216 scalars", null);
      };
      let out = ""; let part = s; let n = count;
      while n > 0 {
        if n % 2 == 1 { out = out + part; };
        n = (n - n % 2) / 2;
        if n > 0 { part = part + part; };
      };
      out;
    };
  },
  join: (a) -> {
    if !AnyArray.check(a) { return std.Error.raise("TypeMismatch", "String.join expects Array", null); };
    (separator) -> {
      if !String.check(separator) { return ""; };
      // Pairwise reduction: growing one string with `out = out + …` per element
      // is O(n²) and dominates callers that join large arrays.
      let parts = []; let i = 0;
      while i < a.length { parts[parts.length] = `${a[i]}`; i = i + 1; };
      while parts.length > 1 {
        let next = []; let k = 0;
        while k + 1 < parts.length { next[next.length] = parts[k] + separator + parts[k + 1]; k = k + 2; };
        if k < parts.length { next[next.length] = parts[k]; };
        parts = next;
      };
      if parts.length == 0 { return ""; };
      parts[0];
    };
  },
  at: (s, index) -> {
    s = requireString(s, "String.at")?;
    if !Number.check(index) { return std.Error.raise("TypeMismatch", "String.at expects Number index", null); };
    if !finite(index) || index % 1 != 0 || index < -s.length || index >= s.length {
      return std.Error.raise("IndexOutOfBounds", "String index out of bounds", null);
    };
    s[index];
  }
};
export StringLibrary;
