import { notMatch, isMatch } from './match.js';

const parseSeq = source => (index, parser) => {
    let result = {
        start: index,
        end: index,
        result: []
    }
    for (const p of parser) {
        const parseResult = p(source)(result.end);

        if (isMatch(parseResult)) {
            result.result.push(parseResult);
            result.end = parseResult.end;
        } else {
            return notMatch(index);
        }
    }

    return result;
}

const matchParse = str => (index, parses) => {
    for (const parse of parses) {
        const p = parse(str)(index)
        if (isMatch(p)) {
            return p;
        }
    }

    return notMatch(index);
}

export {
    parseSeq,
    matchParse
}