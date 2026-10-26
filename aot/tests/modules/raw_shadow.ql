// Used by t60_raw_direct: an import that binds the same name as a local direct
// target must disable the direct/raw target, so the imported value wins.
export let shadow = (x) -> x + 100;
