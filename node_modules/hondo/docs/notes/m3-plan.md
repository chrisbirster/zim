# M3 implementation plan

The M3 slice promotes capabilities already present in the native renderer into a typed Solid/Hondo component API.

Planned public primitives: `Text`, `Box`, `Stack`, `Row`, `Column`, and `Spacer`.

The native renderer remains the authority for sizing, layout, clipping, paint style, focus, and routed events. Components serialize typed props into the existing host/Scene mutation protocol rather than introducing a second layout or event engine.
