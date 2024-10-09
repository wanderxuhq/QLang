import {notMatch} from './match.js'

const parseConst = token => source => index => {
    if (source.substring(index, index + token.length) === token) {
        return {
            type: token,
            start: index,
            end: index + token.length
        }
    } else {
        return notMatch(index);
    }
}

export {parseConst};
