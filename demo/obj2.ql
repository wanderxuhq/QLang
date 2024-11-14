let createMap = x -> {
    let cache = [['a', 2]];
    return {
        put = (key, value) -> {
            cache = [[key, value]]
            //debug(cache)
            //print('\n')
        },
        get = key -> {
            let index = 0;
            while (index < 1) {
                //print(cache)
                //print('\n')
                if (cache[index][0] == key) {
                    return cache[index][1];
                }
                index = index + 1;
            }

            return 3
        }
    }
};

let map = createMap(1);
//print('\n')
//print(map.get('a'));
//print('\n')
//map.get('a')
map.put('a', {x = 6});
print(map.get('a').x);
print('\n')
//debug(1)
//print('\n')
map.put('b', {x = 7});
print(map.get('b').x);
print('\n')