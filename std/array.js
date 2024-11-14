import { fromNative, toNative } from "../runtime/native.js";
import { Void } from "../value/constant.js";

let lib = new Map();
lib.set('length', arr => fromNative(arr.result.value.values.length));
lib.set('add', arr => {
    let func = fromNative((arr, e) => {
        arr.result.value.values.push(e.result);

        return Void;
    });
    func.value.oop = true;

    return func;
});
lib.set('remove', arr => {
    let func = fromNative((arr, index) => {
        arr.result.value.values.splice(toNative(index.result.value), 1);

        return Void;
    });
    func.value.oop = true;

    return func;
});

export default lib;