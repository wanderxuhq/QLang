import { Ast } from "../ast/index.js";
import { fromNative, wrap } from "../native/fromNative.js";
import { PrimeType } from "../type/constant.js";

let lib = wrap(fromNative({
    new: (key, value) => {
        return {
            type: Ast.VALUE,
            native: true,
            value: {
                key: key,
                value: value
            }
        }
        return wrap( fromNative({
            key: key,
            value: value
        }));
    }
}));

export default lib;