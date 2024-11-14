import { Ast } from "../ast/index.js";
import { PrimeType } from "../type/constant.js";

const Void = {
    type: Ast.VALUE,
    value: {
        type: PrimeType.Void
    }
}

export {Void}
