import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runValue } from "../runtime/run-value.js";
import { equal, PrimeType } from "../type/constant.js";
import { Void } from "../value/constant.js";

export default fromNative(
    {
        toString: fromNative(value => {
            if (equal(value.value.type, PrimeType.String)) {
                return value;
            } else {
                return fromNative(JSON.stringify(toNative(value)));
            }
        }),
        concat: fromNative((str1, str2) => {
            const v1 = runValue(str1.env)(str1).value;
            const v2 = runValue(str2.env)(str2).value;

            let v1Value;
            let v2Value;

            if (!equal(v1.value.type, PrimeType.String)) {
                v1Value = JSON.stringify(toNative(v1));
            } else {
                v1Value = toNative(v1);
            }
            if (!equal(v2.value.type, PrimeType.String)) {
                v2Value = JSON.stringify(toNative(v2));
            } else {
                v2Value = toNative(v2);
            }

            return fromNative(v1Value + v2Value);
        })
    }
);