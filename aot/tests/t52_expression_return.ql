let initializerHits = 0;
let initializerCase = () -> {
  let result = if true { return 7; } else { 0; };
  initializerHits = initializerHits + 1;
  99;
};
let initializerValue = initializerCase();
println("initializer=" + std.String.toString(initializerValue) + ",hits=" + std.String.toString(initializerHits));

let arrayHits = 0;
let arrayCase = () -> {
  let result = [if true { return 7; } else { 0; }];
  arrayHits = arrayHits + 1;
  99;
};
let arrayValue = arrayCase();
println("array=" + std.String.toString(arrayValue) + ",hits=" + std.String.toString(arrayHits));

let consume = (value) -> value;
let argumentHits = 0;
let argumentCase = () -> {
  let result = consume(if true { return 7; } else { 0; });
  argumentHits = argumentHits + 1;
  99;
};
let argumentValue = argumentCase();
println("argument=" + std.String.toString(argumentValue) + ",hits=" + std.String.toString(argumentHits));

let arithmeticHits = 0;
let arithmeticCase = () -> {
  let result = 1 + (if true { return 7; } else { 0; });
  arithmeticHits = arithmeticHits + 1;
  99;
};
let arithmeticValue = arithmeticCase();
println("arithmetic=" + std.String.toString(arithmeticValue) + ",hits=" + std.String.toString(arithmeticHits));

let unaryHits = 0;
let unaryCase = () -> {
  let result = -(if true { return 7; } else { 1; });
  unaryHits = unaryHits + 1;
  99;
};
let unaryValue = unaryCase();
println("unary=" + std.String.toString(unaryValue) + ",hits=" + std.String.toString(unaryHits));

let conditionHits = 0;
let conditionCase = () -> {
  while (if true { return false; } else { false; }) { conditionHits = conditionHits + 1; };
  conditionHits = conditionHits + 10;
  true;
};
let conditionValue = conditionCase();
println("condition=" + std.String.toString(conditionValue) + ",hits=" + std.String.toString(conditionHits));

let receiverHits = 0;
let receiverObject = { value: 0 };
let receiverCase = () -> {
  (if true { return receiverObject; } else { receiverObject; }).value = 3;
  receiverHits = receiverHits + 1;
  99;
};
let receiverValue = receiverCase();
println("receiver=" + std.String.toString(receiverValue == receiverObject) + ",hits=" + std.String.toString(receiverHits) + ",stored=" + std.String.toString(receiverObject.value));

let indexHits = 0;
let indexArray = [0];
let indexCase = () -> {
  (if true { return indexArray; } else { indexArray; })[0] = 3;
  indexHits = indexHits + 1;
  99;
};
let indexValue = indexCase();
println("index=" + std.String.toString(indexValue == indexArray) + ",hits=" + std.String.toString(indexHits) + ",stored=" + std.String.toString(indexArray[0]));

let indexExpressionHits = 0;
let indexExpressionCase = () -> {
  indexArray[if true { return 0; } else { 0; }] = 3;
  indexExpressionHits = indexExpressionHits + 1;
  99;
};
let indexExpressionValue = indexExpressionCase();
println("index-expression=" + std.String.toString(indexExpressionValue) + ",hits=" + std.String.toString(indexExpressionHits) + ",stored=" + std.String.toString(indexArray[0]));

let nestedHits = 0;
let nestedOuter = () -> {
  let nestedInner = () -> { return 13; 99; };
  let result = nestedInner();
  nestedHits = nestedHits + 1;
  result;
};
let nestedValue = nestedOuter();
println("nested=" + std.String.toString(nestedValue) + ",outerHits=" + std.String.toString(nestedHits));
