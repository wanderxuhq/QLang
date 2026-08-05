// AST node types for QLang
// Bootstrapped QLang implementation

import ./tokens.ql;

let Program = (statements) -> {
  { type: "Program", statements: statements };
};

let LetStmt = (name, value) -> {
  { type: "Let", name: name, value: value };
};

let AssignStmt = (target, value) -> {
  { type: "Assign", target: target, value: value };
};

let IfStmt = (branches, elseBody) -> {
  { type: "If", branches: branches, elseBody: elseBody };
};

let IfBranch = (condition, body) -> {
  { type: "IfBranch", condition: condition, body: body };
};

let WhileStmt = (condition, body) -> {
  { type: "While", condition: condition, body: body };
};

let ReturnStmt = (value) -> {
  { type: "Return", value: value };
};

let ExportStmt = (value) -> {
  { type: "Export", value: value };
};

let Block = (statements) -> {
  { type: "Block", statements: statements };
};

let NumberExpr = (value) -> {
  { type: "Number", value: value };
};

let StringExpr = (value) -> {
  { type: "String", value: value };
};

let BooleanExpr = (value) -> {
  { type: "Boolean", value: value };
};

let NullExpr = () -> {
  { type: "Null" };
};

let IdentifierExpr = (name) -> {
  { type: "Identifier", name: name };
};

let ArrayExpr = (elements) -> {
  { type: "Array", elements: elements };
};

let ObjectExpr = (fields) -> {
  { type: "Object", fields: fields };
};

let ObjectField = (name, value) -> {
  { type: "ObjectField", name: name, value: value };
};

let FunctionExpr = (parameters, body) -> {
  { type: "Function", parameters: parameters, body: body };
};

let Parameter = (name) -> {
  { type: "Parameter", name: name };
};

let CallExpr = (callee, arguments) -> {
  { type: "Call", callee: callee, arguments: arguments };
};

let BinaryOpExpr = (operator, left, right) -> {
  { type: "BinaryOp", operator: operator, left: left, right: right };
};

let MemberAccessExpr = (object, field) -> {
  { type: "MemberAccess", object: object, field: field };
};

let IndexAccessExpr = (object, index) -> {
  { type: "IndexAccess", object: object, index: index };
};

let ImportExpr = (path) -> {
  { type: "Import", path: path };
};

let UnaryOpExpr = (operator, operand) -> {
  { type: "UnaryOp", operator: operator, operand: operand };
};

export {
  Program,
  LetStmt,
  AssignStmt,
  IfStmt,
  IfBranch,
  WhileStmt,
  ReturnStmt,
  ExportStmt,
  Block,
  NumberExpr,
  StringExpr,
  BooleanExpr,
  NullExpr,
  IdentifierExpr,
  ArrayExpr,
  ObjectExpr,
  ObjectField,
  FunctionExpr,
  Parameter,
  CallExpr,
  BinaryOpExpr,
  MemberAccessExpr,
  IndexAccessExpr,
  ImportExpr,
  UnaryOpExpr,
};
