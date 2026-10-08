// Internal evaluator/native value bridge. Both sides retain their own storage
// format; memoized pairs preserve aliases and cycles at synchronous call edges.
// Envelopes let Error values cross internal helpers without changing the public
// rule that ordinary functions reject Error arguments.
import ./stdlib.ql;

let NativeValues = (host, canonical, invoke) -> {
  let pairs = [];
  let wrapped = (value) -> value != null && !isError(value.type);
  let coreKey = (value) -> {
    if wrapped(value) && (value.type == "Object" || value.type == "Type" || value.type == "Array") { value.value; }
    else { value; };
  };
  let findCore = (value) -> {
    let key = coreKey(value); let i = 0;
    while i < pairs.length {
      if pairs[i].key == key { return pairs[i]; }; i = i + 1;
    };
    null;
  };
  let findHost = (value) -> {
    let i = 0;
    while i < pairs.length {
      if pairs[i].host == value { return pairs[i]; }; i = i + 1;
    };
    null;
  };
  let remember = (core, native, kind, rawCore) -> {
    let pair = {core: core, key: coreKey(core), host: native, kind: kind, rawCore: rawCore};
    pairs[pairs.length] = pair; pair;
  };
  let i = 0;
  while i < canonical.length {
    remember(canonical[i].core, canonical[i].host, "Canonical", true); i = i + 1;
  };
  let copied = (pair, seen) -> {
    let i = 0;
    while i < seen.length { if seen[i] == pair { return true; }; i = i + 1; };
    seen[seen.length] = pair; false;
  };
  let copy = (pair, outward, seen) -> {
    if pair.kind == "Canonical" || pair.kind == "Function" || copied(pair, seen) { return null; };
    let core = pair.key;
    let source = if outward { core; } else { pair.host; };
    let dest = if outward { pair.host; } else { core; };
    if pair.kind == "Array" {
      let i = 0;
      while i < source.length {
        let box = {value: source[i]};
        if outward { dest[i] = out(box, seen); } else { dest[i] = into(box, seen); };
        i = i + 1;
      };
      while dest.length > source.length { dest.remove(dest.length - 1); };
    } else {
      let keys = std.Object.keys(source); let i = 0;
      while i < keys.length {
        let key = keys[i]; let box = {value: source[key]};
        if outward { dest[key] = out(box, seen); } else { dest[key] = into(box, seen); };
        i = i + 1;
      };
    };
    null;
  };
  let synchronize = (outward) -> {
    let seen = []; let i = 0;
    while i < pairs.length { copy(pairs[i], outward, seen); i = i + 1; };
    null;
  };
  let out = (box, seen) -> {
    let value = box.value;
    if isError(value) { return value; };
    if value == null { return null; };
    let tag = if wrapped(value) { value.type; } else { typeTag(value); };
    if tag == "Error" { return value.value; };
    if tag == "Null" { return null; };
    if tag == "Number" || tag == "String" || tag == "Boolean" {
      if wrapped(value) { return value.value; }; return value;
    };
    let pair = findCore(value);
    if pair != null { copy(pair, true, seen); return pair.host; };
    if tag == "Function" {
      // Existing native functions already consume native values and carry their
      // own Error policy. Preserve their identity and metadata across modules.
      if !wrapped(value) && !isError(value.name) {
        remember(value, value, "Function", false); return value;
      };
      // The evaluator owns arity, annotations, partials and predicate exemptions.
      // The host adapter forwards the borrowed argument list synchronously.
      let callback = (arguments, exempt) -> {
        synchronize(false);
        let args = []; let i = 0; let visited = [];
        while i < arguments.length { args[i] = into({value: arguments[i]}, visited); i = i + 1; };
        let result = invoke(value, args, exempt);
        synchronize(true);
        out({value: result}, []);
      };
      let name = null;
      if wrapped(value) && !isError(value.boundArgs) { name = "<curried>"; };
      if wrapped(value) && !isError(value.boundArray) { name = "Array." + value.boundMethod; };
      let native = host.callback(callback, name);
      remember(value, native, "Function", false); return native;
    };
    let native = if tag == "Array" { []; } else { {}; };
    pair = remember(value, native, tag, !wrapped(value));
    copy(pair, true, seen); native;
  };
  let into = (box, seen) -> {
    let value = box.value;
    if isError(value) { return {type: "Error", value: value, propagate: false}; };
    let tag = typeTag(value);
    if tag == "Number" || tag == "String" || tag == "Boolean" || tag == "Null" { return {type: tag, value: value}; };
    let pair = findHost(value);
    if pair != null { copy(pair, false, seen); return pair.core; };
    if tag == "Function" {
      let core = {type: "Function", extensionFunction: value};
      remember(core, value, "Function", false); return core;
    };
    let fields = if tag == "Array" { []; } else { {}; };
    let core = {type: tag, value: fields};
    pair = remember(core, value, tag, false);
    copy(pair, false, seen); core;
  };
  let call = (func, arguments, exempt) -> {
    synchronize(true);
    let args = []; let i = 0; let seen = [];
    while i < arguments.length { args[i] = out({value: arguments[i]}, seen); i = i + 1; };
    let result = host.call(func, args, exempt);
    synchronize(false);
    into({value: result}, []);
  };
  let load = (path, origin, arguments) -> {
    synchronize(true);
    let rawPath = out({value: path}, []);
    // Keep Error paths in an Array: the loader's own call policy reports them.
    let result = host.call(host.load, [rawPath, origin, out({value: arguments}, [])], false);
    synchronize(false);
    into({value: result}, []);
  };
  {call: call, load: load, toHost: (box) -> out(box, []), toCore: (box) -> into(box, []), push: () -> synchronize(true), pull: () -> synchronize(false)};
};
export NativeValues;
