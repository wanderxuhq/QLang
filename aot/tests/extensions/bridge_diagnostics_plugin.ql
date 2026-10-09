let fail = () -> 1 / zero;
let apply = (callback) -> callback(); let zero = 0;
let saved = Error.raise("stored extension error");
let reuse = () -> saved;
export {fail, apply, reuse};
