// Conservative lexical-frame escape analysis. A function or imported module
// can capture the current frame or one of its descendants. Otherwise the frame
// address cannot escape: QLang exposes values, never raw environment pointers.
// Fail closed for closures even when a more precise free-variable analysis
// could prove they do not capture anything. Do not descend imported graphs.
let lifetimeMayCapture = (node) -> {
  if AnyArray.check(node) {
    let i = 0;
    while i < node.length {
      if lifetimeMayCapture(node[i]) { return true; };
      i = i + 1;
    };
  } else if AnyObject.check(node) {
    if !isError(node.type) && (node.type == "Function" || node.type == "Import") { return true; };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length {
      if lifetimeMayCapture(node[keys[i]]) { return true; };
      i = i + 1;
    };
  };
  false;
};
export lifetimeMayCapture;
