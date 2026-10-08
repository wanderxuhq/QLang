println("initialize counter");
let count = 0;
let bump = () -> { count = count + 1; count; };
let box = {value: 1};
export { bump, box };
export let answer = 42;
