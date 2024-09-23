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

export {
    notMatch, isMatch
}