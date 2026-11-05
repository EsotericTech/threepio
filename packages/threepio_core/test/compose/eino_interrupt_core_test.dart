// Port of eino `internal/core/interrupt_test.go` (v0.9.22).
//
// The Go tests build the private `addrCtx` and `globalResumeInfo` structs by
// hand. Both are private here as well, so the same states are reached through
// `appendAddressSegmentTo`, `populateInterruptState` and
// `batchResumeWithData`. A comment marks every case that is approximated.
//
// Dart has `null` where Go has the zero value of `T` (`""`) in the answers of
// `getInterruptState` and `getResumeContext`.
import 'package:test/test.dart';
import 'package:threepio_core/src/compose/address.dart';
import 'package:threepio_core/src/compose/interrupt.dart';
import 'package:threepio_core/src/compose/resume.dart';
import 'package:threepio_core/src/core/run_context.dart';

// Go: the constants AddressSegmentAgent, AddressSegmentTool and
// AddressSegmentNode the test file declares for itself.
const _agent = AddressSegmentType('agent');
const _tool = AddressSegmentType.tool;
const _node = AddressSegmentType.node;

AddressSegment _seg(AddressSegmentType type, String id, [String subId = '']) =>
    AddressSegment(type: type, id: id, subId: subId);

/// The address `agent:<id>`.
Address _agentAddress(String id) => Address([_seg(_agent, id)]);

/// [ctx] at [address]. Go: `context.WithValue(ctx, addrCtxKey{},
/// &addrCtx{addr: address})`.
RunContext _at(RunContext ctx, Address address) {
  var next = ctx;
  for (final segment in address.segments) {
    next = appendAddressSegmentTo(next, segment.type, segment.id, segment.subId);
  }
  return next;
}

/// A context whose address context carries [state]. Go:
/// `&addrCtx{interruptState: &state}`. The state is populated first; the
/// segment that enters its address picks it up.
RunContext _withInterruptState(InterruptState state) {
  final address = _agentAddress('agent1');
  final populated = populateInterruptState(
    RunContext.background(),
    {'interrupt1': address},
    {'interrupt1': state},
  );
  return _at(populated, address);
}

/// A context that is a resume target with [data]. Go:
/// `&addrCtx{isResumeTarget: true, resumeData: data}`.
RunContext _resumeTarget(Object? data) {
  final address = _agentAddress('agent1');
  final resumed =
      RunContext.background().batchResumeWithData({'interrupt1': data});
  final populated = populateInterruptState(
    resumed,
    {'interrupt1': address},
    {'interrupt1': const InterruptState()},
  );
  return _at(populated, address);
}

/// What `rInfo.id2ResumeData[id]` holds, seen the way a component sees it:
/// the interrupt [id] is given an address, and the context that enters that
/// address is asked for its resume data.
({bool isResumeTarget, bool hasData, String? data}) _resumeDataOf(
  RunContext ctx,
  String id,
) {
  final address = _agentAddress('component-$id');
  final populated = populateInterruptState(
    ctx,
    {id: address},
    {id: const InterruptState()},
  );
  return getResumeContext<String>(_at(populated, address));
}

AddressedInterruptSignal _signal(
  String id,
  List<AddressSegment> address, {
  Object? state,
  Object? payload,
  List<AddressedInterruptSignal> subs = const [],
}) =>
    AddressedInterruptSignal(
      id: id,
      address: Address(address),
      state: InterruptState(state: state, layerSpecificPayload: payload),
      subs: subs,
    );

/// Go compares the two `InterruptState` struct values. The Dart class has no
/// `==`, so its fields are compared.
void _expectState(InterruptState? actual, InterruptState expected) {
  expect(actual, isNotNull);
  expect(actual!.state, expected.state);
  expect(actual.layerSpecificPayload, expected.layerSpecificPayload);
}

void main() {
  group('TestInterruptConversion', () {
    // Test Case 1: Simple Chain (A -> B -> C)
    test('SimpleChain', () {
      // The user-facing contexts with parent pointers.
      const ctxA = InterruptCtx(id: 'A', address: Address.empty());
      const ctxB = InterruptCtx(id: 'B', address: Address.empty(), parent: ctxA);
      const ctxC = InterruptCtx(
        id: 'C',
        address: Address.empty(),
        isRootCause: true,
        parent: ctxB,
      );

      // The input is just the root cause leaf node.
      final signal = fromInterruptContexts([ctxC]);

      expect(signal, isNotNull);
      expect(signal!.id, 'A');
      expect(signal.subs, hasLength(1));
      expect(signal.subs[0].id, 'B');
      expect(signal.subs[0].subs, hasLength(1));
      expect(signal.subs[0].subs[0].id, 'C');
      expect(signal.subs[0].subs[0].isRootCause, isTrue);

      // And back from the signal tree to user-facing contexts.
      final finalContexts = toInterruptContexts(signal);

      expect(finalContexts, hasLength(1));
      final finalC = finalContexts[0];
      expect(finalC.id, 'C');
      expect(finalC.isRootCause, isTrue);
      expect(finalC.parent, isNotNull);
      expect(finalC.parent!.id, 'B');
      expect(finalC.parent!.parent, isNotNull);
      expect(finalC.parent!.parent!.id, 'A');
      expect(finalC.parent!.parent!.parent, isNull);
    });

    // Test Case 2: Multiple Root Causes with Shared Parent (B -> D, C -> D)
    test('MultipleRootsSharedParent', () {
      const ctxD = InterruptCtx(id: 'D', address: Address.empty());
      const ctxB = InterruptCtx(
        id: 'B',
        address: Address.empty(),
        isRootCause: true,
        parent: ctxD,
      );
      const ctxC = InterruptCtx(
        id: 'C',
        address: Address.empty(),
        isRootCause: true,
        parent: ctxD,
      );

      // The input contains both root cause leaves.
      final signal = fromInterruptContexts([ctxB, ctxC]);

      // The tree merges at D.
      expect(signal, isNotNull);
      expect(signal!.id, 'D');
      expect(signal.subs, hasLength(2));
      final subIds = [signal.subs[0].id, signal.subs[1].id];
      expect(subIds, contains('B'));
      expect(subIds, contains('C'));

      final finalContexts = toInterruptContexts(signal);

      expect(finalContexts, hasLength(2));
      final finalIds = [finalContexts[0].id, finalContexts[1].id];
      expect(finalIds, contains('B'));
      expect(finalIds, contains('C'));

      // Parent linking for one of the branches.
      final finalB =
          finalContexts[0].id == 'B' ? finalContexts[0] : finalContexts[1];
      expect(finalB.parent, isNotNull);
      expect(finalB.parent!.id, 'D');
      expect(finalB.parent!.parent, isNull);
    });

    // Test Case 3: Nil and Empty Inputs
    test('NilAndEmpty', () {
      // A Dart list is never nil: Go's nil slice and its empty slice are the
      // same case here.
      expect(fromInterruptContexts(const []), isNull);
      expect(fromInterruptContexts(<InterruptCtx>[]), isNull);
      // Dart gives an empty list where Go returns nil.
      expect(toInterruptContexts(null), isEmpty);
    });
  });

  group('TestSignalToPersistenceMaps', () {
    // Test Case 1: Nil Signal
    test('NilSignal', () {
      final (id2addr, id2state) = signalToPersistenceMaps(null);
      expect(id2addr, isNotNull);
      expect(id2state, isNotNull);
      expect(id2addr, isEmpty);
      expect(id2state, isEmpty);
    });

    // Test Case 2: Single Node Signal
    test('SingleNode', () {
      final signal = _signal(
        'node1',
        [_seg(_agent, 'agent1')],
        state: 'test state',
        payload: 'test payload',
      );

      final (id2addr, id2state) = signalToPersistenceMaps(signal);

      expect(id2addr, hasLength(1));
      expect(id2state, hasLength(1));

      expect(id2addr['node1'], signal.address);
      _expectState(id2state['node1'], signal.state);
      expect(id2state['node1']!.state, 'test state');
      expect(id2state['node1']!.layerSpecificPayload, 'test payload');
    });

    // Test Case 3: Simple Tree Structure
    test('SimpleTree', () {
      final child1 = _signal(
        'child1',
        [_seg(_agent, 'agent1'), _seg(_tool, 'tool1')],
        state: 'child1 state',
      );
      final child2 = _signal(
        'child2',
        [_seg(_agent, 'agent1'), _seg(_tool, 'tool2')],
        state: 'child2 state',
      );
      final parent = _signal(
        'parent',
        [_seg(_agent, 'agent1')],
        state: 'parent state',
        subs: [child1, child2],
      );

      final (id2addr, id2state) = signalToPersistenceMaps(parent);

      // All 3 nodes.
      expect(id2addr, hasLength(3));
      expect(id2state, hasLength(3));

      expect(id2addr['parent'], parent.address);
      _expectState(id2state['parent'], parent.state);

      expect(id2addr['child1'], child1.address);
      _expectState(id2state['child1'], child1.state);
      expect(id2addr['child2'], child2.address);
      _expectState(id2state['child2'], child2.state);
    });

    // Test Case 4: Deeply Nested Tree
    test('DeeplyNestedTree', () {
      final leaf1 = _signal(
        'leaf1',
        [_seg(_agent, 'agent1'), _seg(_tool, 'tool1'), _seg(_node, 'node1')],
        state: 'leaf1 state',
      );
      final leaf2 = _signal(
        'leaf2',
        [_seg(_agent, 'agent1'), _seg(_tool, 'tool1'), _seg(_node, 'node2')],
        state: 'leaf2 state',
      );
      final middle = _signal(
        'middle',
        [_seg(_agent, 'agent1'), _seg(_tool, 'tool1')],
        state: 'middle state',
        subs: [leaf1, leaf2],
      );
      final root = _signal(
        'root',
        [_seg(_agent, 'agent1')],
        state: 'root state',
        subs: [middle],
      );

      final (id2addr, id2state) = signalToPersistenceMaps(root);

      // All 4 nodes.
      expect(id2addr, hasLength(4));
      expect(id2state, hasLength(4));

      expect(id2addr['root'], root.address);
      _expectState(id2state['root'], root.state);
      expect(id2addr['middle'], middle.address);
      _expectState(id2state['middle'], middle.state);
      expect(id2addr['leaf1'], leaf1.address);
      _expectState(id2state['leaf1'], leaf1.state);
      expect(id2addr['leaf2'], leaf2.address);
      _expectState(id2state['leaf2'], leaf2.state);
    });

    // Test Case 5: Complex Tree with Multiple Branches
    test('ComplexTree', () {
      final a1 = [_seg(_agent, 'a1')];
      final branch1Leaf1 = _signal('b1l1', a1, state: 'b1l1');
      final branch1Leaf2 = _signal('b1l2', a1, state: 'b1l2');
      final branch1 =
          _signal('b1', a1, state: 'b1', subs: [branch1Leaf1, branch1Leaf2]);

      final branch2Leaf1 = _signal('b2l1', a1, state: 'b2l1');
      final branch2 = _signal('b2', a1, state: 'b2', subs: [branch2Leaf1]);

      final root = _signal('root', a1, state: 'root', subs: [branch1, branch2]);

      final (id2addr, id2state) = signalToPersistenceMaps(root);

      // All 6 nodes.
      expect(id2addr, hasLength(6));
      expect(id2state, hasLength(6));

      for (final nodeId in ['root', 'b1', 'b2', 'b1l1', 'b1l2', 'b2l1']) {
        expect(id2addr, contains(nodeId));
        expect(id2state, contains(nodeId));
      }
    });

    // Test Case 6: Empty InterruptState Values
    test('EmptyInterruptState', () {
      final signal = AddressedInterruptSignal(
        id: 'node1',
        address: _agentAddress('agent1'),
      );

      final (id2addr, id2state) = signalToPersistenceMaps(signal);

      expect(id2addr, hasLength(1));
      expect(id2state, hasLength(1));
      expect(id2addr['node1'], signal.address);
      _expectState(id2state['node1'], signal.state);
      expect(id2state['node1']!.state, isNull);
      expect(id2state['node1']!.layerSpecificPayload, isNull);
    });
  });

  group('TestGetCurrentAddress', () {
    // Test Case 1: No Address in Context
    test('NoAddressInContext', () {
      final ctx = RunContext.background();
      // Dart gives the empty address where Go returns nil.
      expect(ctx.currentAddress.isEmpty, isTrue);
      expect(ctx.currentAddress, const Address.empty());
    });

    // Test Case 2: Address in Context
    test('AddressInContext', () {
      final expectedAddr =
          Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]);

      // Go sets addrCtx{addr: expectedAddr}; here the two segments are
      // entered one after the other.
      final ctx = _at(RunContext.background(), expectedAddr);

      expect(ctx.currentAddress, expectedAddr);
    });
  });

  group('TestGetNextResumptionPoints', () {
    // Test Case 1: No Resume Info in Context
    test('NoResumeInfo', () {
      // Dart returns null where Go returns the error "GetNextResumptionPoints:
      // failed to get resume info from context".
      expect(nextResumptionPoints(RunContext.background()), isNull);
    });

    // Test Case 2: Empty Resume Info
    test('EmptyResumeInfo', () {
      // Go: globalResumeInfo{id2Addr: {}} set by hand.
      final ctx = populateInterruptState(RunContext.background(), {}, {});

      final points = nextResumptionPoints(ctx);
      expect(points, isNotNull);
      expect(points, isEmpty);
    });

    // Test Case 3: Valid Resume Points
    test('ValidResumePoints', () {
      // The current address, then the resume info with child addresses.
      var ctx = _at(RunContext.background(), _agentAddress('agent1'));
      ctx = populateInterruptState(
        ctx,
        {
          'child1': Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]),
          'child2': Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool2')]),
          'unrelated': _agentAddress('agent2'),
        },
        {},
      );

      final points = nextResumptionPoints(ctx);
      expect(points, isNotNull);
      expect(points, hasLength(2));
      expect(points, contains('tool1'));
      expect(points, contains('tool2'));
    });

    // Test Case 4: Root Address (Empty Parent)
    test('RootAddress', () {
      // Approximated: Go has an addrCtx with an empty address; here the
      // context has no address context, which reads as the empty address.
      final ctx = populateInterruptState(
        RunContext.background(),
        {
          'agent1': _agentAddress('agent1'),
          'agent2': _agentAddress('agent2'),
        },
        {},
      );
      expect(ctx.currentAddress.isEmpty, isTrue);

      final points = nextResumptionPoints(ctx);
      expect(points, isNotNull);
      expect(points, hasLength(2));
      expect(points, contains('agent1'));
      expect(points, contains('agent2'));
    });
  });

  // Go reads the private `rInfo.id2ResumeData`. Here the data of an id is
  // read the way a component gets it (see `_resumeDataOf`), and "the context
  // has a resume info" is `nextResumptionPoints` not being null.
  group('TestBatchResumeWithData', () {
    // Test Case 1: New Resume Data
    test('NewResumeData', () {
      final ctx = RunContext.background();
      final newCtx = ctx.batchResumeWithData({'id1': 'data1', 'id2': 'data2'});

      expect(nextResumptionPoints(ctx), isNull);
      expect(nextResumptionPoints(newCtx), isNotNull);
      final first = _resumeDataOf(newCtx, 'id1');
      expect(first.isResumeTarget, isTrue);
      expect(first.hasData, isTrue);
      expect(first.data, 'data1');
      final second = _resumeDataOf(newCtx, 'id2');
      expect(second.isResumeTarget, isTrue);
      expect(second.hasData, isTrue);
      expect(second.data, 'data2');
    });

    // Test Case 2: Merge with Existing Resume Data
    test('MergeWithExisting', () {
      // First call with initial data, second call with additional data.
      final ctx = RunContext.background().batchResumeWithData({'id1': 'initial'});
      final newCtx = ctx.batchResumeWithData({'id2': 'additional'});

      // Both data sets are present.
      expect(nextResumptionPoints(newCtx), isNotNull);
      expect(_resumeDataOf(newCtx, 'id1').data, 'initial');
      expect(_resumeDataOf(newCtx, 'id2').data, 'additional');
    });

    // Test Case 3: Empty Resume Data
    test('EmptyResumeData', () {
      final newCtx = RunContext.background().batchResumeWithData({});

      expect(nextResumptionPoints(newCtx), isNotNull);
      // An empty id2ResumeData: no interrupt id is resumed.
      final resumed = _resumeDataOf(newCtx, 'id1');
      expect(resumed.isResumeTarget, isFalse);
      expect(resumed.hasData, isFalse);
      expect(resumed.data, isNull);
    });
  });

  group('TestGetInterruptState', () {
    // Test Case 1: No Interrupt State
    test('NoInterruptState', () {
      final previous = getInterruptState<String>(RunContext.background());
      expect(previous.wasInterrupted, isFalse);
      expect(previous.hasState, isFalse);
      expect(previous.state, isNull);
    });

    // Test Case 2: With Interrupt State
    test('WithInterruptState', () {
      final ctx =
          _withInterruptState(const InterruptState(state: 'test state'));

      final previous = getInterruptState<String>(ctx);
      expect(previous.wasInterrupted, isTrue);
      expect(previous.hasState, isTrue);
      expect(previous.state, 'test state');
    });

    // Test Case 3: Wrong Type for Interrupt State
    test('WrongType', () {
      // An int instead of a string.
      final ctx = _withInterruptState(const InterruptState(state: 123));

      final previous = getInterruptState<String>(ctx);
      expect(previous.wasInterrupted, isTrue);
      expect(previous.hasState, isFalse); // false due to the type mismatch
      expect(previous.state, isNull);
    });

    // Test Case 4: Nil Interrupt State
    test('NilInterruptState', () {
      // An address context without an interrupt state.
      final ctx = _at(RunContext.background(), _agentAddress('agent1'));

      final previous = getInterruptState<String>(ctx);
      expect(previous.wasInterrupted, isFalse);
      expect(previous.hasState, isFalse);
      expect(previous.state, isNull);
      expect(interruptStateOf(ctx), isNull);
    });
  });

  group('TestGetResumeContext', () {
    // Test Case 1: Not Resume Target
    test('NotResumeTarget', () {
      final resumed = getResumeContext<String>(RunContext.background());
      expect(resumed.isResumeTarget, isFalse);
      expect(resumed.hasData, isFalse);
      expect(resumed.data, isNull);
    });

    // Test Case 2: Resume Target with Data
    test('ResumeTargetWithData', () {
      final resumed = getResumeContext<String>(_resumeTarget('resume data'));
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isTrue);
      expect(resumed.data, 'resume data');
    });

    // Test Case 3: Resume Target without Data
    test('ResumeTargetWithoutData', () {
      final resumed = getResumeContext<String>(_resumeTarget(null));
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isFalse);
      expect(resumed.data, isNull);
    });

    // Test Case 4: Wrong Type for Resume Data
    test('WrongType', () {
      // An int instead of a string.
      final resumed = getResumeContext<String>(_resumeTarget(123));
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isFalse); // false due to the type mismatch
      expect(resumed.data, isNull);
    });
  });

  // Go's `InterruptConfig` and the option `WithLayerPayload` are the named
  // parameter `layerPayload` of `newInterruptSignal` here. What the option
  // sets is read from the signal it ends up in.
  group('TestWithLayerPayload', () {
    final ctx = RunContext.background();

    // Test Case 1: Basic Usage
    test('BasicUsage', () {
      final signal = newInterruptSignal(
        ctx,
        null,
        null,
        const [],
        layerPayload: 'test payload',
      );
      expect(signal.state.layerSpecificPayload, 'test payload');
    });

    // Test Case 2: Nil Payload
    test('NilPayload', () {
      // Approximated: there is no config object whose "existing" payload a
      // nil option overwrites; a nil payload gives a signal without payload.
      const Object? payload = null;
      final signal =
          newInterruptSignal(ctx, null, null, const [], layerPayload: payload);
      expect(signal.state.layerSpecificPayload, isNull);
    });

    // Test Case 3: Complex Payload
    test('ComplexPayload', () {
      final payload = <String, Object?>{'key1': 'value1', 'key2': 123};
      final signal =
          newInterruptSignal(ctx, null, null, const [], layerPayload: payload);
      expect(signal.state.layerSpecificPayload, payload);
    });
  });

  group('TestInterruptFunction', () {
    // Test Case 1: Simple Interrupt without SubContexts
    test('SimpleInterrupt', () {
      final expectedAddr = _agentAddress('test-agent');
      final ctx = _at(RunContext.background(), expectedAddr);

      const info = 'test info';
      const state = 'test state';

      // Go passes nil for the sub contexts.
      final signal = newInterruptSignal(ctx, info, state, const []);
      expect(signal.id, isNotEmpty);
      expect(signal.info, info);
      expect(signal.state.state, state);
      expect(signal.isRootCause, isTrue);
      expect(signal.address, expectedAddr);
    });

    // Test Case 2: Interrupt with SubContexts
    test('InterruptWithSubContexts', () {
      final ctx = _at(RunContext.background(), _agentAddress('parent-agent'));

      final subContexts = [
        AddressedInterruptSignal(
          id: 'child1',
          address: _agentAddress('child1'),
        ),
        AddressedInterruptSignal(
          id: 'child2',
          address: _agentAddress('child2'),
        ),
      ];

      const info = 'parent info';
      const state = 'parent state';

      final signal = newInterruptSignal(ctx, info, state, subContexts);
      expect(signal.id, isNotEmpty);
      expect(signal.info, info);
      expect(signal.state.state, state);
      expect(signal.isRootCause, isFalse); // false when there are sub contexts
      expect(signal.subs, hasLength(2));
      expect(signal.subs[0].id, 'child1');
      expect(signal.subs[1].id, 'child2');
    });

    // Test Case 3: Interrupt with Options
    test('InterruptWithOptions', () {
      final ctx = _at(RunContext.background(), _agentAddress('test-agent'));

      const info = 'test info';
      const state = 'test state';
      const layerPayload = 'layer payload';

      final signal = newInterruptSignal(
        ctx,
        info,
        state,
        const [],
        layerPayload: layerPayload,
      );
      expect(signal.state.layerSpecificPayload, layerPayload);
    });

    // Test Case 4: Empty SubContexts
    test('EmptySubContexts', () {
      final ctx = _at(RunContext.background(), _agentAddress('test-agent'));

      const info = 'test info';
      const state = 'test state';

      final signal =
          newInterruptSignal(ctx, info, state, <AddressedInterruptSignal>[]);
      expect(signal.isRootCause, isTrue); // true when sub contexts is empty
      expect(signal.subs, isEmpty);
    });
  });

  group('TestAddressMethods', () {
    // Test Case 1: Address.String()
    test('AddressString', () {
      final addr = Address([
        _seg(_agent, 'agent1'),
        _seg(_tool, 'tool1'),
        _seg(_node, 'node1', 'sub1'),
      ]);

      expect(addr.toString(), 'agent:agent1;tool:tool1;node:node1:sub1');
    });

    // Test Case 2: Address.String() with empty address
    test('EmptyAddressString', () {
      // Go: a nil Address.
      expect(const Address.empty().toString(), '');
      expect(Address(const []).toString(), '');
    });

    // Test Case 3: Address.Equals() with equal addresses
    test('AddressEquals', () {
      final addr1 = Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]);
      final addr2 = Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]);

      expect(addr1 == addr2, isTrue);
    });

    // Test Case 4: Address.Equals() with different addresses
    test('AddressNotEquals', () {
      final addr1 = Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]);
      final addr2 = Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool2')]);

      expect(addr1 == addr2, isFalse);
    });

    // Test Case 5: Address.Equals() with different lengths
    test('AddressDifferentLengths', () {
      final addr1 = Address([_seg(_agent, 'agent1'), _seg(_tool, 'tool1')]);
      final addr2 = Address([_seg(_agent, 'agent1')]);

      expect(addr1 == addr2, isFalse);
    });

    // Test Case 6: Address.Equals() with SubID differences
    test('AddressSubIDDifference', () {
      final addr1 = Address([_seg(_agent, 'agent1', 'sub1')]);
      final addr2 = Address([_seg(_agent, 'agent1', 'sub2')]);

      expect(addr1 == addr2, isFalse);
    });
  });

  group('TestAppendAddressSegment', () {
    // Test Case 1: Append to empty address
    test('AppendToEmpty', () {
      final ctx = RunContext.background();

      final newCtx = appendAddressSegmentTo(ctx, _agent, 'agent1');

      final addr = newCtx.currentAddress;
      expect(addr.segments, hasLength(1));
      expect(addr.segments[0].type, _agent);
      expect(addr.segments[0].id, 'agent1');
      expect(addr.segments[0].subId, '');
    });

    // Test Case 2: Append to existing address
    test('AppendToExisting', () {
      // First append, second append.
      final ctx = appendAddressSegmentTo(RunContext.background(), _agent, 'agent1');
      final newCtx = appendAddressSegmentTo(ctx, _tool, 'tool1', 'call1');

      final addr = newCtx.currentAddress;
      expect(addr.segments, hasLength(2));
      expect(addr.segments[0].type, _agent);
      expect(addr.segments[0].id, 'agent1');
      expect(addr.segments[1].type, _tool);
      expect(addr.segments[1].id, 'tool1');
      expect(addr.segments[1].subId, 'call1');
    });

    // Test Case 3: Append with SubID
    test('AppendWithSubID', () {
      final newCtx = appendAddressSegmentTo(
        RunContext.background(),
        _tool,
        'tool1',
        'call123',
      );

      final addr = newCtx.currentAddress;
      expect(addr.segments, hasLength(1));
      expect(addr.segments[0].type, _tool);
      expect(addr.segments[0].id, 'tool1');
      expect(addr.segments[0].subId, 'call123');
    });
  });

  group('TestPopulateInterruptState', () {
    // Test Case 1: Populate with matching address
    test('PopulateMatchingAddress', () {
      // The current address first, as in Go; the state is then applied to it.
      final currentAddr = _agentAddress('agent1');
      final ctx = _at(RunContext.background(), currentAddr);

      final newCtx = populateInterruptState(
        ctx,
        {'interrupt1': currentAddr},
        {'interrupt1': const InterruptState(state: 'test state')},
      );

      final previous = getInterruptState<String>(newCtx);
      expect(previous.wasInterrupted, isTrue);
      expect(previous.hasState, isTrue);
      expect(previous.state, 'test state');
    });

    // Test Case 2: Populate with non-matching address
    test('PopulateNonMatchingAddress', () {
      final ctx = _at(RunContext.background(), _agentAddress('agent1'));

      // Interrupt state data with a different address.
      final newCtx = populateInterruptState(
        ctx,
        {'interrupt1': _agentAddress('agent2')},
        {'interrupt1': const InterruptState(state: 'test state')},
      );

      // The state was NOT populated (no matching address).
      final previous = getInterruptState<String>(newCtx);
      expect(previous.wasInterrupted, isFalse);
      expect(previous.hasState, isFalse);
      expect(previous.state, isNull);
    });

    // Test Case 3: Populate with empty data
    test('PopulateEmptyData', () {
      final newCtx = populateInterruptState(RunContext.background(), {}, {});

      final previous = getInterruptState<String>(newCtx);
      expect(previous.wasInterrupted, isFalse);
      expect(previous.hasState, isFalse);
      expect(previous.state, isNull);
    });
  });

  // Not ported, no Dart equivalent: `InterruptStateStringNil` and
  // `InterruptInfoStringNil` call `String()` on a nil pointer.
  group('TestStringMethods', () {
    // Test Case 1: InterruptSignal.Error()
    test('InterruptSignalError', () {
      final signal = AddressedInterruptSignal(
        id: 'test-id',
        address: _agentAddress('agent1'),
        info: 'test info',
        state: const InterruptState(
          state: 'test state',
          layerSpecificPayload: 'test payload',
        ),
        subs: [
          AddressedInterruptSignal(id: 'sub1', address: const Address.empty()),
        ],
      );

      // Go: signal.Error().
      final errorStr = signal.toString();
      for (final expected in [
        'interrupt signal:',
        'ID=test-id',
        'Addr=agent:agent1',
        'Info=interrupt info: Info=test info, IsRootCause=false',
        'State=interrupt state: State=test state, LayerSpecificPayload=test payload',
        'SubsLen=1',
      ]) {
        expect(errorStr, contains(expected));
      }
    });

    // Test Case 2: InterruptState.String()
    test('InterruptStateString', () {
      const state = InterruptState(
        state: 'test state',
        layerSpecificPayload: 'test payload',
      );

      expect(
        state.toString(),
        'interrupt state: State=test state, LayerSpecificPayload=test payload',
      );
    });

    // Test Case 4: InterruptInfo.String()
    test('InterruptInfoString', () {
      // Approximated: `core.InterruptInfo` is not a class of its own here (its
      // two fields are fields of the signal), so its text is read where the
      // signal prints it.
      final signal = AddressedInterruptSignal(
        id: 'test-id',
        address: const Address.empty(),
        info: 'test info',
        isRootCause: true,
      );

      expect(
        signal.toString(),
        contains('Info=interrupt info: Info=test info, IsRootCause=true, '),
      );
    });
  });

  group('TestInterruptCtxEqualsWithoutID', () {
    // Test Case 1: Equal contexts
    test('EqualContexts', () {
      final ctx1 = InterruptCtx(
        id: 'id1',
        address: _agentAddress('agent1'),
        info: 'info1',
        isRootCause: true,
      );
      final ctx2 = InterruptCtx(
        id: 'id2', // a different id is ignored
        address: _agentAddress('agent1'),
        info: 'info1',
        isRootCause: true,
      );

      expect(ctx1.equalsWithoutId(ctx2), isTrue);
    });

    // Test Case 2: Different addresses
    test('DifferentAddresses', () {
      final ctx1 = InterruptCtx(id: '', address: _agentAddress('agent1'));
      final ctx2 = InterruptCtx(id: '', address: _agentAddress('agent2'));

      expect(ctx1.equalsWithoutId(ctx2), isFalse);
    });

    // Test Case 3: Different root cause flags
    test('DifferentRootCause', () {
      final ctx1 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        isRootCause: true,
      );
      final ctx2 = InterruptCtx(id: '', address: _agentAddress('agent1'));

      expect(ctx1.equalsWithoutId(ctx2), isFalse);
    });

    // Test Case 4: Different info
    test('DifferentInfo', () {
      final ctx1 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        info: 'info1',
      );
      final ctx2 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        info: 'info2',
      );

      expect(ctx1.equalsWithoutId(ctx2), isFalse);
    });

    // Test Case 5: Nil contexts
    test('NilContexts', () {
      // Not ported, no Dart equivalent: the two assertions that call
      // EqualsWithoutID on a nil receiver (nil == nil is true, nil against a
      // context is false). What remains is a context against nil.
      const ctx3 = InterruptCtx(id: '', address: Address.empty());
      expect(ctx3.equalsWithoutId(null), isFalse);
    });

    // Test Case 6: With parent contexts
    test('WithParentContexts', () {
      final parent1 = InterruptCtx(id: '', address: _agentAddress('parent'));
      final parent2 = InterruptCtx(id: '', address: _agentAddress('parent'));

      final ctx1 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        parent: parent1,
      );
      final ctx2 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        parent: parent2,
      );

      expect(ctx1.equalsWithoutId(ctx2), isTrue);
    });

    // Test Case 7: Different parent contexts
    test('DifferentParentContexts', () {
      final parent1 = InterruptCtx(id: '', address: _agentAddress('parent1'));
      final parent2 = InterruptCtx(id: '', address: _agentAddress('parent2'));

      final ctx1 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        parent: parent1,
      );
      final ctx2 = InterruptCtx(
        id: '',
        address: _agentAddress('agent1'),
        parent: parent2,
      );

      expect(ctx1.equalsWithoutId(ctx2), isFalse);
    });
  });
}
