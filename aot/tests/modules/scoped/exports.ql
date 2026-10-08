if true { let private = 7; export {chosen: private}; };
if false { export {preserved: 100, absent: 101}; };
let publish = (value) -> { export let later = value; };
let publishPartial = (a, b) -> { export let summed = a + b; };
publish(5);
let load = () -> {
  let result = import ./value.ql;
  {value: result.answer, local: answer, next: result.bump};
};
let branch = (run) -> {
  if run { import ./value.ql; answer; } else { 0; };
};
export {publish, publishPartial, load, branch};
