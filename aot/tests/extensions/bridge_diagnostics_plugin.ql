let fail = () -> 1 / 0;
let apply = (callback) -> callback();
let saved = Error.raise("stored extension error");
let reuse = () -> saved;
export {fail, apply, reuse};
