# Signal-light integration boundary

`main` is the integration baseline. Signal-light behavior, WG branding, and update behavior retain the `wg` implementation during synchronization.

`AppModel` owns a `SignalLightFeatureModel` and forwards session state changes through `updateSessionState(_:)`. The feature owns preferences, persistence, effect selection, deduplication, and reconnection providers. `SignalLightSettingsPane` receives this feature and its language dependency directly.

Keep future signal-light changes in its dedicated files. Do not add device preferences or BLE commands to `AppModel`. The existing Core types, firmware protocol, preference keys, BLE coordinator, and update sources remain compatible.

The historical WG release/upstream-sync design describes the previous branch workflow; it does not override the current main-based integration policy.
