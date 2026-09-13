let patchHooks = null;

let rowHooks = null;

function installPatchHooks(o) {
    patchHooks = o;
}

function installRowHooks(o) {
    rowHooks = o;
}

export { installPatchHooks, installRowHooks, patchHooks, rowHooks };