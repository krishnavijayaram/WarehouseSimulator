/// sim_random.dart — the ONLY sanctioned source of randomness in the sim.
///
/// The spec wants demand to look random; the JEPA eval needs runs to be exactly
/// reproducible. Both hold only if every draw comes from one seeded generator
/// that is INJECTED, never constructed ad-hoc.
///
/// Rules enforced from here on:
///   • No brain constructs its own `Random`, and no brain reads a wall clock.
///     The sim's clock is `BrainContext.tick`; its randomness is a [SimRng].
///   • Each consumer gets its OWN child RNG (`derive`) so adding a new consumer
///     never shifts an existing one's draw sequence — the property that keeps a
///     replay byte-identical when the cast changes.
///
/// LOCAL sim only.
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Default seed. Any fixed value works; it is pinned so a run replays exactly.
const int kSimSeed = 20260716;

/// The seed in force for this sim. Tests override it to pin a scenario.
final simSeedProvider = StateProvider<int>((_) => kSimSeed);

/// A small, deterministic RNG facade. Deliberately thin: every method is a pure
/// function of the seed and the number of prior draws.
class SimRng {
  SimRng(this.seed) : _r = Random(seed);

  final int seed;
  final Random _r;

  /// A child RNG for one consumer. Derived from this RNG's seed and a stable
  /// [salt] (e.g. a role name), NOT from the parent's draw sequence — so two
  /// consumers never interfere and a third can be added without disturbing them.
  SimRng derive(String salt) {
    var h = seed;
    for (final unit in salt.codeUnits) {
      h = (h * 31 + unit) & 0x3FFFFFFF; // keep in Random's positive 32-bit range
    }
    return SimRng(h);
  }

  /// Uniform int in [min, max] inclusive. Returns [min] if the range is empty.
  int nextIntIn(int min, int max) {
    if (max <= min) return min;
    return min + _r.nextInt(max - min + 1);
  }

  /// Uniform element of [items]. Throws on empty — callers must guard, because a
  /// silent null here would masquerade as "no work available".
  T pick<T>(List<T> items) {
    if (items.isEmpty) {
      throw StateError('SimRng.pick called with no items');
    }
    return items[_r.nextInt(items.length)];
  }

  /// Weighted pick. [weights] must align with [items]; non-positive weights are
  /// treated as zero. Falls back to a uniform pick if every weight is zero.
  T pickWeighted<T>(List<T> items, List<num> weights) {
    if (items.isEmpty) {
      throw StateError('SimRng.pickWeighted called with no items');
    }
    var total = 0.0;
    for (final w in weights) {
      if (w > 0) total += w.toDouble();
    }
    if (total <= 0) return pick(items);
    var roll = _r.nextDouble() * total;
    for (var i = 0; i < items.length && i < weights.length; i++) {
      final w = weights[i] > 0 ? weights[i].toDouble() : 0.0;
      if (w <= 0) continue;
      roll -= w;
      if (roll <= 0) return items[i];
    }
    return items.last;
  }

  /// `base` ± up to [spread], floored at [floor]. For jittering intervals so
  /// generators don't emit in lockstep.
  int jitter(int base, int spread, {int floor = 1}) {
    final j = base + nextIntIn(-spread, spread);
    return j < floor ? floor : j;
  }

  /// True with probability [p] (clamped to 0..1).
  bool chance(double p) => _r.nextDouble() < p.clamp(0.0, 1.0);
}
