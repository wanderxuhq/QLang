import { PrimeType } from "../type/constant.js";
import number from "./number.js";
import string from "./string.js";
import array from "./array.js";
import object from "./object.js";
import type from "./type.js";
import pair from "./pair.js";

let std = {
    Number: number,
    String: string,
    Array: array,
    Object: object,
    Type: type,
};

const findInStd = (type, attribute) => {
    if (std.has(type.value)) {
        const lib = std.get(type.value)
        if (lib.has(attribute)) {
            return lib.get(attribute);
        } else {
            return null;
        }
    } else {
        return null;
    }
}

//findInStd(PrimeType.Array, 'length')
//findInStd('print');

export {std, findInStd}