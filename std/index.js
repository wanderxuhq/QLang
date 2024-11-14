import { PrimeType } from "../type/constant.js";
import array from "./array.js";

let std = new Map();
std.set(PrimeType.Array, array)

const findInStd = (type, attribute) => {
    if (std.has(type)) {
        const lib = std.get(type)
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

export {findInStd}