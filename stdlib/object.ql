// Internal Object algorithm candidate. Key enumeration is injected and remains
// the caller's backend-provided primitive for this experiment.
let makeObjectAlgorithms = (enumerateKeys) -> {
  let isObjectReceiver = (value) -> AnyObject.check(value) || std.Type.check(value);

  let containsKey = (keys, wanted) -> {
    let i = 0;
    while i < keys.length {
      if keys[i] == wanted { return true; };
      i = i + 1;
    };
    false;
  };

  let values = (object) -> {
    if !isObjectReceiver(object) {
      return std.Error.raise("TypeMismatch", "Object.values expects Object", null);
    };
    let keys = enumerateKeys(object);
    let result = [];
    let i = 0;
    while i < keys.length {
      let key = keys[i];
      let value = object[key];
      result[result.length] = value;
      i = i + 1;
    };
    result;
  };

  let merge = (left) -> {
    if !isObjectReceiver(left) {
      return std.Error.raise("TypeMismatch", "Object.merge expects Object", null);
    };
    (right) -> {
      if !isObjectReceiver(right) {
        return std.Error.raise("TypeMismatch", "Object.merge expects Object", null);
      };
      let result = {};
      let leftKeys = enumerateKeys(left);
      let i = 0;
      while i < leftKeys.length {
        let key = leftKeys[i];
        let value = left[key];
        result[key] = value;
        i = i + 1;
      };
      let rightKeys = enumerateKeys(right);
      let j = 0;
      while j < rightKeys.length {
        let key = rightKeys[j];
        let value = right[key];
        result[key] = value;
        j = j + 1;
      };
      result;
    };
  };

  let hasOwn = (object) -> {
    if !isObjectReceiver(object) {
      return std.Error.raise("TypeMismatch", "Object.hasOwn expects Object", null);
    };
    (key) -> {
      if !String.check(key) { return false; };
      containsKey(enumerateKeys(object), key);
    };
  };

  let get = (object) -> {
    if !isObjectReceiver(object) {
      return std.Error.raise("TypeMismatch", "Object.get expects Object", null);
    };
    (key) -> {
      if !String.check(key) { return null; };
      if containsKey(enumerateKeys(object), key) {
        let value = object[key];
        return value;
      };
      null;
    };
  };

  let field = (object, key) -> {
    if !isObjectReceiver(object) {
      return std.Error.raise("TypeMismatch", "Object.field expects Object", null);
    };
    if !String.check(key) {
      return std.Error.raise("TypeMismatch", "Object.field expects String key", null);
    };
    if !containsKey(enumerateKeys(object), key) {
      return std.Error.raise("UndefinedField", "Undefined field: " + key, null);
    };
    let value = object[key];
    value;
  };

  { values: values, merge: merge, hasOwn: hasOwn, get: get, field: field };
};

// Key enumeration remains an explicit transitional language dependency.
let ObjectLibrary = makeObjectAlgorithms(std.Object.keys);
export { ObjectLibrary };
