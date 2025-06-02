import { Ast } from "../ast/index.js";
import rootEnv from "../env.js";
import { fromNative, wrap } from "../native/fromNative.js";
import toNative from "../native/toNative.js";
import { runValue } from "../runtime/run-value.js";
import { Void } from "../value/constant.js";

export default fromNative(handler => {
    let proxyObj = {};
    const get = handler.value.fields.find(e => e.key.value === 'get');
    if (get) {
        proxyObj.get = get;
    }
    return proxyObj;
});
