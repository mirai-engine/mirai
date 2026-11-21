# Scenario assertion reference

Use these conditions with `play.check` or `play.step` in a [scenario](scenario.md#conditions).
All conditions in the step must hold.

```json
{"entity": "Door", "field": "Door.open", "compare": "Equal", "value": true}
{"entity": "Door", "field": "Door", "compare": "Exists"}
{"entity": "Pickup", "compare": "Gone"}
{"storage": "Shell", "field": "page", "compare": "Equal", "value": "Pause"}
{"entity": "Player", "field": "Transform.position",
 "compare": "Approx", "value": [1, 0, 2], "tolerance": 0.05}
```

An entity can be selected by name, a path like `Parent/Child`, an id, or a live handle.
With `component`, the query includes only entities with that component. To assert presence
or absence on the selected entities, give the component name as `field` and use `Exists`
or `Gone`. Component reads include disabled rows, as in `scene.inspect`.

```json
{"entity": "Guard", "match": "Any", "field": "Guard.alert", "compare": "Equal", "value": true}
{"entity": "Guard", "match": "All", "field": "Motion", "compare": "Exists"}
{"entity": "Guard", "component": "Motion", "count": true, "compare": "At_Least", "value": 2}
```

`Unique`, the default, expects one match. An entity that is gone also satisfies a unique
`Gone` condition. `Any` requires at least one match to satisfy the condition, and `All`
requires a non-empty set in which every match satisfies it. To assert the number of matches,
use `count: true` with `Equal` for an exact count, `At_Least` for a minimum, or `At_Most`
for a maximum. A count can be zero.

Field paths use dots, with `Component.field` on an entity and just `field` on a storage.
Use `position.y` or `position.1` for a coordinate and `items.0` or `items[0]` for a list
element. Find component and storage names with `component.list` and `scene.inspect` with
`"world": "Game"`.

For values, `Equal` and `Not_Equal` compare scalars. `Below`, `At_Most`, `Above`, and
`At_Least` order numbers. `Approx` uses absolute tolerance for a number or each coordinate of
a numeric vector. `Contains` checks for a substring in text. Use a JSON literal with `value`;
`number` and `text` also take scalar expectations. An enum compares as its member name.

## Problems and events

```json
{"no_problems": true}
{"problem": "physics.transform", "compare": "Gone"}
{"storage": "Seat_Requests", "field": "queue.items", "length": true,
 "compare": "Equal", "value": 0}
```

`no_problems` requires zero reports since the run started. Use a problem code with `Exists`
or `Gone` for a specific report. If the problem log has lost earlier reports, the check
requires positive evidence before it can say whether a specific code occurred.

Read queues or event logs through their storage fields. Use `length: true` to compare the
length of a list, or read an item by index to check its payload. Events age out as the game
advances, so use a bounded wait to inspect them while they are retained. A missing list item
satisfies `Gone` and can become available during a wait.
