// Restore original source positions after source packaging. Semantic AST fields
// and annotation text remain unchanged; synthetic wrapper ranges stay virtual.
let remapSourceLocations = (program, virtualPath, origins) -> {
  let remap = (point) -> {
    if point.file != virtualPath { return point; };
    let i = 0;
    while i < origins.length {
      let origin = origins[i];
      let inside = point.line >= origin.startLine && point.line <= origin.endLine;
      let endInside = point.endLine <= origin.endLine || (point.endLine == origin.endLine + 1 && point.endCol == 1);
      if inside && endInside {
        let line = point.line - origin.startLine + 1;
        let endLine = point.endLine - origin.startLine + 1;
        let start = origin.sourceLineStarts[line - 1] + point.col - 1;
        let end = origin.sourceLength;
        if endLine <= origin.sourceLineStarts.length {
          end = origin.sourceLineStarts[endLine - 1] + point.endCol - 1;
        };
        if end > origin.sourceLength { end = origin.sourceLength; };
        // The packager adds a final newline if absent. That boundary is EOF in
        // the original file, not a fictitious extra source line.
        let endCol = point.endCol;
        if endLine > origin.sourceLineStarts.length {
          endLine = origin.sourceLineStarts.length;
          endCol = end - origin.sourceLineStarts[endLine - 1] + 1;
        };
        point.file = origin.path; point.line = line; point.endLine = endLine;
        point.endCol = endCol; point.span = {start: start, end: end};
        return point;
      };
      i = i + 1;
    };
    point;
  };
  let diagnosticText = (d) -> d.file + ":" + std.String.toString(d.line) + ":" + std.String.toString(d.col) + ": " + d.message;
  let visit = (node) -> {
    if AnyArray.check(node) {
      let i = 0; while i < node.length { visit(node[i]); i = i + 1; };
    } else if AnyObject.check(node) {
      if !isError(node.location) { remap(node.location); };
      if !isError(node.diagnostic) { remap(node.diagnostic); node.message = diagnosticText(node.diagnostic); };
      let keys = std.Object.keys(node); let i = 0;
      while i < keys.length {
        let key = keys[i];
        if key != "location" && key != "diagnostic" && key != "diagnostics" && key != "errors" { visit(node[key]); };
        i = i + 1;
      };
    };
  };
  visit(program);
  let i = 0;
  while i < program.diagnostics.length {
    let diagnostic = remap(program.diagnostics[i]);
    program.errors[i] = diagnosticText(diagnostic); i = i + 1;
  };
  program;
};
export remapSourceLocations;
