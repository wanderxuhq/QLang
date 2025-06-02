import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runValue } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

export default fromNative(
    {
        toString: fromNative(number => fromNative(number.value.value + '')),
    }
);