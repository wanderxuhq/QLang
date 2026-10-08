let loadB = () -> { let b = import ./b.ql; b.value; };
export {loadB, name: "A"};
