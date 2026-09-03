(() => {
  var __defProp = Object.defineProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // node_modules/hondo/packages/core/src/bridge.ts
  function encodeHondoValue(value) {
    if (value == null) return null;
    switch (typeof value) {
      case "boolean":
      case "number":
      case "string":
        return value;
      case "undefined":
        return null;
      case "object": {
        if (Array.isArray(value)) return value.map(encodeHondoValue);
        const encoded = {};
        for (const [key, item] of Object.entries(value)) {
          encoded[key] = encodeHondoValue(item);
        }
        return encoded;
      }
      default:
        throw new TypeError(`Unsupported Hondo bridge value: ${typeof value}`);
    }
  }
  function resolveNativeHostCall() {
    const hostCall = globalThis.__hondoHostCall;
    if (typeof hostCall !== "function") {
      throw new Error("Hondo native host call is not installed");
    }
    return hostCall;
  }
  var NativeMutationBridge = class {
    constructor(hostCall = resolveNativeHostCall()) {
      __publicField(this, "hostCall", hostCall);
    }
    createElement(id, type) {
      this.hostCall("createElement", id, type);
    }
    createTextNode(id, value) {
      this.hostCall("createTextNode", id, value);
    }
    replaceText(id, value) {
      this.hostCall("replaceText", id, value);
    }
    setProperty(id, name, value) {
      const encoded = JSON.stringify(value);
      if (encoded === void 0) throw new TypeError("Hondo property value is not serializable");
      this.hostCall("setProperty", id, name, encoded);
    }
    insertNode(parentId, nodeId, anchorId) {
      this.hostCall("insertNode", parentId, nodeId, anchorId);
    }
    removeNode(parentId, nodeId) {
      this.hostCall("removeNode", parentId, nodeId);
    }
  };

  // node_modules/hondo/packages/core/src/events.ts
  var handlers = /* @__PURE__ */ new Map();
  function decodePayload(payloadJson) {
    const value = JSON.parse(payloadJson);
    return value;
  }
  function dispatchNativeEvent(name, payloadJson) {
    const listeners = handlers.get(name);
    if (!listeners || listeners.size === 0) return;
    const payload = decodePayload(payloadJson);
    for (const listener of [...listeners]) listener(payload);
  }
  var globals = globalThis;
  if (typeof globals.__hondoDispatchNativeEvent !== "function") {
    globals.__hondoDispatchNativeEvent = dispatchNativeEvent;
  }

  // node_modules/hondo/packages/core/src/host.ts
  var HondoHost = class {
    constructor(bridge) {
      __publicField(this, "bridge", bridge);
      __publicField(this, "root", {
        id: 0,
        type: "root",
        isText: false,
        parent: null,
        children: [],
        textValue: null
      });
      __publicField(this, "nextNodeId", 1);
      __publicField(this, "nodes", /* @__PURE__ */ new Map());
      __publicField(this, "eventHandlers", /* @__PURE__ */ new Map());
      this.nodes.set(this.root.id, this.root);
    }
    createElement(type) {
      const node = this.createHostNode(type, false, null);
      this.bridge.createElement(node.id, type);
      return node;
    }
    createTextNode(value) {
      const node = this.createHostNode("#text", true, value);
      this.bridge.createTextNode(node.id, value);
      return node;
    }
    replaceText(node, value) {
      if (!node.isText) throw new TypeError("replaceText requires a Hondo text node");
      if (node.textValue === value) return;
      node.textValue = value;
      this.bridge.replaceText(node.id, value);
    }
    setProperty(node, name, value) {
      const registration = parseEventProperty(name);
      if (registration) {
        this.setEventHandler(node, registration, value);
        return;
      }
      this.bridge.setProperty(node.id, name, encodeHondoValue(value));
    }
    insertNode(parent, node, anchor) {
      if (node === parent) throw new Error("A Hondo node cannot contain itself");
      if (anchor === node) throw new Error("A Hondo node cannot be its own insertion anchor");
      if (anchor && anchor.parent !== parent) {
        throw new Error("Hondo insertion anchor must be a child of the target parent");
      }
      if (node.parent) {
        const previousIndex = node.parent.children.indexOf(node);
        if (previousIndex >= 0) node.parent.children.splice(previousIndex, 1);
      }
      const anchorIndex = anchor ? parent.children.indexOf(anchor) : -1;
      const insertionIndex = anchorIndex >= 0 ? anchorIndex : parent.children.length;
      parent.children.splice(insertionIndex, 0, node);
      node.parent = parent;
      this.bridge.insertNode(parent.id, node.id, anchor?.id ?? null);
    }
    removeNode(parent, node) {
      const index = parent.children.indexOf(node);
      if (index < 0 || node.parent !== parent) {
        throw new Error("Cannot remove a node that is not a child of the supplied parent");
      }
      parent.children.splice(index, 1);
      node.parent = null;
      this.bridge.removeNode(parent.id, node.id);
    }
    isTextNode(node) {
      return node.isText;
    }
    getParentNode(node) {
      return node.parent ?? void 0;
    }
    getFirstChild(node) {
      return node.children[0];
    }
    getNextSibling(node) {
      const parent = node.parent;
      if (!parent) return void 0;
      const index = parent.children.indexOf(node);
      return index >= 0 ? parent.children[index + 1] : void 0;
    }
    getNodeById(id) {
      return this.nodes.get(id);
    }
    dispatchNodeEvent(targetId, type, payload) {
      const target = this.nodes.get(targetId);
      if (!target) throw new Error(`Unknown Hondo event target: ${targetId}`);
      if (!type) throw new TypeError("Hondo node event type cannot be empty");
      const path2 = [];
      for (let node = target; node; node = node.parent) path2.push(node);
      const event = {
        type,
        target,
        payload,
        currentTarget: null,
        phase: "capture",
        propagationStopped: false,
        defaultPrevented: false,
        stopPropagation() {
          this.propagationStopped = true;
        },
        preventDefault() {
          this.defaultPrevented = true;
        }
      };
      for (let index = path2.length - 1; index >= 1; index -= 1) {
        this.invokeNodeHandler(path2[index], type, true, event, "capture");
        if (event.propagationStopped) {
          event.currentTarget = null;
          return eventResult(event);
        }
      }
      this.invokeNodeHandler(target, type, true, event, "target");
      this.invokeNodeHandler(target, type, false, event, "target");
      if (!event.propagationStopped) {
        for (let index = 1; index < path2.length; index += 1) {
          this.invokeNodeHandler(path2[index], type, false, event, "bubble");
          if (event.propagationStopped) break;
        }
      }
      event.currentTarget = null;
      return eventResult(event);
    }
    createHostNode(type, isText, textValue) {
      const node = {
        id: this.nextNodeId++,
        type,
        isText,
        parent: null,
        children: [],
        textValue
      };
      this.nodes.set(node.id, node);
      return node;
    }
    setEventHandler(node, registration, value) {
      const key = eventHandlerKey(registration.type, registration.capture);
      if (value == null || value === false) {
        const handlers3 = this.eventHandlers.get(node.id);
        handlers3?.delete(key);
        if (handlers3?.size === 0) this.eventHandlers.delete(node.id);
        return;
      }
      if (typeof value !== "function") {
        throw new TypeError(`${registration.capture ? "capture " : ""}${registration.type} handler must be a function`);
      }
      let handlers2 = this.eventHandlers.get(node.id);
      if (!handlers2) {
        handlers2 = /* @__PURE__ */ new Map();
        this.eventHandlers.set(node.id, handlers2);
      }
      handlers2.set(key, value);
    }
    invokeNodeHandler(node, type, capture, event, phase) {
      const handler = this.eventHandlers.get(node.id)?.get(eventHandlerKey(type, capture));
      if (!handler) return;
      event.currentTarget = node;
      event.phase = phase;
      handler(event);
    }
  };
  function parseEventProperty(name) {
    if (!/^on[A-Z]/.test(name)) return void 0;
    let eventName = name.slice(2);
    let capture = false;
    if (eventName.endsWith("Capture")) {
      capture = true;
      eventName = eventName.slice(0, -"Capture".length);
    }
    if (!eventName) return void 0;
    return {
      type: eventName[0].toLowerCase() + eventName.slice(1),
      capture
    };
  }
  function eventHandlerKey(type, capture) {
    return `${type}:${capture ? "capture" : "bubble"}`;
  }
  function eventResult(event) {
    return {
      defaultPrevented: event.defaultPrevented,
      propagationStopped: event.propagationStopped
    };
  }
  var activeHost;
  function installHost(host2) {
    const previous = activeHost;
    activeHost = host2;
    let restored = false;
    return () => {
      if (restored) return;
      restored = true;
      if (activeHost === host2) activeHost = previous;
    };
  }
  function getHost() {
    if (!activeHost) throw new Error("No Hondo host is installed");
    return activeHost;
  }
  var globals2 = globalThis;
  if (typeof globals2.__hondoDispatchNodeEvent !== "function") {
    globals2.__hondoDispatchNodeEvent = (targetId, type, payloadJson) => {
      const payload = JSON.parse(payloadJson);
      return getHost().dispatchNodeEvent(targetId, type, payload).defaultPrevented;
    };
  }

  // node_modules/@solidjs/signals/dist/prod/core/error.js
  var NotReadyError = class extends Error {
    constructor(r) {
      const o = Error;
      const t = o.stackTraceLimit;
      if (t !== void 0) o.stackTraceLimit = 0;
      super();
      __publicField(this, "source");
      if (t !== void 0) o.stackTraceLimit = t;
      this.source = r;
    }
  };
  var StatusError = class extends Error {
    constructor(r, o) {
      super(o instanceof Error ? o.message : String(o), {
        cause: o
      });
      __publicField(this, "source");
      this.source = r;
    }
  };
  function unwrapStatusError(r) {
    return r instanceof StatusError ? r.cause : r;
  }

  // node_modules/@solidjs/signals/dist/prod/core/constants.js
  var REACTIVE_NONE = 0;
  var REACTIVE_CHECK = 1 << 0;
  var REACTIVE_DIRTY = 1 << 1;
  var REACTIVE_RECOMPUTING_DEPS = 1 << 2;
  var REACTIVE_IN_HEAP = 1 << 3;
  var REACTIVE_IN_HEAP_HEIGHT = 1 << 4;
  var REACTIVE_ZOMBIE = 1 << 5;
  var REACTIVE_DISPOSED = 1 << 6;
  var REACTIVE_OPTIMISTIC_DIRTY = 1 << 7;
  var REACTIVE_SNAPSHOT_STALE = 1 << 8;
  var REACTIVE_LAZY = 1 << 9;
  var REACTIVE_MANUAL_WRITE = 1 << 10;
  var REACTIVE_REASK = 1 << 11;
  var REACTIVE_MISSED_WAKE = 1 << 12;
  var CONFIG_OWNED_WRITE = 1 << 0;
  var CONFIG_NO_SNAPSHOT = 1 << 1;
  var CONFIG_TRANSPARENT = 1 << 2;
  var CONFIG_IN_SNAPSHOT_SCOPE = 1 << 3;
  var CONFIG_CHILDREN_FORBIDDEN = 1 << 4;
  var CONFIG_AUTO_DISPOSE = 1 << 5;
  var CONFIG_SYNC = 1 << 6;
  var CONFIG_OPTIMISTIC = 1 << 7;
  var CONFIG_HAS_COMPANIONS = 1 << 8;
  var CONFIG_HAS_SNAPSHOT = 1 << 9;
  var CONFIG_HAS_LANE = 1 << 10;
  var CONFIG_CHILD_COMPANIONS = 1 << 11;
  var CONFIG_FW_CHILDREN = 1 << 12;
  var CONFIG_AUTHORITATIVE_READ = 1 << 13;
  var CONFIG_AUTHORITATIVE_OBSERVED = 1 << 14;
  var CONFIG_DIRECT_COMMIT = 1 << 15;
  var CONFIG_FRESH_READ = 1 << 16;
  var CONFIG_HELD_TRUTH = 1 << 17;
  var STATUS_PENDING = 1 << 0;
  var STATUS_ERROR = 1 << 1;
  var STATUS_UNINITIALIZED = 1 << 2;
  var EFFECT_RENDER = 1;
  var EFFECT_USER = 2;
  var EFFECT_TRACKED = 3;
  var NOT_PENDING = {};
  var NO_SNAPSHOT = {};
  var OVERRIDE_UNDEFINED = {};
  function unwrapOverride(E) {
    return E === OVERRIDE_UNDEFINED ? void 0 : E;
  }
  var SUPPORTS_PROXY = typeof Proxy === "function";
  var defaultContext = {};
  var $REFRESH = /* @__PURE__ */ Symbol("refresh");

  // node_modules/@solidjs/signals/dist/prod/core/lanes.js
  var activeLanes = /* @__PURE__ */ new Set();
  function findLane(n) {
    while (n.rn) n = n.rn;
    return n;
  }
  function mergeLanes(n, e) {
    n = findLane(n);
    e = findLane(e);
    if (n === e) return n;
    e.rn = n;
    for (const i of e.Oe) n.Oe.add(i);
    e.Oe.clear();
    n.tn[0].push(...e.tn[0]);
    n.tn[1].push(...e.tn[1]);
    e.tn[0].length = 0;
    e.tn[1].length = 0;
    return n;
  }
  function resolveLane(n) {
    const e = n.o?.Je;
    if (!e) return void 0;
    const i = findLane(e);
    if (activeLanes.has(i)) return i;
    if (n.o !== null) n.o.Je = void 0;
    return void 0;
  }
  function resolveTransition(n) {
    if (hasActiveOverride(n) && n.o?.Nt) {
      const e = ext(n).Nt = currentTransition(n.o?.Nt);
      if (e.sn !== true) return e;
      if (n.o !== null) n.o.Nt = null;
    }
    return resolveLane(n)?.Ae ?? n.Ae;
  }
  function hasActiveOverride(n) {
    const e = n.o;
    return e !== null && e.Pe !== void 0 && e.Pe !== NOT_PENDING;
  }
  function assignOrMergeLane(n, e) {
    const i = findLane(e);
    const t = n.o?.Je;
    if (t) {
      if (t.rn) {
        ext(n).Je = e;
        n.T |= CONFIG_HAS_LANE;
        return;
      }
      const r = findLane(t);
      if (activeLanes.has(r)) {
        if (r !== i && !hasActiveOverride(n)) {
          if (i.an && findLane(i.an) === r) {
            ext(n).Je = e;
            n.T |= CONFIG_HAS_LANE;
          } else if (r.an && findLane(r.an) === i) ;
          else mergeLanes(i, r);
        }
        return;
      }
    }
    ext(n).Je = e;
    n.T |= CONFIG_HAS_LANE;
  }

  // node_modules/@solidjs/signals/dist/prod/core/scheduler.js
  var transitions = /* @__PURE__ */ new Set();
  var dirtyQueue = {
    eE: new Array(2e3).fill(void 0),
    tE: false,
    Qe: 0,
    EE: 0
  };
  var zombieQueue = {
    eE: new Array(2e3).fill(void 0),
    tE: false,
    Qe: 0,
    EE: 0
  };
  function cancelZombieRecompute(e) {
    if (e.ie & REACTIVE_IN_HEAP_HEIGHT) e.ie &= -12;
    else {
      deleteFromHeap(e, zombieQueue);
      e.ie &= -4;
    }
  }
  var clock = 0;
  var activeTransition = null;
  var scheduled = false;
  var halted = false;
  var haltNotified = false;
  var syncDepth = 0;
  var projectionWriteActive = false;
  var transientStoreNodes = /* @__PURE__ */ new Set();
  function canUseSimpleSyncFlush(e) {
    const t = e.m;
    return transitions.size === 0 && activeLanes.size === 0 && e.Qt.length === 0 && t.ze.length === 0 && t.A.length === 0 && t.En.size === 0 && transientStoreNodes.size === 0;
  }
  function sweepTransientStoreNodes() {
    if (transientStoreNodes.size === 0) return;
    for (const e of transientStoreNodes) {
      if (e.u !== null) {
        transientStoreNodes.delete(e);
        continue;
      }
      if (e.Re !== NOT_PENDING) continue;
      if (e.o?.Pe !== void 0 && e.o?.Pe !== NOT_PENDING) continue;
      if (e.o?.t) continue;
      transientStoreNodes.delete(e);
      e.o?.Et?.();
    }
  }
  function createBatch() {
    return {
      Te: clock,
      Lt: [],
      _e: /* @__PURE__ */ new Map(),
      ze: [],
      A: [],
      En: /* @__PURE__ */ new Set(),
      ue: [],
      Bt: {
        Mt: [[], []],
        Qt: []
      },
      sn: false,
      cn: /* @__PURE__ */ new Set()
    };
  }
  function mergeTransitionState(e, t) {
    t.sn = e;
    e.ue.push(...t.ue);
    for (const i2 of activeLanes) if (i2.Ae === t) i2.Ae = e;
    if (t.ze.length) {
      e.ze.push(...t.ze);
      t.ze.length = 0;
    }
    if (t.A.length) {
      e.A.push(...t.A);
      t.A.length = 0;
    }
    for (const i2 of t.En) e.En.add(i2);
    const i = t.wt;
    if (i !== void 0) {
      t.wt = void 0;
      let n = e.wt;
      if (n !== void 0) n.push(...i);
      else n = e.wt = i;
      for (let e2 = 0; e2 < i.length; e2++) {
        const t2 = i[e2].pc;
        if (t2 !== void 0 && t2.qe === i[e2]) t2.qa = n;
      }
    }
    for (const [i2, n] of t._e) {
      let t2 = e._e.get(i2);
      if (!t2) e._e.set(i2, t2 = /* @__PURE__ */ new Set());
      for (const e2 of n) t2.add(e2);
    }
    for (const i2 of t.cn) e.cn.add(i2);
  }
  function schedule() {
    if (halted) {
      notifyHalted();
      return;
    }
    if (scheduled) return;
    scheduled = true;
    if (!syncDepth && !globalQueue.fn && !projectionWriteActive) queueMicrotask(flush);
  }
  function haltReactivity(e) {
    if (halted) return;
    halted = true;
    let t = "[REACTIVITY_HALTED]";
    e === void 0 ? console.error(t) : console.error(t, e);
  }
  function notifyHalted() {
    if (haltNotified) return;
    haltNotified = true;
    console.error("[REACTIVITY_HALTED]");
  }
  var queueRunToken = 0;
  var Queue = class {
    constructor() {
      __publicField(this, "ke", null);
      __publicField(this, "Mt", [[], []]);
      __publicField(this, "Qt", []);
      __publicField(this, "jt", 0);
      __publicField(this, "created", clock);
    }
    addChild(e) {
      this.Qt.push(e);
      e.ke = this;
    }
    removeChild(e) {
      const t = this.Qt.indexOf(e);
      if (t >= 0) {
        this.Qt.splice(t, 1);
        e.ke = null;
      }
    }
    notify(e, t, i, n) {
      if (this.ke) return this.ke.notify(e, t, i, n);
      return false;
    }
    run(e) {
      if (this.Mt[e - 1].length) {
        const t2 = this.Mt[e - 1];
        this.Mt[e - 1] = [];
        runQueue(t2, e);
      }
      const t = this.Qt;
      const i = ++queueRunToken;
      for (let n = 0; n < t.length; ) {
        const r = t[n];
        if (r.jt !== i) {
          r.jt = i;
          r.run?.(e);
          if (t[n] !== r) {
            n = 0;
            continue;
          }
        }
        n++;
      }
    }
    enqueue(e, t) {
      if (e) {
        if (currentOptimisticLane) {
          const i = findLane(currentOptimisticLane);
          i.tn[e - 1].push(t);
        } else {
          this.Mt[e - 1].push(t);
        }
      }
      schedule();
    }
    stashQueues(e) {
      e.Mt[0].push(...this.Mt[0]);
      e.Mt[1].push(...this.Mt[1]);
      this.Mt = [[], []];
      for (let t = 0; t < this.Qt.length; t++) {
        let i = this.Qt[t];
        let n = e.Qt[t];
        if (!n) {
          n = {
            Mt: [[], []],
            Qt: []
          };
          e.Qt[t] = n;
        }
        i.stashQueues(n);
      }
    }
    restoreQueues(e) {
      this.Mt[0].push(...e.Mt[0]);
      this.Mt[1].push(...e.Mt[1]);
      for (let t = 0; t < e.Qt.length; t++) {
        const i = e.Qt[t];
        let n = this.Qt[t];
        if (n) n.restoreQueues(i);
      }
    }
  };
  var _GlobalQueue = class _GlobalQueue extends Queue {
    constructor() {
      super(...arguments);
      __publicField(this, "fn", false);
      // The current transaction-shaped batch: a plain ambient batch while no
      // transition is active, the active transition itself after initTransition.
      __publicField(this, "m", createBatch());
    }
    flush() {
      if (this.fn) return;
      if (activeTransition === null && dirtyQueue.EE < dirtyQueue.Qe && this.Mt[0].length === 0 && this.Mt[1].length === 0 && this.Qt.length === 0 && canUseSimpleSyncFlush(this)) {
        this.fn = true;
        try {
          sweepDormant();
          commitPendingNodes();
        } finally {
          this.fn = false;
        }
        clock++;
        scheduled = dirtyQueue.EE >= dirtyQueue.Qe || this.Mt[0].length !== 0 || this.Mt[1].length !== 0 || this.m.Lt.length !== 0;
        return;
      }
      this.fn = true;
      try {
        if (false) ;
        sweepDormant();
        runHeap(dirtyQueue, _GlobalQueue.Fe);
        if (activeTransition) {
          const e = transitionComplete(activeTransition);
          if (!e) {
            const e2 = activeTransition;
            runHeap(zombieQueue, this.m === e2 ? cancelZombieRecompute : _GlobalQueue.Fe);
            if (this.m === e2) currentBatch = this.m = createBatch();
            if (activeLanes.size) {
              _GlobalQueue.Nn(EFFECT_RENDER);
              _GlobalQueue.Nn(EFFECT_USER);
            }
            this.stashQueues(e2.Bt);
            clock++;
            scheduled = dirtyQueue.EE >= dirtyQueue.Qe || this.m.Lt.length > 0;
            reassignPendingTransition(e2.Lt);
            activeTransition = null;
            finalizePureQueue(null, true);
            return;
          }
          const t = activeTransition;
          const i = this.m;
          i !== t && i.Lt.push(...t.Lt);
          this.restoreQueues(t.Bt);
          transitions.delete(t);
          activeTransition = null;
          reassignPendingTransition(i.Lt);
          finalizePureQueue(t);
          if (i === t) {
            const e2 = createBatch();
            e2.Lt = i.Lt;
            e2.ze = i.ze;
            e2.A = i.A;
            e2.En = i.En;
            currentBatch = this.m = e2;
          }
        } else {
          if (canUseSimpleSyncFlush(this)) {
            commitPendingNodes();
            if (dirtyQueue.EE >= dirtyQueue.Qe) {
              runHeap(dirtyQueue, _GlobalQueue.Fe);
              commitPendingNodes();
            }
          } else {
            if (transitions.size) runHeap(zombieQueue, _GlobalQueue.Fe);
            finalizePureQueue();
          }
        }
        clock++;
        scheduled = dirtyQueue.EE >= dirtyQueue.Qe;
        activeLanes.size && _GlobalQueue.Nn(EFFECT_RENDER);
        this.run(EFFECT_RENDER);
        activeLanes.size && _GlobalQueue.Nn(EFFECT_USER);
        this.run(EFFECT_USER);
        if (false) ;
        if (false) ;
        if (false) ;
      } finally {
        this.fn = false;
      }
    }
    notify(e, t, i, n) {
      if (t & STATUS_PENDING) {
        if (i & STATUS_PENDING) {
          const t2 = n !== void 0 ? n : e.o?._;
          if (t2?.l) return true;
          if (activeTransition && t2) {
            const i2 = t2.source;
            let n2 = activeTransition._e.get(i2);
            if (!n2) activeTransition._e.set(i2, n2 = /* @__PURE__ */ new Set());
            const r = n2.size;
            n2.add(e);
            if (n2.size !== r) {
              schedule();
              _GlobalQueue.zt?.(activeTransition);
            }
          }
        }
        return true;
      }
      return false;
    }
    initTransition(e) {
      if (e) {
        e = currentTransition(e);
        if (e.sn === true || e === activeTransition) return;
      }
      if (!e && activeTransition && activeTransition.Te === clock) return;
      if (!activeTransition) {
        activeTransition = e ?? createBatch();
      } else if (e) {
        const t2 = activeTransition;
        mergeTransitionState(e, t2);
        transitions.delete(t2);
        activeTransition = e;
      }
      transitions.add(activeTransition);
      activeTransition.Te = clock;
      const t = this.m;
      if (t !== activeTransition) {
        for (let e2 = 0; e2 < t.Lt.length; e2++) {
          const i = t.Lt[e2];
          i.Ae = activeTransition;
          activeTransition.Lt.push(i);
        }
        for (let e2 = 0; e2 < t.ze.length; e2++) {
          const i = t.ze[e2];
          i.Ae = activeTransition;
          activeTransition.ze.push(i);
        }
        if (t.A.length) activeTransition.A.push(...t.A);
        for (const e2 of t.En) activeTransition.En.add(e2);
        if (t.cn.size) {
          for (const e2 of t.cn) activeTransition.cn.add(e2);
          t.cn.clear();
        }
        currentBatch = this.m = activeTransition;
      }
      for (const e2 of activeLanes) {
        if (!e2.Ae) e2.Ae = activeTransition;
      }
      schedule();
    }
  };
  __publicField(_GlobalQueue, "Fe");
  __publicField(_GlobalQueue, "He");
  __publicField(_GlobalQueue, "it");
  __publicField(_GlobalQueue, "qt", null);
  // Store-side hook: drops a keyless affects() mark's identity scope when the
  // carrier node's last registration releases (wired by store.ts, mirroring
  // _clearOptimisticStore).
  __publicField(_GlobalQueue, "p", null);
  // affects()-side hooks (wired by affects.ts, mirroring _update): the mark
  // engine — count/register/release — lives with the feature. Every call site
  // is gated by state only that module creates, so `!` invocations are safe
  // once the gate holds.
  __publicField(_GlobalQueue, "G", null);
  __publicField(_GlobalQueue, "M", null);
  __publicField(_GlobalQueue, "N", null);
  // External-source bridge (wired by enableExternalSource(); null while no
  // config is active — including after _resetExternalSourceConfig()).
  __publicField(_GlobalQueue, "Pt", null);
  __publicField(_GlobalQueue, "ht", null);
  // Verdict-layer hooks (wired by verdict.ts when isPending()/latest() are
  // imported; null in apps that never use them). Call sites either guard for
  // null or sit behind state only the verdict layer can create (`!` is safe
  // there: `_pendingSignal`/`_latestValueComputed` are only ever assigned by
  // verdict.ts, and `pendingCheckActive`/`latestReadActive` only flip inside
  // isPending()/latest()).
  __publicField(_GlobalQueue, "Ue", null);
  __publicField(_GlobalQueue, "de", null);
  __publicField(_GlobalQueue, "me", null);
  __publicField(_GlobalQueue, "un", null);
  __publicField(_GlobalQueue, "gt", null);
  __publicField(_GlobalQueue, "Ht", null);
  __publicField(_GlobalQueue, "kt", null);
  __publicField(_GlobalQueue, "et", null);
  __publicField(_GlobalQueue, "k", null);
  __publicField(_GlobalQueue, "Wt", null);
  // Re-asks probes whose verdict was provisionally suppressed by a fresh read
  // of a held value, once the transaction gains an async blocker (#3028).
  __publicField(_GlobalQueue, "zt", null);
  // Optimistic-engine hooks (wired by core/optimistic.ts via
  // installOptimisticEngine(), called from verdict.ts / createOptimistic /
  // createOptimisticStore — every module that can create optimistic state).
  // Call sites are gated by state only the engine can create: an
  // `_overrideValue` slot, a lane in `activeLanes`, an `_optimisticNodes`
  // entry, or a non-null `currentOptimisticLane`, so `!` invocations are safe
  // once the gate holds.
  __publicField(_GlobalQueue, "xt", null);
  __publicField(_GlobalQueue, "Tn", null);
  __publicField(_GlobalQueue, "dn", null);
  __publicField(_GlobalQueue, "In", null);
  __publicField(_GlobalQueue, "Nn", null);
  /** Patch-channel optimistic drain (next/patch.ts): optimistic emissions
   * apply at lane-effect timing — visible in flight, unlike the regular
   * effect queues an action stashes. Injected; null when unused. */
  __publicField(_GlobalQueue, "ln", null);
  __publicField(_GlobalQueue, "vt", null);
  __publicField(_GlobalQueue, "Vt", null);
  __publicField(_GlobalQueue, "bt", null);
  __publicField(_GlobalQueue, "Be", null);
  __publicField(_GlobalQueue, "$e", null);
  /** Authoritative-view reader wakeup (until()): installed at first until() call.
   * Call sites are gated by CONFIG_AUTHORITATIVE_OBSERVED, which only until()'s
   * carve-out read can set, so `!` invocations are safe once the gate holds. */
  __publicField(_GlobalQueue, "he", null);
  __publicField(_GlobalQueue, "Xe", null);
  __publicField(_GlobalQueue, "_n", null);
  var GlobalQueue = _GlobalQueue;
  function queuePendingNode(e) {
    currentBatch.Lt.push(e);
  }
  var reaskArmed = false;
  var notifyEpoch = 0;
  function bumpNotifyEpoch() {
    notifyEpoch++;
  }
  function insertSubs(e, t = false) {
    e.It = notifyEpoch;
    const i = e.T;
    const n = (i & CONFIG_HAS_LANE ? e.o?.Je : void 0) || currentOptimisticLane;
    const r = (i & CONFIG_HAS_SNAPSHOT) !== 0 && e.o?.We !== void 0;
    const s = reaskArmed;
    for (let i2 = e.u; i2 !== null; i2 = i2.ae) {
      const e2 = i2.ce;
      if (s) e2.ie &= ~REACTIVE_REASK;
      if (e2.ie & REACTIVE_RECOMPUTING_DEPS && i2.Ft === e2.Ke && i2 !== e2.je) e2.ie |= REACTIVE_MISSED_WAKE;
      if (r && e2.T & CONFIG_IN_SNAPSHOT_SCOPE) {
        e2.ie |= REACTIVE_SNAPSHOT_STALE;
        continue;
      }
      if (t && n) {
        e2.ie |= REACTIVE_OPTIMISTIC_DIRTY;
        assignOrMergeLane(e2, n);
      } else if (t) {
        e2.ie |= REACTIVE_OPTIMISTIC_DIRTY;
        if (e2.o) e2.o.Je = void 0;
      }
      enqueueSub(e2);
    }
  }
  function commitPendingNode(e) {
    const t = e;
    if (!t.oe) {
      if (e.Re !== NOT_PENDING) {
        e.be = e.Re;
        e.Re = NOT_PENDING;
      }
      if (e.T & CONFIG_HAS_COMPANIONS) GlobalQueue.un(e);
      return;
    }
    if (e.Re !== NOT_PENDING) {
      e.be = e.Re;
      e.Re = NOT_PENDING;
      if (e.ge && e.ge !== EFFECT_TRACKED) e.tt = true;
      if (e.o) e.o.De = false;
    }
    t.Ne = false;
    t.ie &= ~REACTIVE_MANUAL_WRITE;
    if (!(t.S & STATUS_PENDING)) t.S &= ~STATUS_UNINITIALIZED;
    if (t.o != null && (t.o.Ye !== null || t.o.qe !== null)) GlobalQueue.He(t, false, true);
    if (e.T & CONFIG_HAS_COMPANIONS) GlobalQueue.un(e);
  }
  var storeCommitHook = null;
  var patchCommitHook = null;
  var heldRevealed = [];
  function commitPendingNodes() {
    const e = currentBatch.Lt;
    for (let t = 0; t < e.length; t++) {
      const i = e[t];
      commitPendingNode(i);
      i.Ae = null;
      if (i.T & CONFIG_HELD_TRUTH) {
        i.T &= ~CONFIG_HELD_TRUTH;
        heldRevealed.push(i);
      }
    }
    e.length = 0;
    storeCommitHook?.();
    patchCommitHook?.(currentBatch);
  }
  function finalizePureQueue(e = null, t = false) {
    const i = !t;
    if (i) commitPendingNodes();
    if (!t && globalQueue.Qt.length) checkBoundaryChildren(globalQueue);
    const n = dirtyQueue.EE >= dirtyQueue.Qe;
    if (n) runHeap(dirtyQueue, GlobalQueue.Fe);
    if (i) {
      if (n) commitPendingNodes();
      const t2 = e ?? globalQueue.m;
      if (t2.ze.length) GlobalQueue.Tn(t2.ze);
      if (t2.cn.size) {
        for (const e2 of t2.cn) {
          if (e2.ie & REACTIVE_DISPOSED) continue;
          enqueueSub(e2);
        }
        t2.cn.clear();
        schedule();
      }
      if (t2.A.length) {
        GlobalQueue.G(t2.A);
        if (globalQueue.Qt.length) checkBoundaryChildren(globalQueue);
      }
      if (t2.En.size) GlobalQueue.qt(t2.En, e);
      if (heldRevealed.length !== 0) {
        while (heldRevealed.length) insertSubs(heldRevealed.pop());
        if (dirtyQueue.EE >= dirtyQueue.Qe) {
          runHeap(dirtyQueue, GlobalQueue.Fe);
          commitPendingNodes();
        }
      }
      sweepTransientStoreNodes();
      if (activeLanes.size) GlobalQueue.In(e);
    }
  }
  function checkBoundaryChildren(e) {
    for (const t of e.Qt) {
      t.se?.();
      checkBoundaryChildren(t);
    }
  }
  function reassignPendingTransition(e) {
    for (let t = 0; t < e.length; t++) {
      e[t].Ae = activeTransition;
    }
  }
  var globalQueue = new GlobalQueue();
  var currentBatch = globalQueue.m;
  function flush(e) {
    if (e) {
      syncDepth++;
      try {
        return e();
      } finally {
        try {
          flush();
        } finally {
          syncDepth--;
        }
      }
    }
    if (globalQueue.fn) {
      return;
    }
    if (halted) return;
    while (scheduled || activeTransition) {
      globalQueue.flush();
    }
  }
  function runQueue(e, t) {
    for (let i = 0; i < e.length; i++) e[i](t);
  }
  function reporterBlocksSource(e, t) {
    if (e.ie & (REACTIVE_ZOMBIE | REACTIVE_DISPOSED)) return false;
    if (e.o?.le?.has(t)) return true;
    for (let i = e.ut; i; i = i.lt) {
      let e2 = i.ot;
      while (e2) {
        if (e2 === t || e2.st === t) return true;
        e2 = e2.o?.Tt;
      }
    }
    return !!(e.S & STATUS_PENDING && e.o?._ instanceof NotReadyError && e.o?._.source === t);
  }
  function transitionComplete(e) {
    if (e.sn) return true;
    if (e.ue.length) return false;
    let t = true;
    for (const [i, n] of e._e) {
      let r = false;
      for (const e2 of n) {
        if (reporterBlocksSource(e2, i)) {
          r = true;
          break;
        }
        n.delete(e2);
      }
      if (!r) e._e.delete(i);
      else if (i.S & STATUS_PENDING && i.o?._?.source === i) {
        t = false;
        break;
      }
    }
    if (t && GlobalQueue.dn?.(e)) t = false;
    t && (e.sn = true);
    return t;
  }
  function currentTransition(e) {
    while (e.sn && typeof e.sn === "object") e = e.sn;
    return e;
  }
  function runInTransition(e, t) {
    const i = activeTransition;
    try {
      activeTransition = currentTransition(e);
      return t();
    } finally {
      activeTransition = i;
    }
  }

  // node_modules/@solidjs/signals/dist/prod/core/heap.js
  function queueFor(e) {
    return e.ie & REACTIVE_ZOMBIE ? zombieQueue : dirtyQueue;
  }
  function enqueueSub(e) {
    if (e.ge === EFFECT_TRACKED) {
      const E2 = e;
      if (!E2.tt) {
        E2.tt = true;
        E2.C.enqueue(EFFECT_USER, E2.yt);
      }
      return;
    }
    const E = queueFor(e);
    if (E.Qe > e.Me) E.Qe = e.Me;
    insertIntoHeap(e, E);
  }
  function actualInsertIntoHeap(e, E) {
    const t = (e.ke?.Gt ? e.ke.Dt?.Me : e.ke?.Me) ?? -1;
    if (t >= e.Me) e.Me = t + 1;
    const n = e.Me;
    const I = E.eE[n];
    if (I === void 0) E.eE[n] = e;
    else {
      const E2 = I.ct;
      E2.rt = e;
      e.ct = E2;
      I.ct = e;
    }
    if (n > E.EE) E.EE = n;
  }
  function insertIntoHeap(e, E) {
    let t = e.ie;
    if (t & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS | REACTIVE_MANUAL_WRITE)) return;
    if (t & REACTIVE_CHECK) {
      e.ie = t & -4 | REACTIVE_DIRTY | REACTIVE_IN_HEAP;
    } else {
      e.ie = t | REACTIVE_IN_HEAP;
      if (E.tE && !(t & REACTIVE_DIRTY)) E.tE = false;
    }
    if (!(t & REACTIVE_IN_HEAP_HEIGHT)) actualInsertIntoHeap(e, E);
  }
  function insertIntoHeapHeight(e, E) {
    let t = e.ie;
    if (t & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS | REACTIVE_IN_HEAP_HEIGHT | REACTIVE_MANUAL_WRITE)) return;
    e.ie = t | REACTIVE_IN_HEAP_HEIGHT;
    actualInsertIntoHeap(e, E);
  }
  function deleteFromHeap(e, E) {
    const t = e.ie;
    if (!(t & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT))) return;
    e.ie = t & -25;
    const n = e.Me;
    if (e.ct === e) E.eE[n] = void 0;
    else {
      const t2 = e.rt;
      const I = E.eE[n];
      const o = t2 ?? I;
      if (e === I) E.eE[n] = t2;
      else e.ct.rt = t2;
      o.ct = e.ct;
    }
    e.ct = e;
    e.rt = void 0;
  }
  function markHeap(e) {
    if (e.tE) return;
    e.tE = true;
    for (let E = 0; E <= e.EE; E++) {
      for (let t = e.eE[E]; t !== void 0; t = t.rt) {
        if (t.ie & REACTIVE_IN_HEAP) markNode(t);
      }
    }
  }
  function markNode(e, E = REACTIVE_DIRTY) {
    const t = e.ie;
    if ((t & (REACTIVE_CHECK | REACTIVE_DIRTY)) >= E) return;
    e.ie = t & -4 | E;
    for (let E2 = e.u; E2 !== null; E2 = E2.ae) {
      markNode(E2.ce, REACTIVE_CHECK);
    }
    if (e.T & CONFIG_FW_CHILDREN) {
      for (let E2 = e.o.i; E2 !== null; E2 = E2.Se) {
        for (let e2 = E2.u; e2 !== null; e2 = e2.ae) {
          markNode(e2.ce, REACTIVE_CHECK);
        }
      }
    }
  }
  function runHeap(e, E) {
    e.tE = false;
    for (e.Qe = 0; e.Qe <= e.EE; e.Qe++) {
      let t = e.eE[e.Qe];
      while (t !== void 0) {
        if (t.ie & REACTIVE_IN_HEAP) E(t);
        else adjustHeight(t, e);
        t = e.eE[e.Qe];
      }
    }
    e.EE = 0;
  }
  function adjustHeight(e, E) {
    deleteFromHeap(e, E);
    let t = e.Me;
    for (let E2 = e.ut; E2; E2 = E2.lt) {
      const e2 = E2.ot;
      const n = e2.st || e2;
      if (n.oe && n.Me >= t) t = n.Me + 1;
    }
    if (e.Me !== t) {
      e.Me = t;
      for (let E2 = e.u; E2 !== null; E2 = E2.ae) {
        insertIntoHeapHeight(E2.ce, queueFor(E2.ce));
      }
    }
  }

  // node_modules/@solidjs/signals/dist/prod/core/owner.js
  function markDisposal(e) {
    let t = e.xe;
    while (t) {
      const e2 = t.ie;
      t.ie = e2 | REACTIVE_ZOMBIE;
      if (e2 & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT)) {
        deleteFromHeap(t, e2 & REACTIVE_ZOMBIE ? zombieQueue : dirtyQueue);
        if (e2 & REACTIVE_IN_HEAP) insertIntoHeap(t, zombieQueue);
        else insertIntoHeapHeight(t, zombieQueue);
      }
      markDisposal(t);
      t = t.Le;
    }
  }
  function disposeChildren(e, t = false, n) {
    const i = e.ie;
    if (i & REACTIVE_DISPOSED) return;
    if (t) {
      e.ie = i | REACTIVE_DISPOSED;
      const t2 = e;
      if (t2.o?.ye || t2.o?.Ce) GlobalQueue.un(t2);
    }
    if (t && e.oe && e.o !== null) e.o.Ie = null;
    let o = n ? e.o?.Ye ?? null : e.xe;
    while (o) {
      const e2 = o.Le;
      const t2 = o;
      t2.T &= ~CONFIG_AUTO_DISPOSE;
      deleteFromHeap(t2, queueFor(t2));
      clearDeps(t2);
      disposeChildren(o, true);
      o = e2;
    }
    if (n) {
      if (e.o !== null) e.o.Ye = null;
    } else {
      e.xe = null;
      e.Ze = 0;
    }
    if (t && !n && !(i & REACTIVE_ZOMBIE) && e.ke !== null && !(e.ke.ie & REACTIVE_DISPOSED)) {
      const t2 = e.ft;
      const n2 = e.Le;
      if (t2 !== null) t2.Le = n2;
      else e.ke.xe = n2;
      if (n2 !== null) n2.ft = t2;
      e.ft = null;
    }
    runDisposal(e, n);
    if (t && e.Rt) {
      const t2 = e.Rt;
      e.Rt = void 0;
      t2();
    }
  }
  function runDisposal(e, t) {
    let n = t ? e.o?.qe : e.Ge;
    if (!n) return;
    if (Array.isArray(n)) {
      for (let e2 = 0; e2 < n.length; e2++) {
        const t2 = n[e2];
        t2.call(t2);
      }
    } else {
      n.call(n);
    }
    if (t) {
      if (e.o !== null) e.o.qe = null;
    } else e.Ge = null;
  }
  function childId(e, t) {
    let n = e;
    while (n.T & CONFIG_TRANSPARENT && n.ke) n = n.ke;
    if (n.id != null) return formatId(n.id, t ? n.Ze++ : n.Ze);
    throw new Error("");
  }
  function getNextChildId(e) {
    return childId(e, true);
  }
  function inheritId(e, t, n) {
    return e?.id ?? (t ? n?.id : n?.id != null ? getNextChildId(n) : void 0);
  }
  function formatId(e, t) {
    const n = t.toString(36), i = n.length - 1;
    return e + (i ? String.fromCharCode(64 + i) : "") + n;
  }
  function cleanup(e) {
    if (!context) return e;
    if (!context.Ge) context.Ge = e;
    else if (Array.isArray(context.Ge)) context.Ge.push(e);
    else context.Ge = [context.Ge, e];
    return e;
  }
  function disposeRootSelf(e = true) {
    disposeChildren(this, e);
  }
  function createOwner(e) {
    const t = context;
    const n = e?.transparent ?? false;
    const i = {
      id: inheritId(e, n, t),
      T: n ? CONFIG_TRANSPARENT : 0,
      Gt: true,
      Dt: t?.Gt ? t.Dt : t,
      xe: null,
      Le: null,
      ft: null,
      Ge: null,
      C: t?.C ?? globalQueue,
      we: t?.we || defaultContext,
      Ze: 0,
      o: null,
      ke: t,
      dispose: disposeRootSelf
    };
    if (t) {
      const e2 = t.xe;
      if (e2 === null) {
        t.xe = i;
      } else {
        i.Le = e2;
        e2.ft = i;
        t.xe = i;
      }
    }
    return i;
  }
  function createRoot(e, t) {
    const n = createOwner(t);
    return runWithOwner(n, () => e(() => n.dispose()));
  }

  // node_modules/@solidjs/signals/dist/prod/core/graph.js
  function unlinkSubs(e) {
    const n = e.ot;
    const l = e.lt;
    const o = e.ae;
    const u = e.en;
    if (o !== null) o.en = u;
    else n._t = u;
    if (u !== null) u.ae = o;
    else {
      n.u = o;
      if (o === null) {
        n.o?.Et?.();
        const e2 = n;
        e2.oe && e2.T & CONFIG_AUTO_DISPOSE && !(e2.ie & REACTIVE_ZOMBIE) && !(e2.S & STATUS_PENDING) && unobserved(e2);
      }
    }
    return l;
  }
  function trimStaleDeps(e) {
    const n = e.je;
    let l = n !== null ? n.lt : e.ut;
    if (l !== null) {
      do {
        l = unlinkSubs(l);
      } while (l !== null);
      if (n !== null) n.lt = null;
      else e.ut = null;
    }
  }
  function clearDeps(e) {
    let n = e.ut;
    if (!n) return;
    do {
      n = unlinkSubs(n);
    } while (n !== null);
    e.ut = null;
    e.je = null;
  }
  function unobserved(e) {
    deleteFromHeap(e, queueFor(e));
    clearDeps(e);
    disposeChildren(e, true);
  }
  var dormantNodes = /* @__PURE__ */ new Set();
  function sweepDormant() {
    if (dormantNodes.size === 0) return;
    for (const e of dormantNodes) {
      if (!e.u && e.T & CONFIG_AUTO_DISPOSE && !(e.S & STATUS_PENDING) && !(e.ie & (REACTIVE_DISPOSED | REACTIVE_ZOMBIE))) {
        unobserved(e);
      }
    }
    dormantNodes.clear();
  }
  function link(e, n, l = false) {
    const o = n.je;
    if (o !== null && o.ot === e) {
      o.ve && (o.ve = l);
      return;
    }
    let u = null;
    const t = n.ie & REACTIVE_RECOMPUTING_DEPS;
    if (t) {
      u = o !== null ? o.lt : n.ut;
      if (u !== null && u.ot === e) {
        u.Ft = n.Ke;
        n.je = u;
        u.ve = l;
        return;
      }
    }
    const s = e._t;
    if (s !== null && s.ce === n && (!t || s.Ft === n.Ke)) {
      if (t) s.ve && (s.ve = l);
      else s.ve = l;
      return;
    }
    const r = n.je = e._t = {
      ot: e,
      ce: n,
      lt: u,
      en: s,
      ae: null,
      Ft: n.Ke,
      ve: l
    };
    if (o !== null) o.lt = r;
    else n.ut = r;
    if (s !== null) s.ae = r;
    else e.u = r;
    bumpNotifyEpoch();
  }

  // node_modules/@solidjs/signals/dist/prod/core/async.js
  function addPendingSource(e, n) {
    var _a;
    if (e.o?.le?.has(n)) return false;
    ((_a = ext(e)).le ?? (_a.le = /* @__PURE__ */ new Set())).add(n);
    return true;
  }
  function removePendingSource(e, n) {
    const t = e.o?.le;
    if (!t?.delete(n)) return false;
    if (!t.size) e.o.le = void 0;
    return true;
  }
  function clearPendingSources(e) {
    if (e.o !== null) e.o.le = void 0;
  }
  function parkLoadingWindow(e, n) {
    ext(e).fe = true;
    if (n.source) addPendingSource(e, n.source);
    if (!(e.S & STATUS_ERROR)) setPendingError(e, n.source, n);
  }
  function setPendingError(e, n, t) {
    if (!n) {
      if (e.o !== null) e.o._ = null;
      return;
    }
    if (t instanceof NotReadyError && t.source === n) {
      ext(e)._ = t;
      return;
    }
    const r = e.o?._;
    if (!(r instanceof NotReadyError) || r.source !== n) {
      ext(e)._ = new NotReadyError(n);
    }
  }
  function forEachDependent(e, n) {
    for (let t = e.u; t !== null; t = t.ae) n(t.ce, t);
    for (let t = e.o?.i ?? null; t !== null; t = t.Se) {
      for (let e2 = t.u; e2 !== null; e2 = e2.ae) n(e2.ce, e2);
    }
  }
  function releaseIfSettledUnobserved(e) {
    e.oe && e.T & CONFIG_AUTO_DISPOSE && !e.u && !(e.ie & REACTIVE_ZOMBIE) && !(e.S & STATUS_PENDING) && unobserved(e);
  }
  function releaseSettledDependents(e) {
    let n;
    const t = /* @__PURE__ */ new Set();
    const visit = (e2) => {
      if (t.has(e2)) return;
      t.add(e2);
      if (!e2.u && e2.T & CONFIG_AUTO_DISPOSE) (n ?? (n = [])).push(e2);
      forEachDependent(e2, visit);
    };
    forEachDependent(e, visit);
    if (n) for (const e2 of n) releaseIfSettledUnobserved(e2);
  }
  function settleErroredDependents(e, n) {
    let t = false;
    const r = /* @__PURE__ */ new Set();
    const visit = (e2) => {
      if (r.has(e2)) return;
      r.add(e2);
      if (e2.o?._ === n) {
        enqueueSub(e2);
        t = true;
      }
      forEachDependent(e2, visit);
    };
    forEachDependent(e, visit);
    if (t) schedule();
  }
  function settlePendingSource(e) {
    removePendingSource(e, e);
    let n = false;
    let t;
    const r = /* @__PURE__ */ new Set();
    const o = GlobalQueue.de;
    const settle = (i) => {
      if (r.has(i) || !removePendingSource(i, e)) return;
      r.add(i);
      i.Te = clock;
      const l = i.o?.le?.values().next().value;
      const s = i.S & STATUS_ERROR;
      if (l) {
        if (!s) setPendingError(i, l);
        o?.(i);
      } else {
        i.S &= ~STATUS_PENDING;
        if (!s) setPendingError(i);
        o?.(i);
        if (i.o?.fe) {
          enqueueSub(i);
          n = true;
        }
        if (i.o !== null) i.o.fe = false;
        if (!i.u && i.T & CONFIG_AUTO_DISPOSE) (t ?? (t = [])).push(i);
      }
      forEachDependent(i, settle);
    };
    forEachDependent(e, settle);
    if (t) for (const e2 of t) releaseIfSettledUnobserved(e2);
    if (n) schedule();
  }
  function isThenable(e) {
    return e != null && typeof e === "object" && typeof e.then === "function";
  }
  function releaseFlightTeardown(e) {
    const n = e.o?.Ee;
    if (n != null) {
      e.o.Ee = null;
      n();
    }
  }
  function handleAsync(e, n, t) {
    let r = false;
    let o = false;
    if (typeof n === "object" && n !== null) {
      untrack(() => {
        r = n[Symbol.asyncIterator];
        o = !r && isThenable(n);
      });
    }
    if (!o && !r) {
      if (e.o !== null) e.o.Ie = null;
      e.Ne = false;
      return n;
    }
    ext(e).Ie = n;
    let i;
    const settleTransition = () => {
      const n2 = resolveTransition(e);
      if (n2 && e.S & STATUS_UNINITIALIZED && !currentTransition(n2)._e.has(e)) {
        e.Ae = null;
        return;
      }
      globalQueue.initTransition(n2);
    };
    const handleError = (t2) => {
      if (e.o?.Ie !== n) return;
      let r2 = t2 instanceof NotReadyError;
      if (r2 && e.Ne) {
        if (e.o !== null) e.o.Ie = null;
        parkLoadingWindow(e, t2);
        e.Te = clock;
        return;
      }
      settleTransition();
      notifyStatus(e, r2 ? STATUS_PENDING : STATUS_ERROR, t2);
      if (r2) settlePendingSource(e);
      e.Te = clock;
      if (!r2) releaseSettledDependents(e);
    };
    const asyncWrite = (r2, o2) => {
      if (e.o?.Ie !== n) return;
      if (e.ie & (REACTIVE_DIRTY | REACTIVE_OPTIMISTIC_DIRTY)) return;
      settleTransition();
      const i2 = !!(e.S & STATUS_UNINITIALIZED);
      const l2 = e.o?.De;
      trimStaleDeps(e);
      clearStatus(e);
      if (l2) e.o.De = true;
      const s = resolveLane(e);
      if (s) s.Oe.delete(e);
      if (t) {
        t(r2);
        if (i2) clearStatus(e, true);
      } else if (e.o?.Pe !== void 0) {
        if (e.Re === NOT_PENDING) queuePendingNode(e);
        e.Re = r2;
        GlobalQueue.Ue?.(e, r2);
        if (!hasActiveOverride(e)) {
          insertSubs(e);
        } else if (e.T & CONFIG_AUTHORITATIVE_OBSERVED) {
          GlobalQueue.he?.(e);
        }
        e.Te = clock;
      } else if (s) {
        const n2 = e.ge;
        const t2 = e.be;
        const o3 = e.pe;
        try {
          if (!n2 && i2 || !o3 || !o3(r2, t2)) {
            e.be = r2;
            e.Te = clock;
            GlobalQueue.Ue?.(e, r2);
            insertSubs(e, true);
          }
        } catch (n3) {
          notifyStatus(e, STATUS_ERROR, n3);
        }
      } else {
        try {
          setSignal(e, () => r2);
        } catch (n2) {
          notifyStatus(e, STATUS_ERROR, n2);
        }
      }
      if (e.Re === NOT_PENDING) {
        e.Ne = false;
        if (l2) e.o.De = false;
      }
      settlePendingSource(e);
      schedule();
      flush();
      o2?.();
    };
    const settleAutodispose = () => {
      if (e.T & CONFIG_AUTO_DISPOSE && !e.u && !(e.S & STATUS_PENDING)) {
        unobserved(e);
        return true;
      }
      return false;
    };
    const consumeIterator = (t2, r2) => {
      const o2 = t2[Symbol.asyncIterator]();
      let l2 = false;
      let s = false;
      let u = !r2;
      const close = () => {
        if (s) return;
        s = true;
        try {
          const e2 = o2.return?.();
          if (isThenable(e2)) e2.then(void 0, () => {
          });
        } catch {
        }
      };
      r2 ? r2(close) : cleanup(close);
      ext(e).Ee = close;
      const iterateOrRelease = () => {
        if (!settleAutodispose()) iterate();
      };
      const iterate = () => {
        let t3, r3, f2 = false, a = false, c = true;
        const S = o2.next();
        const d = isThenable(S) ? S : {
          then: (e2) => void e2(S)
        };
        d.then((r4) => {
          if (c && u) {
            t3 = r4;
            f2 = true;
            if (r4.done) s = true;
          } else if (e.o?.Ie !== n) {
            return;
          } else if (!r4.done) {
            l2 = true;
            asyncWrite(r4.value, iterateOrRelease);
          } else {
            s = true;
            if (l2) {
              schedule();
              flush();
            } else {
              asyncWrite(void 0);
            }
            settleAutodispose();
          }
        }, (t4) => {
          if (c && u) {
            r3 = t4;
            a = true;
          } else if (e.o?.Ie === n) {
            s = true;
            handleError(t4);
            settleAutodispose();
          }
        });
        c = false;
        if (a) {
          s = true;
          handleError(r3);
          if (u) throw r3;
          return true;
        }
        if (f2 && !t3.done) {
          i = t3.value;
          l2 = true;
          return iterate();
        }
        return f2 && t3.done;
      };
      const f = iterate();
      u = false;
      return l2 || f;
    };
    let l = null;
    const flattenIfIterable = (e2, n2) => {
      let t2 = false;
      if (typeof e2 === "object" && e2 !== null) {
        untrack(() => {
          t2 = e2[Symbol.asyncIterator];
        });
      }
      if (!t2) return false;
      const r2 = consumeIterator(e2, n2);
      if (!n2) l = r2;
      return true;
    };
    if (o) {
      let t2 = false, r2 = false, o2, l2 = true;
      const registerDeferredClose = (n2) => {
        if (!e.Ge) e.Ge = n2;
        else if (Array.isArray(e.Ge)) e.Ge.push(n2);
        else e.Ge = [e.Ge, n2];
      };
      n.then((r3) => {
        if (l2) {
          i = r3;
          t2 = true;
        } else if (e.o?.Ie === n && !(e.ie & REACTIVE_DISPOSED) && flattenIfIterable(r3, registerDeferredClose)) ;
        else {
          asyncWrite(r3);
          settleAutodispose();
        }
      }, (e2) => {
        if (l2) {
          o2 = e2;
          r2 = true;
        } else {
          handleError(e2);
          settleAutodispose();
        }
      });
      l2 = false;
      if (r2) {
        handleError(o2);
        throw o2;
      } else if (!t2) {
        if (e.Ne) return e.be;
        globalQueue.initTransition(resolveTransition(e));
        throw new NotReadyError(context);
      } else if (!flattenIfIterable(i)) {
        e.Ne = false;
      }
    }
    if (r) flattenIfIterable(n);
    if (l !== null) {
      if (!l) {
        if (e.Ne) return e.be;
        globalQueue.initTransition(resolveTransition(e));
        throw new NotReadyError(context);
      }
      e.Ne = false;
    }
    return i;
  }
  function clearStatus(e, n = false) {
    if (e.o?.le) clearPendingSources(e);
    if (e.o?.fe) {
      if (e.o !== null) e.o.fe = false;
    }
    if (e.o !== null) e.o.De = false;
    e.S = n ? 0 : e.S & STATUS_UNINITIALIZED;
    if (e.o?._) setPendingError(e);
    if (e.o?.ye || e.o?.Ce) GlobalQueue.de(e);
    if (e.o?.i && e.T & CONFIG_CHILD_COMPANIONS && GlobalQueue.me !== null) GlobalQueue.me(e);
    const t = statusNotifierOf(e);
    if (t) t.call(e);
  }
  function notifyStatus(e, n, t, r, o) {
    if (n === STATUS_ERROR && !(t instanceof StatusError) && !(t instanceof NotReadyError)) t = new StatusError(e, t);
    const i = n === STATUS_PENDING && t instanceof NotReadyError ? t.source : void 0;
    const l = i === e;
    const s = n === STATUS_PENDING && e.o?.Pe !== void 0 && !l;
    const u = s && hasActiveOverride(e);
    if (!r) {
      if (n === STATUS_PENDING && i) {
        addPendingSource(e, i);
        e.S = STATUS_PENDING | e.S & STATUS_UNINITIALIZED;
        setPendingError(e, i, t);
      } else {
        clearPendingSources(e);
        e.S = n | (n !== STATUS_ERROR ? e.S & STATUS_UNINITIALIZED : 0);
        ext(e)._ = t;
      }
      GlobalQueue.de?.(e);
      if (e.o?.i && e.T & CONFIG_CHILD_COMPANIONS && GlobalQueue.me !== null) GlobalQueue.me(e);
    }
    if (o && !r) {
      assignOrMergeLane(e, o);
    }
    const f = r || u;
    const a = r || s ? void 0 : o;
    const c = statusNotifierOf(e);
    if (c) {
      if (r && n === STATUS_PENDING) {
        return;
      }
      if (f) {
        c.call(e, n, t);
      } else {
        c.call(e);
      }
      return;
    }
    forEachDependent(e, (e2, r2) => {
      e2.Te = clock;
      if (n === STATUS_PENDING && i && !e2.o?.le?.has(i) || n !== STATUS_PENDING && (e2.o?._ !== t || e2.o?.le)) {
        if (r2.ve && n !== STATUS_PENDING && !(t instanceof NotReadyError)) {
          enqueueSub(e2);
          schedule();
          return;
        }
        if (!f && !e2.Ae) queuePendingNode(e2);
        notifyStatus(e2, n, t, f, a);
      }
    });
  }

  // node_modules/@solidjs/signals/dist/prod/core/core.js
  GlobalQueue.Fe = recompute;
  GlobalQueue.He = disposeChildren;
  var tracking = false;
  var stale = false;
  var pendingCheckActive = false;
  var latestReadActive = false;
  var context = null;
  var currentOptimisticLane = null;
  var snapshotCaptureActive = false;
  var snapshotSources = null;
  function ownerInSnapshotScope(e) {
    while (e) {
      if (e.Ve) return true;
      e = e.ke;
    }
    return false;
  }
  function recompute(e, t = false) {
    bumpNotifyEpoch();
    const n = e.ge;
    if (!t) {
      if (e.Ae && (!n || activeTransition) && activeTransition !== e.Ae) globalQueue.initTransition(e.Ae);
      deleteFromHeap(e, queueFor(e));
      if (e.o !== null) {
        e.o.Ie = null;
        releaseFlightTeardown(e);
      }
      if (e.Ae || n === EFFECT_TRACKED) disposeChildren(e);
      else if (e.xe !== null || e.Ge !== null) {
        markDisposal(e);
        const t2 = ext(e);
        t2.qe = e.Ge;
        t2.Ye = e.xe;
        e.Ge = null;
        e.xe = null;
        e.Ze = 0;
      } else ;
    }
    let i = !!(e.ie & REACTIVE_OPTIMISTIC_DIRTY);
    const u = (e.T & CONFIG_OPTIMISTIC) !== 0 && e.o?.Pe !== NOT_PENDING && e.o?.Pe !== void 0;
    const l = !!(e.S & STATUS_UNINITIALIZED);
    const o = e.S & STATUS_ERROR ? e.o?._ : void 0;
    const s = e.o?.le?.has(e);
    const a = (e.ie & REACTIVE_REASK) !== 0;
    const r = e.Ne;
    const c = context;
    context = e;
    e.je = null;
    e.Ke++;
    e.ie = REACTIVE_RECOMPUTING_DEPS;
    e.Te = clock;
    let _ = e.Re === NOT_PENDING ? e.be : e.Re;
    let f = e.Me;
    let I = false;
    let E = tracking;
    let N = currentOptimisticLane;
    tracking = true;
    const T = latestReadActive;
    latestReadActive = false;
    if (i) {
      const t2 = GlobalQueue.Be(e, true);
      if (t2) currentOptimisticLane = t2;
      else if (t2 === false) i = false;
    } else if (activeTransition && !t && activeTransition.ze.length) {
      const t2 = GlobalQueue.Be(e, false);
      if (t2) {
        i = true;
        currentOptimisticLane = t2;
      }
    }
    const S = n && n !== EFFECT_USER;
    const d = stale;
    if (S) stale = true;
    try {
      if (e.T & CONFIG_SYNC) {
        _ = e.oe(_);
        if (e.o !== null) e.o.Ie = null;
        e.Ne = false;
      } else {
        const t2 = e.o?.Ie;
        const n2 = e.oe(_);
        const i2 = typeof n2 === "object" && n2 !== null;
        const u2 = e.o?.Ie !== t2;
        _ = u2 || !i2 ? n2 : handleAsync(e, n2);
        if (!u2 && !i2) {
          if (e.o !== null) e.o.Ie = null;
          e.Ne = false;
        }
      }
      if (e.S !== 0 || e.o !== null) clearStatus(e, t);
      if (e.T & CONFIG_HAS_LANE && e.o?.Je) GlobalQueue.Xe(e);
    } catch (t2) {
      const n2 = t2 instanceof NotReadyError;
      if (n2 && e.Ne) {
        parkLoadingWindow(e, t2);
      } else {
        if (n2 && currentOptimisticLane) GlobalQueue.$e(e);
        let i2 = false;
        if (n2) {
          ext(e).fe = true;
          if (GlobalQueue.et !== null) i2 = GlobalQueue.et(e, a);
        }
        notifyStatus(e, n2 ? STATUS_PENDING : STATUS_ERROR, t2, void 0, n2 ? e.o?.Je : void 0);
        if (n2 && s && !e.o?.Ie) settlePendingSource(e);
        if (i2) GlobalQueue.k(e);
      }
    } finally {
      tracking = E;
      latestReadActive = T;
      if (S) stale = d;
      I = (e.ie & REACTIVE_MISSED_WAKE) !== 0;
      e.ie = REACTIVE_NONE | (t ? e.ie & REACTIVE_SNAPSHOT_STALE : 0);
      context = c;
    }
    if (!e.o?._) {
      trimStaleDeps(e);
      const a2 = u ? unwrapOverride(e.o?.Pe) : e.Re === NOT_PENDING ? e.be : e.Re;
      let c2 = false;
      try {
        c2 = !n && l || !e.pe || !e.pe(a2, _);
      } catch (t2) {
        notifyStatus(e, STATUS_ERROR, t2);
      }
      if (n && c2) {
        e.tt = !e.o?._;
        if (!t) e.C.enqueue(n, e.nt ?? (e.nt = GlobalQueue.it.bind(null, e)));
      }
      if (e.o?._) ;
      else if (c2) {
        const l2 = u ? e.o?.Pe : void 0;
        if (t || // Plain sync flush (no transition on either side) commits effect
        // values directly — the pending round-trip (queuePendingNode +
        // commitPendingNodes) exists to sequence transition reveals, and
        // paying it per effect on the plain path is pure overhead.
        // DIRECT_COMMIT effects (resolve/until) commit directly even under
        // their own held transition: their applies deliver on a microtask,
        // not the stashed queues, so a staged value would hand the immediate
        // apply stale state — see CONFIG_DIRECT_COMMIT.
        n && (activeTransition !== e.Ae || activeTransition === null || e.T & CONFIG_DIRECT_COMMIT) || i) {
          e.be = _;
          if (u && i) {
            ext(e).Pe = _ === void 0 ? OVERRIDE_UNDEFINED : _;
            e.Re = NOT_PENDING;
          }
        } else {
          e.Re = _;
          if (r) e.Ne = true;
          if ((activeTransition || e.Ae) && GlobalQueue.Ue !== null) GlobalQueue.Ue(e, _);
        }
        if (e.u !== null && (!u || i || e.o?.Pe !== l2)) insertSubs(e, i || u);
      } else if (u) {
        if (e.Re === NOT_PENDING) queuePendingNode(e);
        e.Re = _;
        if (r) e.Ne = true;
        if (e.T & CONFIG_AUTHORITATIVE_OBSERVED) GlobalQueue.he(e);
      } else if (e.Me != f) {
        for (let t2 = e.u; t2 !== null; t2 = t2.ae) {
          insertIntoHeapHeight(t2.ce, queueFor(t2.ce));
        }
      }
      if (o !== void 0 && !c2 && !e.o?._) settleErroredDependents(e, o);
      if (s && !(e.S & (STATUS_PENDING | STATUS_UNINITIALIZED))) settlePendingSource(e);
    }
    currentOptimisticLane = N;
    const A = e.Re !== NOT_PENDING || e.o !== null && (e.o.Ye !== null || e.o.qe !== null) || (e.S & (STATUS_PENDING | STATUS_UNINITIALIZED)) !== 0;
    A && (!t || e.S & STATUS_PENDING) && (!e.Ae || u) && queuePendingNode(e);
    e.Ae && n && activeTransition !== e.Ae && runInTransition(e.Ae, () => recompute(e));
    if (I) {
      enqueueSub(e);
      schedule();
    }
  }
  function updateIfNecessary(e) {
    if (e.ie & (REACTIVE_RECOMPUTING_DEPS | REACTIVE_DISPOSED)) return;
    if (e.ie & REACTIVE_CHECK) {
      for (let t = e.ut; t; t = t.lt) {
        const n = t.ot;
        const i = n.st || n;
        if (i.oe) {
          updateIfNecessary(i);
        }
        if (e.ie & REACTIVE_DIRTY) {
          break;
        }
      }
    }
    if (e.ie & (REACTIVE_DIRTY | REACTIVE_OPTIMISTIC_DIRTY) || e.o?._ && e.Te < clock && !e.o?.Ie) {
      recompute(e);
    }
    e.ie = e.ie & (REACTIVE_SNAPSHOT_STALE | REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT);
  }
  function computed(e, t) {
    const n = t?.transparent ?? false;
    const i = t !== null && typeof t === "object" && "loadingValue" in t;
    const u = {
      id: inheritId(t, n, context),
      T: (n ? CONFIG_TRANSPARENT : 0) | (t?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (!context || t?.lazy ? CONFIG_AUTO_DISPOSE : 0) | (t?.sync ? CONFIG_SYNC : 0) | (t?.H ? CONFIG_NO_SNAPSHOT : 0) | (snapshotCaptureActive && ownerInSnapshotScope(context) ? CONFIG_IN_SNAPSHOT_SCOPE : 0),
      pe: t?.equals ?? isEqual,
      Ge: null,
      C: context?.C ?? globalQueue,
      we: context?.we ?? defaultContext,
      Ze: 0,
      oe: e,
      be: i ? t.loadingValue : void 0,
      Me: 0,
      rt: void 0,
      ct: null,
      ut: null,
      je: null,
      Ke: 0,
      u: null,
      _t: null,
      ke: context,
      Le: null,
      ft: null,
      xe: null,
      ie: t?.lazy ? REACTIVE_LAZY : REACTIVE_NONE,
      // A loadingValue node is born committed: commit #0 is already in _value.
      S: i ? 0 : STATUS_UNINITIALIZED,
      Te: clock,
      Re: NOT_PENDING,
      Ae: null,
      It: -1,
      Ne: i,
      // Cold machinery (async/transition/optimistic/verdict slots) lives one
      // hop away in the lazily-allocated extension — the core literal MUST
      // stay under V8's in-object boundary (§12: past ~39 fields every
      // allocation spills to a backing store and creation cost ~4x's).
      o: null
    };
    if (t?.unobserved) ext(u).Et = t.unobserved;
    setupComputedNode(u, t);
    return u;
  }
  function ext(e) {
    return e.o ?? (e.o = {
      Pe: void 0,
      Nt: void 0,
      Je: void 0,
      ye: void 0,
      Ce: void 0,
      Tt: void 0,
      t: 0,
      Ie: null,
      Ee: null,
      _: void 0,
      fe: void 0,
      le: void 0,
      h: void 0,
      De: false,
      i: null,
      Et: void 0,
      We: void 0,
      qe: null,
      Ye: null,
      St: void 0
    });
  }
  function createEffectNode(e, t, n, i, u) {
    const l = u?.transparent ?? false;
    const o = {
      id: inheritId(u, l, context),
      T: (l ? CONFIG_TRANSPARENT : 0) | (u?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (u?.sync ? CONFIG_SYNC : 0) | (u?.dt ?? 0) | (snapshotCaptureActive && ownerInSnapshotScope(context) ? CONFIG_IN_SNAPSHOT_SCOPE : 0),
      pe: false,
      Ge: null,
      C: context?.C ?? globalQueue,
      we: context?.we ?? defaultContext,
      Ze: 0,
      oe: e,
      be: void 0,
      Me: 0,
      rt: void 0,
      ct: null,
      ut: null,
      je: null,
      Ke: 0,
      u: null,
      _t: null,
      ke: context,
      Le: null,
      ft: null,
      xe: null,
      ie: REACTIVE_LAZY,
      S: STATUS_UNINITIALIZED,
      Te: clock,
      Re: NOT_PENDING,
      Ae: null,
      It: -1,
      Ne: false,
      tt: false,
      At: void 0,
      Ot: t,
      Ct: n,
      Rt: void 0,
      ge: i,
      o: null
    };
    if (u?.unobserved) ext(o).Et = u.unobserved;
    setupComputedNode(o, lazyOptions);
    return o;
  }
  var effectStatusNotify = null;
  function setEffectStatusNotify(e) {
    effectStatusNotify = e;
  }
  function statusNotifierOf(e) {
    const t = e.o?.h;
    if (t !== void 0) return t;
    return e.ge ? effectStatusNotify ?? void 0 : void 0;
  }
  var lazyOptions = {
    lazy: true
  };
  function setupComputedNode(e, t) {
    e.ct = e;
    const n = context?.Gt ? context.Dt : context;
    if (context) {
      const t2 = context.xe;
      if (t2 === null) {
        context.xe = e;
      } else {
        e.Le = t2;
        t2.ft = e;
        context.xe = e;
      }
    }
    if (n) e.Me = n.Me + 1;
    if (GlobalQueue.Pt !== null) GlobalQueue.Pt(e);
    !t?.lazy && recompute(e, true);
    if (snapshotCaptureActive && !t?.lazy) {
      if (!(e.S & STATUS_PENDING) && !(e.T & CONFIG_NO_SNAPSHOT)) {
        ext(e).We = e.be === void 0 ? NO_SNAPSHOT : e.be;
        e.T |= CONFIG_HAS_SNAPSHOT;
        snapshotSources.add(e);
      }
    }
  }
  function signal(e, t, n = null) {
    const i = {
      pe: t?.equals ?? isEqual,
      T: (t?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (t?.H ? CONFIG_NO_SNAPSHOT : 0),
      be: e,
      u: null,
      _t: null,
      Te: clock,
      st: n,
      Se: n?.o?.i || null,
      Re: NOT_PENDING,
      // Signal-literal diet (§12e): NO _time/_fn/_statusFlags slots. Stores
      // materialize one signal per touched leaf, so signal bytes are store
      // bytes. _time is write-only on signals (every read site is computed-
      // typed error-retry gating); _fn/_statusFlags read falsy-identically as
      // missing properties on the shared paths (undefined masks to 0).
      Ae: null,
      It: -1,
      o: null
    };
    if (t?.unobserved) ext(i).Et = t.unobserved;
    if (n) {
      ext(n).i = i;
      n.T |= CONFIG_FW_CHILDREN;
    }
    if (snapshotCaptureActive && !(i.T & CONFIG_NO_SNAPSHOT) && !((n?.S ?? 0) & STATUS_PENDING)) {
      ext(i).We = e === void 0 ? NO_SNAPSHOT : e;
      i.T |= CONFIG_HAS_SNAPSHOT;
      snapshotSources.add(i);
    }
    return i;
  }
  function isEqual(e, t) {
    return e === t;
  }
  function untrack(e, t) {
    if (GlobalQueue.ht === null && !tracking && true) return e();
    const n = tracking;
    tracking = false;
    try {
      if (GlobalQueue.ht !== null) return GlobalQueue.ht(e);
      return e();
    } finally {
      tracking = n;
    }
  }
  function prepareComputed(e, t) {
    if (e.ie & REACTIVE_LAZY) {
      e.ie &= ~REACTIVE_LAZY;
      recompute(e, true);
    } else if (e.ie & REACTIVE_DISPOSED) {
      if (e.T & CONFIG_AUTO_DISPOSE) recompute(e, true);
    } else if (t) {
      updateIfNecessary(e);
    }
  }
  function read(e) {
    if (latestReadActive) return GlobalQueue.gt(e);
    let t = context;
    if (t?.Gt) t = t.Dt;
    const n = e;
    const i = e.st;
    const u = i || e;
    if (pendingCheckActive) {
      GlobalQueue.Ht(e, t, u, i);
    } else if (typeof n.oe === "function") {
      prepareComputed(e, false);
    }
    if (!n.oe && u === e && e.o?.Pe === void 0 && e.o?.We === void 0 && activeTransition === null && currentOptimisticLane === null && !snapshotCaptureActive && true) {
      if (t && tracking) link(e, t);
      return !t || e.Re === NOT_PENDING || t.T & CONFIG_CHILDREN_FORBIDDEN ? e.be : e.Re;
    }
    if (t && tracking) {
      link(e, t, pendingCheckActive);
      if (u.oe) {
        const n2 = queueFor(e);
        if (u.Me >= n2.Qe) {
          markNode(t);
          markHeap(n2);
          updateIfNecessary(u);
        } else if (t.T & CONFIG_FRESH_READ) updateIfNecessary(u);
        const i2 = u.Me;
        if (i2 >= t.Me && e.ke !== t) {
          t.Me = i2 + 1;
        }
      }
    }
    if (u.S & STATUS_PENDING) {
      if (t && !(stale && u.Ae && activeTransition !== u.Ae)) {
        if (currentOptimisticLane === null || GlobalQueue.Vt(u)) {
          if (!tracking && e !== t) link(e, t);
          throw u.o?._;
        }
      } else if (t && u.S & STATUS_UNINITIALIZED) {
        if (!tracking && e !== t) link(e, t);
        throw u.o?._;
      } else if (!t && u.S & STATUS_UNINITIALIZED) {
        throw u.o?._;
      }
    }
    if (u.oe && u.S & STATUS_ERROR) {
      if (tracking && !pendingCheckActive && u.Te < clock) {
        recompute(u);
        return read(e);
      } else throw u.o?._;
    }
    if (snapshotCaptureActive && t && t.T & CONFIG_IN_SNAPSHOT_SCOPE) {
      const n2 = e.o?.We;
      if (n2 !== void 0) {
        const i2 = n2 === NO_SNAPSHOT ? void 0 : n2;
        const u2 = e.Re !== NOT_PENDING ? e.Re : e.be;
        if (u2 !== i2) t.ie |= REACTIVE_SNAPSHOT_STALE;
        return i2;
      }
    }
    if (e.o?.Pe !== void 0 && e.o?.Pe !== NOT_PENDING) {
      if (!(t && t.T & CONFIG_AUTHORITATIVE_READ)) return unwrapOverride(e.o?.Pe);
      e.T |= CONFIG_AUTHORITATIVE_OBSERVED;
    }
    if (currentOptimisticLane !== null && activeTransition !== null && t !== null && GlobalQueue.vt(e, u, t)) {
      return e.be;
    }
    const l = !t || currentOptimisticLane !== null && GlobalQueue.bt(e, u, t) || e.Re === NOT_PENDING || t.T & CONFIG_CHILDREN_FORBIDDEN || stale && e.Ae && activeTransition !== e.Ae || // A17 for HELD truth (#3164, see CONFIG_HELD_TRUTH): staged confirming
    // truth — fold-staged onto an armed family, or entangle-stolen by an
    // awaited until() — is masked from ordinary readers until its
    // transaction's reveal; the retaining transaction's own speculative
    // recomputes included (partial override coverage would otherwise
    // compose override + staged truth into a state no timeline contains).
    // Authoritative readers (until()'s predicate) and latest() see the
    // staged truth — the tunnel that keeps the hold deadlock-free.
    e.T & CONFIG_HELD_TRUTH && !latestReadActive && !(t.T & CONFIG_AUTHORITATIVE_READ) ? e.be : e.Re;
    if (pendingCheckActive) GlobalQueue.kt(e, l);
    if (!t && u === e && typeof n.oe === "function" && e.T & CONFIG_AUTO_DISPOSE && !(u.S & STATUS_PENDING) && !e.u) {
      dormantNodes.add(e);
      schedule();
    }
    return l;
  }
  function setSignal(e, t) {
    if (e.Ae && activeTransition !== e.Ae) globalQueue.initTransition(e.Ae);
    if (e.T & CONFIG_OPTIMISTIC && !projectionWriteActive) return GlobalQueue.xt(e, t);
    const n = e.Re === NOT_PENDING ? e.be : e.Re;
    if (typeof t === "function") t = t(n);
    const i = !!(e.S & STATUS_UNINITIALIZED) || !e.pe || !e.pe(n, t);
    if (!i) return t;
    const u = e.Re !== NOT_PENDING;
    if (!u) queuePendingNode(e);
    e.Re = t;
    e.T & CONFIG_HAS_COMPANIONS && GlobalQueue.Ue !== null && GlobalQueue.Ue(e, t);
    if (e.oe !== void 0) e.Te = clock;
    if (u && e.It === notifyEpoch && currentOptimisticLane === null && !reaskArmed) return t;
    insertSubs(e);
    schedule();
    return t;
  }
  function suppressComputedRecompute(e) {
    deleteFromHeap(e, queueFor(e));
    if (!(e.ie & REACTIVE_MANUAL_WRITE) && e.Re === NOT_PENDING) {
      queuePendingNode(e);
      schedule();
    }
    e.ie = e.ie & -4 | REACTIVE_MANUAL_WRITE;
    e.Ut = clock;
  }
  function setMemo(e, t) {
    const n = setSignal(e, t);
    suppressComputedRecompute(e);
    return n;
  }
  function runWithOwner(e, t) {
    const n = context;
    const i = tracking;
    context = e;
    tracking = false;
    try {
      return t();
    } finally {
      context = n;
      tracking = i;
    }
  }

  // node_modules/@solidjs/signals/dist/prod/core/effect.js
  function effect(t, e, E, f) {
    const r = !!f?.user;
    const R = createEffectNode(t, e, E, r ? EFFECT_USER : EFFECT_RENDER, f);
    recompute(R, true);
    !f?.defer && (R.ge === EFFECT_USER || f?.schedule ? R.C.enqueue(R.ge, runEffect.bind(null, R)) : runEffect(R));
  }
  function notifyEffectStatus(t, e) {
    const E = t !== void 0 ? t : this.S;
    const f = e !== void 0 ? e : this.o?._;
    if (E & STATUS_ERROR) {
      this.C.notify(this, STATUS_PENDING, 0);
      if (this.ge === EFFECT_USER) {
        if (this.S & STATUS_ERROR) {
          this.tt = true;
          this.C.enqueue(this.ge, this.nt ?? (this.nt = runEffect.bind(null, this)));
        }
        return;
      }
      if (!this.C.notify(this, STATUS_ERROR, STATUS_ERROR)) {
        haltReactivity(unwrapStatusError(f));
        throw f;
      }
    } else if (this.ge === EFFECT_RENDER) {
      this.C.notify(this, STATUS_PENDING | STATUS_ERROR, E, f);
    }
  }
  function runEffect(t) {
    if (!t.tt || t.ie & REACTIVE_DISPOSED) return;
    if (t.S & STATUS_ERROR && t.ge === EFFECT_USER) {
      const e2 = unwrapStatusError(t.o?._);
      t.At = t.be;
      t.tt = false;
      try {
        t.Ct ? t.Ct(e2, () => {
          const e3 = t.Rt;
          t.Rt = void 0;
          e3?.();
        }) : console.error(e2);
      } catch (e3) {
        if (!t.C.notify(t, STATUS_ERROR, STATUS_ERROR)) {
          haltReactivity(e3);
          throw e3;
        }
      }
      return;
    }
    const e = t.Rt;
    t.Rt = void 0;
    try {
      e?.();
      const E = t.Ot(t.be, t.At);
      if (false) ;
      t.Rt = E;
    } catch (e2) {
      ext(t)._ = new StatusError(t, e2);
      t.S |= STATUS_ERROR;
      if (!t.C.notify(t, STATUS_ERROR, STATUS_ERROR)) {
        haltReactivity(e2);
        throw e2;
      }
    } finally {
      t.At = t.be;
      t.tt = false;
    }
  }
  GlobalQueue.it = runEffect;
  setEffectStatusNotify(notifyEffectStatus);

  // node_modules/@solidjs/signals/dist/prod/signals.js
  function accessor(e) {
    const t = read.bind(null, e);
    t[$REFRESH] = e;
    return t;
  }
  function createSignal(e, t) {
    if (typeof e === "function") {
      const n2 = computed(e, t);
      n2.T &= ~CONFIG_AUTO_DISPOSE;
      return [accessor(n2), setMemo.bind(null, n2)];
    }
    const n = signal(e, t);
    return [accessor(n), setSignal.bind(null, n)];
  }
  function createMemo(e, t) {
    return accessor(computed(e, t));
  }
  function createRenderEffect(e, t, n) {
    effect(e, t, void 0, n);
  }

  // node_modules/@solidjs/signals/dist/prod/store/store.js
  var $PROXY = /* @__PURE__ */ Symbol(0);
  var OBJECT_PROTO = Object.prototype;
  function ownEnumerableKeys(e) {
    return Reflect.ownKeys(e).filter((t) => Object.prototype.propertyIsEnumerable.call(e, t));
  }

  // node_modules/@solidjs/signals/dist/prod/boundaries.js
  function flatten(e, t) {
    if (typeof e === "function" && !e.length) {
      if (t?.doNotUnwrap) return e;
      do {
        e = e();
      } while (typeof e === "function" && !e.length);
    }
    if (t?.skipNonRendered && (e == null || e === true || e === false || e === "")) return;
    if (Array.isArray(e)) {
      let r = [];
      if (flattenArray(e, r, t)) {
        return () => {
          let e2 = [];
          flattenArray(r, e2, {
            ...t,
            doNotUnwrap: false
          });
          return e2;
        };
      }
      return r;
    }
    return e;
  }
  function flattenArray(e, t = [], r) {
    let n = null;
    let s = false;
    for (let i = 0; i < e.length; i++) {
      try {
        let n2 = e[i];
        if (typeof n2 === "function" && !n2.length) {
          if (r?.doNotUnwrap) {
            t.push(n2);
            s = true;
            continue;
          }
          do {
            n2 = n2();
          } while (typeof n2 === "function" && !n2.length);
        }
        if (Array.isArray(n2)) {
          s = flattenArray(n2, t, r) || s;
        } else if (r?.skipNonRendered && (n2 == null || n2 === true || n2 === false || n2 === "")) {
        } else t.push(n2);
      } catch (e2) {
        if (!(e2 instanceof NotReadyError)) throw e2;
        n = e2;
      }
    }
    if (n) throw n;
    return s;
  }

  // node_modules/@solidjs/signals/dist/prod/store/utils.js
  function trueFn() {
    return true;
  }
  var propTraps = {
    get(e, r, t) {
      if (r === $PROXY) return t;
      return e.get(r);
    },
    has(e, r) {
      if (r === $PROXY) return true;
      return e.has(r);
    },
    set: trueFn,
    deleteProperty: trueFn,
    getOwnPropertyDescriptor(e, r) {
      return {
        configurable: true,
        enumerable: true,
        get() {
          return e.get(r);
        },
        set: trueFn,
        deleteProperty: trueFn
      };
    },
    ownKeys(e) {
      return e.keys();
    }
  };
  function resolveSource(e) {
    return !(e = typeof e === "function" ? e() : e) ? {} : e;
  }
  var $SOURCES = /* @__PURE__ */ Symbol(0);
  function merge(...e) {
    if (e.length === 1 && typeof e[0] !== "function") return e[0];
    let r = false;
    const t = [];
    for (let n2 = 0; n2 < e.length; n2++) {
      const o2 = e[n2];
      r = r || !!o2 && $PROXY in o2;
      const s2 = !!o2 && o2[$SOURCES];
      if (s2) {
        for (let e2 = 0; e2 < s2.length; e2++) t.push(s2[e2]);
      } else t.push(typeof o2 === "function" ? (r = true, createMemo(o2)) : o2);
    }
    if (SUPPORTS_PROXY && r) {
      return new Proxy({
        get(e2) {
          if (e2 === $SOURCES) return t;
          for (let r2 = t.length - 1; r2 >= 0; r2--) {
            const n2 = resolveSource(t[r2]);
            if (e2 in n2) return n2[e2];
          }
        },
        has(e2) {
          for (let r2 = t.length - 1; r2 >= 0; r2--) {
            if (e2 in resolveSource(t[r2])) return true;
          }
          return false;
        },
        keys() {
          const e2 = /* @__PURE__ */ new Set();
          for (let r2 = 0; r2 < t.length; r2++) {
            const n2 = ownEnumerableKeys(resolveSource(t[r2]));
            for (let r3 = 0; r3 < n2.length; r3++) e2.add(n2[r3]);
          }
          return [...e2];
        }
      }, propTraps);
    }
    const n = /* @__PURE__ */ Object.create(null);
    let o = false;
    let s = t.length - 1;
    for (let e2 = s; e2 >= 0; e2--) {
      const r2 = t[e2];
      if (!r2) {
        e2 === s && s--;
        continue;
      }
      const u2 = Object.getOwnPropertyNames(r2);
      for (let t2 = u2.length - 1; t2 >= 0; t2--) {
        const c2 = u2[t2];
        if (c2 === "__proto__" || c2 === "constructor") continue;
        if (!n[c2]) {
          o = o || e2 !== s;
          const t3 = Object.getOwnPropertyDescriptor(r2, c2);
          n[c2] = t3.get ? {
            enumerable: true,
            configurable: true,
            get: t3.get.bind(r2)
          } : t3;
        }
      }
    }
    if (!o) return t[s];
    const u = {};
    const c = Object.keys(n);
    for (let e2 = c.length - 1; e2 >= 0; e2--) {
      const r2 = c[e2], t2 = n[r2];
      if (t2.get) Object.defineProperty(u, r2, t2);
      else u[r2] = t2.value;
    }
    u[$SOURCES] = t;
    return u;
  }

  // node_modules/solid-js/dist/solid.js
  var _createMemo;
  var _createSignal;
  var _createRenderEffect;
  var createMemo2 = (...args) => {
    return (_createMemo || createMemo)(...args);
  };
  var createSignal2 = (...args) => {
    return (_createSignal || createSignal)(...args);
  };
  var createRenderEffect2 = (...args) => (_createRenderEffect || createRenderEffect)(...args);
  function createComponent(Comp, props) {
    return untrack(() => Comp(props || {}));
  }

  // node_modules/@solidjs/universal/dist/universal.js
  var transparentOptions = {
    transparent: true,
    sync: true
  };
  var syncOptions = {
    sync: true
  };
  var effect2 = (fn, effectFn, options) => createRenderEffect2(fn, effectFn, options ? {
    sync: true,
    ...options,
    transparent: !options.scope
  } : transparentOptions);
  var memo = (fn) => createMemo2(() => fn(), syncOptions);
  var INNER_OWNED = {};
  function createRenderer({
    createElement: createElement2,
    createTextNode: createTextNode2,
    createSentinel = () => createTextNode2(""),
    isTextNode,
    replaceText,
    insertNode: insertNode2,
    removeNode,
    cleanupNodes,
    setProperty,
    getParentNode,
    getFirstChild,
    getNextSibling
  }) {
    function insert2(parent, accessor2, marker, initial, options) {
      const onUpdate = options && options.onUpdate;
      let effectOptions = options;
      if (onUpdate) {
        const {
          onUpdate: onUpdate2,
          ...rest
        } = options;
        effectOptions = rest;
      }
      const multi = marker !== void 0;
      if (multi && !initial) initial = [];
      if (typeof accessor2 !== "function") {
        accessor2 = normalize(accessor2, multi, true);
        if (typeof accessor2 !== "function") {
          insertExpression(parent, accessor2, initial, marker);
          onUpdate && onUpdate(accessor2);
          return;
        }
      }
      if (multi && initial.length === 0) {
        const sentinel = createSentinel();
        insertNode2(parent, sentinel, marker);
        initial = [sentinel];
      }
      let current = initial;
      effect2((prev) => {
        const value = normalize(accessor2(), multi, true);
        if (typeof value !== "function") return value;
        effect2(() => normalize(value, multi), (inner) => {
          insertExpression(parent, inner, current, marker);
          current = inner;
          onUpdate && onUpdate(current);
        }, prev !== void 0 && !(options && options.schedule) ? {
          ...effectOptions,
          schedule: true
        } : effectOptions);
        return INNER_OWNED;
      }, (value) => {
        if (value === INNER_OWNED) return;
        insertExpression(parent, value, current, marker);
        current = value;
        onUpdate && onUpdate(current);
      }, effectOptions);
    }
    function insertExpression(parent, value, current, marker) {
      if (value === current) return;
      const t = typeof value, multi = marker !== void 0;
      if (t === "string" || t === "number") {
        const tc = typeof current;
        if (tc === "string" || tc === "number") {
          replaceText(getFirstChild(parent), value);
        } else {
          cleanChildren(parent, current, marker, createTextNode2(value));
        }
      } else if (value == null) {
        cleanChildren(parent, current, marker);
      } else if (Array.isArray(value)) {
        if (value.length === 0) {
          cleanChildren(parent, current, marker);
        } else {
          if (Array.isArray(current)) {
            if (current.length === 0) {
              appendNodes(parent, value, marker);
            } else reconcileArrays(parent, current, value);
          } else if (current == null) {
            appendNodes(parent, value);
          } else {
            reconcileArrays(parent, multi && current || [getFirstChild(parent)], value);
          }
        }
      } else {
        if (Array.isArray(current)) {
          cleanChildren(parent, current, multi ? marker : null, value);
        } else if (current == null || !getFirstChild(parent)) {
          insertNode2(parent, value);
        } else replaceNode(parent, value, getFirstChild(parent));
      }
    }
    function normalize(value, multi, doNotUnwrap) {
      value = flatten(value, {
        skipNonRendered: true,
        doNotUnwrap
      });
      if (doNotUnwrap && typeof value === "function") return value;
      if (multi && !Array.isArray(value)) value = [value != null ? value : ""];
      if (Array.isArray(value)) {
        for (let i = 0, len = value.length; i < len; i++) {
          const item = value[i], t = typeof item;
          if (t === "string" || t === "number") value[i] = createTextNode2(item);
        }
      }
      return value;
    }
    function reconcileArrays(parentNode, a, b) {
      let bLength = b.length, aEnd = a.length, bEnd = bLength, aStart = 0, bStart = 0, after = getNextSibling(a[aEnd - 1]), map = null;
      const isLive = (n) => n && getParentNode(n) === parentNode;
      while (aStart < aEnd || bStart < bEnd) {
        if (a[aStart] === b[bStart] && isLive(a[aStart])) {
          aStart++;
          bStart++;
          continue;
        }
        while (a[aEnd - 1] === b[bEnd - 1] && isLive(a[aEnd - 1])) {
          aEnd--;
          bEnd--;
        }
        if (aEnd === aStart) {
          const node = bEnd < bLength ? bStart ? getNextSibling(b[bStart - 1]) : b[bEnd - bStart] : after;
          while (bStart < bEnd) insertNode2(parentNode, b[bStart++], node);
        } else if (bEnd === bStart) {
          while (aStart < aEnd) {
            if (!map || !map.has(a[aStart])) removeNode(parentNode, a[aStart]);
            aStart++;
          }
        } else if (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]) {
          const anchor = a[aStart];
          do {
            insertNode2(parentNode, a[--aEnd], anchor);
            bStart++;
            if (aStart >= aEnd - 1 || bStart >= bEnd) break;
          } while (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]);
        } else {
          if (!map) {
            map = /* @__PURE__ */ new Map();
            let i = bStart;
            while (i < bEnd) map.set(b[i], i++);
          }
          const index = map.get(a[aStart]);
          if (index != null) {
            if (bStart < index && index < bEnd) {
              let i = aStart, sequence = 1, t;
              while (++i < aEnd && i < bEnd) {
                if ((t = map.get(a[i])) == null || t !== index + sequence) break;
                sequence++;
              }
              if (sequence > index - bStart) {
                const node = a[aStart];
                while (bStart < index) insertNode2(parentNode, b[bStart++], node);
              } else replaceNode(parentNode, b[bStart++], a[aStart++]);
            } else aStart++;
          } else removeNode(parentNode, a[aStart++]);
        }
      }
    }
    function cleanChildren(parent, current, marker, replacement) {
      if (marker === void 0) {
        let removed;
        while (removed = getFirstChild(parent)) removeNode(parent, removed);
        replacement && insertNode2(parent, replacement);
        return "";
      }
      if (current.length) {
        let inserted = false;
        for (let i = current.length - 1; i >= 0; i--) {
          const el = current[i];
          if (replacement !== el) {
            const isParent = getParentNode(el) === parent;
            if (replacement && !inserted && !i) isParent ? replaceNode(parent, replacement, el) : insertNode2(parent, replacement, marker);
            else isParent && removeNode(parent, el);
          } else inserted = true;
        }
      } else if (replacement) insertNode2(parent, replacement, marker);
    }
    function appendNodes(parent, array, marker) {
      for (let i = 0, len = array.length; i < len; i++) insertNode2(parent, array[i], marker);
    }
    function replaceNode(parent, newNode, oldNode) {
      insertNode2(parent, newNode, oldNode);
      removeNode(parent, oldNode);
    }
    function collectNodes(value, nodes) {
      if (Array.isArray(value)) {
        for (let i = 0, len = value.length; i < len; i++) collectNodes(value[i], nodes);
      } else if (value != null && typeof value !== "string" && typeof value !== "number") {
        nodes.push(value);
      }
      return nodes;
    }
    function collectMounted(parent, value) {
      const nodes = collectNodes(value, []);
      if (!nodes.length && (typeof value === "string" || typeof value === "number")) {
        const node = getFirstChild(parent);
        if (node) nodes.push(node);
      }
      return nodes;
    }
    function defaultCleanupNodes(parent, nodes) {
      for (let i = 0, len = nodes.length; i < len; i++) {
        const node = nodes[i];
        if (getParentNode(node) === parent) removeNode(parent, node);
      }
    }
    function spread2(node, props, skipChildren) {
      const prevProps = {};
      props || (props = {});
      if (!skipChildren) insert2(node, () => props.children);
      effect2(() => {
        const r = props.ref;
        (typeof r === "function" || Array.isArray(r)) && ref2(() => r, node);
      }, () => {
      });
      effect2(() => {
        const newProps = {};
        for (const prop in props) {
          if (prop === "children" || prop === "ref") continue;
          newProps[prop] = props[prop];
        }
        return newProps;
      }, (props2) => {
        for (const prop in prevProps) {
          if (!(prop in props2)) {
            setProperty(node, prop, void 0, prevProps[prop]);
            delete prevProps[prop];
          }
        }
        for (const prop in props2) {
          const value = props2[prop];
          if (value === prevProps[prop]) continue;
          setProperty(node, prop, value, prevProps[prop]);
          prevProps[prop] = value;
        }
      });
      return prevProps;
    }
    function applyRef2(r, element) {
      Array.isArray(r) ? r.flat(Infinity).forEach((f) => f && f(element)) : r(element);
    }
    function ref2(fn, element) {
      const resolved = untrack(fn);
      runWithOwner(null, () => applyRef2(resolved, element));
    }
    return {
      render(code, element) {
        let disposer, disposed = false, mounted = [];
        const cleanup2 = cleanupNodes || defaultCleanupNodes;
        try {
          createRoot((dispose) => {
            disposer = dispose;
            const tree = code();
            insert2(element, () => tree, void 0, void 0, {
              schedule: true,
              onUpdate(value) {
                mounted = collectMounted(element, value);
              }
            });
          });
          flush();
        } catch (err) {
          if (disposer) disposer();
          cleanup2(element, mounted);
          throw err;
        }
        return () => {
          if (disposed) return;
          disposed = true;
          disposer();
          cleanup2(element, mounted);
          mounted = [];
        };
      },
      insert: insert2,
      spread: spread2,
      createElement: createElement2,
      createTextNode: createTextNode2,
      insertNode: insertNode2,
      setProp(node, name, value, prev) {
        setProperty(node, name, value, prev);
        return value;
      },
      mergeProps: merge,
      effect: effect2,
      memo,
      createComponent,
      applyRef: applyRef2,
      ref: ref2,
      patchDriver(subject, body) {
        effect2(() => body(subject, subject, false), () => body(subject, void 0, true));
      }
    };
  }

  // node_modules/hondo/packages/solid/src/renderer.ts
  var renderer = createRenderer({
    createElement(type, staticProperties) {
      const node = getHost().createElement(type);
      if (staticProperties) {
        for (const [name, value] of Object.entries(staticProperties)) {
          getHost().setProperty(node, name, value);
        }
      }
      return node;
    },
    createTextNode(value) {
      return getHost().createTextNode(value);
    },
    replaceText(node, value) {
      getHost().replaceText(node, value);
    },
    setProperty(node, name, value) {
      getHost().setProperty(node, name, value);
    },
    insertNode(parent, node, anchor) {
      getHost().insertNode(parent, node, anchor);
    },
    isTextNode(node) {
      return getHost().isTextNode(node);
    },
    removeNode(parent, node) {
      getHost().removeNode(parent, node);
    },
    getParentNode(node) {
      return getHost().getParentNode(node);
    },
    getFirstChild(node) {
      return getHost().getFirstChild(node);
    },
    getNextSibling(node) {
      return getHost().getNextSibling(node);
    }
  });
  var { render: universalRender } = renderer;
  var {
    effect: effect3,
    memo: memo2,
    createComponent: createComponent2,
    createElement,
    createTextNode,
    insertNode,
    insert,
    spread,
    setProp,
    mergeProps,
    applyRef,
    ref
  } = renderer;
  function render(code, root) {
    return universalRender(code, root);
  }

  // node_modules/hondo/packages/solid/src/components.ts
  var eventProperties = [
    "onKey",
    "onKeyCapture",
    "onMouse",
    "onMouseCapture",
    "onFocusIn",
    "onFocusInCapture",
    "onFocusOut",
    "onFocusOutCapture"
  ];
  function Text(props = {}) {
    return primitive("text", props);
  }
  function Box(props = {}) {
    return primitive("box", props);
  }
  function Row(props = {}) {
    return primitive("row", props);
  }
  function Column(props = {}) {
    return primitive("column", props);
  }
  function Spacer(props = {}) {
    const node = createElement("spacer");
    effect3(
      () => [props.size, props.grow, props.shrink, props.style],
      ([size, grow, shrink, style]) => {
        setProp(node, "style", {
          basis: size ?? 0,
          grow: grow ?? 1,
          shrink: shrink ?? 1,
          ...style ?? {}
        });
      }
    );
    applyEvents(node, props);
    return node;
  }
  var focusRequestSequence = 0;
  function focusNode(node) {
    setProp(node, "focusRequest", ++focusRequestSequence);
  }
  function primitive(type, props) {
    const node = createElement(type);
    effect3(
      () => props.style,
      (style) => {
        if (style !== void 0) setProp(node, "style", style);
      }
    );
    effect3(
      () => props.focusable,
      (focusable) => {
        if (focusable !== void 0) setProp(node, "focusable", focusable);
      }
    );
    applyEvents(node, props);
    if (props.autoFocus) {
      if (props.focusable === void 0) setProp(node, "focusable", true);
      focusNode(node);
    }
    if (props.ref) {
      const handle = {
        node,
        focus() {
          focusNode(node);
        }
      };
      props.ref(handle);
    }
    insert(node, () => props.children);
    return node;
  }
  function applyEvents(node, props) {
    for (const name of eventProperties) {
      const handler = props[name];
      if (handler !== void 0) setProp(node, name, handler);
    }
  }

  // node_modules/hondo/packages/solid/src/controls.ts
  function keyPayload(event) {
    if (event.type !== "key") return void 0;
    const payload = event.payload;
    if (payload === null || Array.isArray(payload) || typeof payload !== "object") return void 0;
    const kind = payload.kind;
    if (typeof kind !== "string" || !isKeyKind(kind)) return void 0;
    if (kind === "codepoint") {
      return typeof payload.codepoint === "number" ? { kind, codepoint: payload.codepoint } : void 0;
    }
    return { kind };
  }
  function isKeyKind(value) {
    return value === "codepoint" || value === "enter" || value === "backspace" || value === "tab" || value === "shiftTab" || value === "escape" || value === "ctrlC" || value === "up" || value === "down" || value === "left" || value === "right";
  }

  // node_modules/hondo/packages/solid/src/popup.ts
  function Popup(props = {}) {
    return Box({
      get style() {
        return {
          ...props.style ?? {},
          position: "overlay",
          x: Math.max(0, Math.trunc(props.x ?? 0)),
          y: Math.max(0, Math.trunc(props.y ?? 0)),
          zIndex: Math.max(0, Math.trunc(props.zIndex ?? 0))
        };
      },
      get focusable() {
        return props.focusable;
      },
      get autoFocus() {
        return props.autoFocus;
      },
      get ref() {
        return props.ref;
      },
      onKey: (event) => {
        props.onKey?.(event);
        if (event.defaultPrevented || !props.onDismiss) return;
        if (keyPayload(event)?.kind !== "escape") return;
        props.onDismiss();
        event.preventDefault();
      },
      onKeyCapture: props.onKeyCapture,
      onMouse: props.onMouse,
      onMouseCapture: props.onMouseCapture,
      onFocusIn: props.onFocusIn,
      onFocusInCapture: props.onFocusInCapture,
      onFocusOut: props.onFocusOut,
      onFocusOutCapture: props.onFocusOutCapture,
      get children() {
        return props.children;
      }
    });
  }

  // node_modules/hondo/packages/solid/src/native_view.ts
  function NativeView(props) {
    if (!props.nativeType) throw new TypeError("NativeView nativeType cannot be empty");
    const node = Box({
      get style() {
        return props.style;
      },
      get focusable() {
        return props.focusable ?? true;
      },
      get autoFocus() {
        return props.autoFocus;
      },
      get ref() {
        return props.ref;
      },
      onKey: props.onKey,
      onKeyCapture: props.onKeyCapture,
      onMouse: props.onMouse,
      onMouseCapture: props.onMouseCapture,
      onFocusIn: props.onFocusIn,
      onFocusInCapture: props.onFocusInCapture,
      onFocusOut: props.onFocusOut,
      onFocusOutCapture: props.onFocusOutCapture
    });
    effect3(
      () => props.nativeType,
      (nativeType) => {
        if (!nativeType) throw new TypeError("NativeView nativeType cannot be empty");
        setProp(node, "nativeType", nativeType);
      }
    );
    effect3(
      () => props.nativeProps,
      (nativeProps) => {
        setProp(node, "nativeProps", nativeProps ?? {});
      }
    );
    effect3(
      () => props.onNativeState,
      (handler) => {
        setProp(node, "onNativeState", handler ?? null);
      }
    );
    return node;
  }

  // ui/src/bundle.ts
  var host = new HondoHost(new NativeMutationBridge());
  var restoreHost = installHost(host);
  var [mode, setMode] = createSignal2("NORMAL");
  var [line, setLine] = createSignal2(1);
  var [column, setColumn] = createSignal2(1);
  var [modified, setModified] = createSignal2(false);
  var [path, setPath] = createSignal2("[No Name]");
  var [project, setProject] = createSignal2("");
  var [status, setStatus] = createSignal2("");
  var [commandOpen, setCommandOpen] = createSignal2(false);
  var [commandText, setCommandText] = createSignal2("");
  var [buffers, setBuffers] = createSignal2(1);
  var [windows, setWindows] = createSignal2(1);
  var [tabs, setTabs] = createSignal2(1);
  var [diagnostics, setDiagnostics] = createSignal2(0);
  var [symbols, setSymbols] = createSignal2(0);
  var [references, setReferences] = createSignal2(0);
  var [pins, setPins] = createSignal2([]);
  var [pinSwitcherOpen, setPinSwitcherOpen] = createSignal2(false);
  var [pinSwitcherIndex, setPinSwitcherIndex] = createSignal2(0);
  var [terminalWidth, setTerminalWidth] = createSignal2(120);
  var [terminalHeight, setTerminalHeight] = createSignal2(30);
  var [projectCollapsed, setProjectCollapsed] = createSignal2(false);
  var [contextCollapsed, setContextCollapsed] = createSignal2(false);
  var [contextIndex, setContextIndex] = createSignal2(0);
  var [focusZone, setFocusZone] = createSignal2("editor");
  var contextNames = ["Symbols", "Diagnostics", "References", "Git", "Quickfix", "Tests"];
  var projectRef;
  var editorRef;
  var contextRef;
  var globals3 = globalThis;
  globals3.__zimJsKeyEvents = 0;
  function payloadObject(payload) {
    if (!payload || Array.isArray(payload) || typeof payload !== "object") return void 0;
    return payload;
  }
  function pinsPayload(value) {
    if (!Array.isArray(value)) return [];
    const result = [];
    for (const candidate of value) {
      const item = payloadObject(candidate);
      if (!item) continue;
      if (typeof item.id !== "number" || typeof item.path !== "string" || typeof item.line !== "number" || typeof item.column !== "number") continue;
      result.push({
        id: item.id,
        path: item.path,
        line: item.line,
        column: item.column,
        label: typeof item.label === "string" ? item.label : void 0
      });
    }
    return result;
  }
  function keyPayload2(event) {
    const value = payloadObject(event.payload);
    if (!value) return void 0;
    return {
      kind: typeof value.kind === "string" ? value.kind : void 0,
      codepoint: typeof value.codepoint === "number" ? value.codepoint : void 0
    };
  }
  function isCodepoint(event, expected) {
    const key = keyPayload2(event);
    return key?.kind === "codepoint" && key.codepoint !== void 0 && String.fromCodePoint(key.codepoint) === expected;
  }
  function dirname(value) {
    if (!value || value === "[No Name]") return "";
    const slash = Math.max(value.lastIndexOf("/"), value.lastIndexOf("\\"));
    return slash <= 0 ? "" : value.slice(0, slash);
  }
  function projectLabel() {
    return project() || dirname(path()) || "[No Project]";
  }
  function projectRail() {
    return projectCollapsed() || terminalWidth() < 72;
  }
  function contextRail() {
    return contextCollapsed() || terminalWidth() < 108;
  }
  function contextSummary() {
    switch (contextIndex()) {
      case 0:
        return symbols() === 0 ? "No symbol result yet" : `${symbols()} symbol${symbols() === 1 ? "" : "s"}`;
      case 1:
        return diagnostics() === 0 ? "No diagnostics" : `${diagnostics()} diagnostic${diagnostics() === 1 ? "" : "s"}`;
      case 2:
        return references() === 0 ? "No reference result yet" : `${references()} reference${references() === 1 ? "" : "s"}`;
      case 3:
        return "Git context surface";
      case 4:
        return "Quickfix context surface";
      case 5:
        return "Tests context surface";
      default:
        return "";
    }
  }
  function onNativeState(event) {
    const value = payloadObject(event.payload);
    if (!value) return;
    if (typeof value.mode === "string") setMode(value.mode);
    if (typeof value.line === "number") setLine(value.line);
    if (typeof value.column === "number") setColumn(value.column);
    if (typeof value.modified === "boolean") setModified(value.modified);
    if (typeof value.path === "string") setPath(value.path);
    if (typeof value.project === "string") setProject(value.project);
    if (typeof value.status === "string") setStatus(value.status);
    if (typeof value.commandOpen === "boolean") setCommandOpen(value.commandOpen);
    if (typeof value.commandText === "string") setCommandText(value.commandText);
    if (typeof value.buffers === "number") setBuffers(value.buffers);
    if (typeof value.windows === "number") setWindows(value.windows);
    if (typeof value.tabs === "number") setTabs(value.tabs);
    if (typeof value.diagnostics === "number") setDiagnostics(value.diagnostics);
    if (typeof value.symbols === "number") setSymbols(value.symbols);
    if (typeof value.references === "number") setReferences(value.references);
    if (value.pins !== void 0) setPins(pinsPayload(value.pins));
    if (typeof value.pinSwitcherOpen === "boolean") setPinSwitcherOpen(value.pinSwitcherOpen);
    if (typeof value.pinSwitcherIndex === "number") setPinSwitcherIndex(value.pinSwitcherIndex);
    if (typeof value.terminalWidth === "number") setTerminalWidth(value.terminalWidth);
    if (typeof value.terminalHeight === "number") setTerminalHeight(value.terminalHeight);
    flush();
  }
  function projectKey(event) {
    if (isCodepoint(event, "c") || keyPayload2(event)?.kind === "enter") {
      setProjectCollapsed((value) => !value);
      event.preventDefault();
      flush();
    }
  }
  function contextKey(event) {
    const key = keyPayload2(event);
    if (isCodepoint(event, "c") || key?.kind === "enter") {
      setContextCollapsed((value) => !value);
      event.preventDefault();
      flush();
      return;
    }
    if (!contextRail() && (key?.kind === "left" || key?.kind === "right")) {
      const direction = key.kind === "right" ? 1 : -1;
      const next = (contextIndex() + direction + contextNames.length) % contextNames.length;
      setContextIndex(next);
      event.preventDefault();
      flush();
    }
  }
  var contextTabs = contextNames.map(
    (name, index) => Text({
      get style() {
        return {
          dim: index !== contextIndex(),
          bold: index === contextIndex(),
          foreground: index === contextIndex() ? "bright-cyan" : "bright-black"
        };
      },
      get children() {
        return index === contextIndex() ? `[${name}]` : name;
      }
    })
  );
  var projectPanel = Column({
    focusable: true,
    ref: (handle) => {
      projectRef = handle;
    },
    onFocusIn: () => setFocusZone("project"),
    onKey: projectKey,
    get style() {
      return {
        width: projectRail() ? 3 : 24,
        minWidth: projectRail() ? 3 : 24,
        clip: true,
        background: focusZone() === "project" ? "#151923" : "#0d1118",
        paddingX: projectRail() ? 0 : 1
      };
    },
    get children() {
      if (projectRail()) {
        return [
          Text({ style: { bold: true, foreground: "bright-magenta" }, children: " P " })
        ];
      }
      return [
        Text({ style: { bold: true, foreground: "bright-magenta" }, children: "PROJECT" }),
        Text({ style: { dim: true }, children: () => projectLabel() }),
        Text({ children: () => `Current: ${path()}` }),
        Text({ children: () => `Open buffers: ${buffers()}` }),
        Text({ style: { bold: true, foreground: "bright-yellow" }, children: () => `PINS (${pins().length})` }),
        ...pins().slice(0, 9).map(
          (pin, index) => Text({
            get children() {
              const name = pin.label || pin.path;
              return `${index + 1} ${name} :${pin.line}`;
            },
            style: { dim: true }
          })
        ),
        Spacer({ grow: 1 }),
        Text({ style: { dim: true }, children: "c collapse \xB7 Tab focus" })
      ];
    }
  });
  var editorPanel = Column({
    style: { grow: 1, minWidth: 24, maxWidth: 110, minHeight: 1, background: "#080b10" },
    children: [
      NativeView({
        nativeType: "zim.editor",
        nativeProps: { shell: "hondo", protocol: 3, workspace: "zen" },
        autoFocus: true,
        ref: (handle) => {
          editorRef = handle;
        },
        onFocusIn: () => setFocusZone("editor"),
        onNativeState,
        onKey: () => {
          globals3.__zimJsKeyEvents = (globals3.__zimJsKeyEvents ?? 0) + 1;
        },
        style: { grow: 1, minHeight: 1, background: "#080b10" }
      })
    ]
  });
  var contextPanel = Column({
    focusable: true,
    ref: (handle) => {
      contextRef = handle;
    },
    onFocusIn: () => setFocusZone("context"),
    onKey: contextKey,
    get style() {
      return {
        width: contextRail() ? 3 : 28,
        minWidth: contextRail() ? 3 : 28,
        clip: true,
        background: focusZone() === "context" ? "#151923" : "#0d1118",
        paddingX: contextRail() ? 0 : 1
      };
    },
    get children() {
      if (contextRail()) {
        return [
          Text({ style: { bold: true, foreground: "bright-cyan" }, children: " C " })
        ];
      }
      return [
        Text({ style: { bold: true, foreground: "bright-cyan" }, children: "CONTEXT" }),
        Row({ style: { gap: 1, clip: true }, children: contextTabs }),
        Text({ style: { foreground: "bright-white" }, children: () => contextSummary() }),
        Text({ style: { dim: true }, children: () => `File: ${path()}` }),
        Spacer({ grow: 1 }),
        Text({ style: { dim: true }, children: "\u2190/\u2192 surface \xB7 c collapse" })
      ];
    }
  });
  var pinSwitcher = Popup({
    get x() {
      return Math.max(0, Math.floor((terminalWidth() - 52) / 2));
    },
    get y() {
      return Math.max(1, Math.floor((terminalHeight() - Math.min(14, pins().length + 5)) / 2));
    },
    zIndex: 20,
    style: { width: 52, paddingX: 1, background: "#20242c" },
    children: Column({
      children: [
        Text({ style: { bold: true, foreground: "bright-magenta" }, children: "PIN SWITCHER" }),
        Text({ style: { dim: true }, children: "1-9 jump \xB7 j/k select \xB7 Enter jump \xB7 Esc close" }),
        () => pins().map(
          (pin, index) => Text({
            get style() {
              return {
                bold: index === pinSwitcherIndex(),
                reverse: index === pinSwitcherIndex(),
                foreground: index === pinSwitcherIndex() ? "bright-cyan" : "bright-white"
              };
            },
            get children() {
              const label = pin.label ? `${pin.label} \xB7 ` : "";
              return `${index + 1} ${label}${pin.path}:${pin.line}:${pin.column}`;
            }
          })
        )
      ]
    })
  });
  var disposeRender = render(
    () => Column({
      style: { minWidth: 1, minHeight: 1, background: "#080b10" },
      children: [
        () => pinSwitcherOpen() ? pinSwitcher : null,
        Row({
          style: { height: 1, background: "#161b22" },
          children: [
            Text({
              style: { bold: true, foreground: "bright-magenta" },
              children: " ZIM "
            }),
            Text({
              style: { foreground: "bright-cyan" },
              children: () => path()
            }),
            Spacer({ grow: 1 }),
            Text({
              style: { dim: true },
              children: () => `ZEN \xB7 ${focusZone().toUpperCase()} \xB7 B${buffers()} W${windows()} T${tabs()} `
            })
          ]
        }),
        Row({
          style: {
            grow: 1,
            minHeight: 1,
            gap: 1,
            paddingX: 1,
            justify: "center",
            background: "#080b10"
          },
          children: [projectPanel, editorPanel, contextPanel]
        }),
        () => commandOpen() ? Row({
          style: { height: 1, background: "#20242c" },
          children: [
            Text({
              style: { foreground: "bright-yellow", bold: true },
              children: () => ` ${commandText()}`
            })
          ]
        }) : null,
        Row({
          style: { height: 1, background: "#161b22" },
          children: [
            Text({
              style: { bold: true, reverse: true },
              children: () => ` ${mode()} `
            }),
            Text({
              style: { foreground: "bright-yellow" },
              children: () => modified() ? " [+]" : ""
            }),
            Text({
              style: { dim: true },
              children: () => status() ? ` ${status()}` : ""
            }),
            Spacer({ grow: 1 }),
            Text({
              style: { dim: true },
              children: () => `${terminalWidth()}\xD7${terminalHeight()} \xB7 Tab workspace \xB7 `
            }),
            Text({ children: () => `Ln ${line()}, Col ${column()} ` })
          ]
        })
      ]
    }),
    host.root
  );
  flush();
  globals3.__zimUiDispose = () => {
    projectRef = void 0;
    editorRef = void 0;
    contextRef = void 0;
    disposeRender();
    restoreHost();
  };
})();
