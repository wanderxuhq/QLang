const notMatch = (index) => {
    return {
        type: 'NOT_MATCH',
        start: index,
        end: index,
        length: 0
    }
}

const isMatch = (snip) => {
    return snip.type !== 'NOT_MATCH';
}

const parseFail = message => source => (start, end) => {
    console.log(`Parse failed: ${message}: ${source.substring(start, end)}`)
    return {
        type: 'PARSE_FAIL',
        start: start,
        end: end
    }
}
export {
    notMatch, isMatch, parseFail
}