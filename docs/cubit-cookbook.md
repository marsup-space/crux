# Cubit Cookbook

This cookbook records Crux-specific conventions for using `nocterm_bloc`.

## Dependency Setup

Crux depends on `nocterm` from the local submodule:

```yaml
dependencies:
  nocterm:
    path: nocterm
```

`nocterm_bloc: ^1.1.0` depends on hosted `nocterm`, so Dart needs an explicit source override to keep the whole graph on the local submodule:

```yaml
dependencies:
  nocterm_bloc: ^1.1.0

dev_dependencies:
  bloc_test: ^10.0.0

dependency_overrides:
  nocterm:
    path: nocterm
```

Without the override, `dart pub get` fails because the same package would be resolved from two different sources.

## Verified API Surface

The package exports core `bloc` types and nocterm component helpers:

- `Cubit<T>` / `Bloc<Event, State>` from `package:bloc`
- `BlocProvider`
- `MultiBlocProvider`
- `BlocBuilder`
- `BlocListener`
- `BlocConsumer`
- `BlocSelector`
- `RepositoryProvider`
- context extensions: `context.read<T>()`, `context.select<T, R>(...)`, `context.watch<T>()`

The local spike test is `test/nocterm_bloc_spike_test.dart`. It verifies:

- `BlocProvider.value` provides a cubit to descendants.
- `context.read<CubitType>()` works in a nocterm `BuildContext`.
- `BlocBuilder<CubitType, State>` renders initial state and rebuilds after `emit`.

## Minimal Pattern

```dart
class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);

  void increment() => emit(state + 1);
}

class CounterView extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    final cubit = context.read<CounterCubit>();
    return BlocBuilder<CounterCubit, int>(
      builder: (context, count) => Text('$count'),
    );
  }
}
```

For Crux production widgets, prefer providing cubits at the smallest stable owner boundary. Avoid creating cubits in deeply rebuilt components unless the lifecycle is deliberately local.

## Test Pattern

Use `bloc_test` for pure cubit state transitions and `testNocterm` only when verifying component integration:

```dart
blocTest<CounterCubit, int>(
  'increments',
  build: CounterCubit.new,
  act: (cubit) => cubit.increment(),
  expect: () => [1],
);
```

```dart
await testNocterm('counter view', (tester) async {
  final cubit = CounterCubit();
  await tester.pumpComponent(
    BlocProvider.value(value: cubit, child: CounterView()),
  );
  expect(tester.terminalState, containsText('0'));
});
```

## Crux Ownership Rules

Do not create a single mega-state for the whole chat panel. Pick the owner that
can maintain the full lifecycle of the state:

| State | Cubit |
|---|---|
| session list/current id/message cache/loading/pending images/input stash/queued messages | `SessionCubit` |
| in-flight text/reasoning/tool previews/waiting/executing state | `StreamingCubit` |
| TTFT/token rate/context target/cache hit | `MetricsCubit` |
| turn phase/active id/status/error/TLDR generation | `ChatTurnCubit` |
| ephemeral `/btw` chain | `BtwCubit` |
| compaction phase/hysteresis/failures | `CompactionCubit` |
| slash/parameter/@mention/session/fullpane overlay state | `OverlayCubit` |

If no owner fits, add a small owner rather than tucking the field into
`SessionCubit` by default.

## Migration Pattern

When replacing a `setState` or `_refresh()` path:

1. Identify the data that changed.
2. Add or reuse a semantic cubit method, such as `putCachedMessages`,
   `setQueuedMessages`, or `setGeneratingTitle`.
3. Keep legacy controller fields in sync only while existing widgets still read
   them.
4. Subscribe the smallest stable widget boundary with `BlocBuilder`.
5. Remove the refresh call only after the cubit emission reaches every affected
   reader.

Avoid exposing mutable collections from cubit state. Store lists and maps as
unmodifiable snapshots, and add tests that verify callers cannot mutate them.

## Builder Placement

Place builders where the rebuild cost matches the state:

- `ChatPanel`: navigation, overlay gates, command/session/fullpane shell.
- `ChatHistory`: message-list composition and local highlighting.
- Individual bubbles: high-frequency streaming content and local animation.
- Toolbars/status widgets: metrics and compact projections.

High-frequency streams should not rebuild `ChatPanel`. Use a focused builder
inside the component that paints the changing content.
