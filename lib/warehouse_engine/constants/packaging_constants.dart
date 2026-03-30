// packaging_constants.dart
// Ported from: SyntWare/shared/constants.py
// Pure data — no network/DB/UI dependency.

/// Reference pallet volume used for SPN classification.
const double kReferencePalletVolumeM3 = 1.20;

/// SPN (Size-Pack-Numeral) classification thresholds.
/// Based on percentage of reference pallet volume.
enum SPNClass {
  micro, // ≤10 % of reference pallet
  small, // ≤25 %
  medium, // ≤50 %
  large; //  >50 %

  static SPNClass fromVolume(double volumeM3) {
    final pct = volumeM3 / kReferencePalletVolumeM3;
    if (pct <= 0.10) return SPNClass.micro;
    if (pct <= 0.25) return SPNClass.small;
    if (pct <= 0.50) return SPNClass.medium;
    return SPNClass.large;
  }
}

class CaseDims {
  final int lengthCm, widthCm, heightCm;
  final double volumeM3;
  const CaseDims({
    required this.lengthCm,
    required this.widthCm,
    required this.heightCm,
    required this.volumeM3,
  });
}

class TruckCapacity {
  final String name;
  final int maxWeightKg;
  final double maxVolumeM3;
  const TruckCapacity({
    required this.name,
    required this.maxWeightKg,
    required this.maxVolumeM3,
  });
}

class PalletDims {
  final int baseLengthCm, baseWidthCm, heightCm;
  final double volumeM3;
  const PalletDims({
    required this.baseLengthCm,
    required this.baseWidthCm,
    required this.heightCm,
    required this.volumeM3,
  });
}

/// Carton case dimensions by size tier (S / M / L).
const Map<String, CaseDims> kCaseDims = {
  'S': CaseDims(lengthCm: 30, widthCm: 20, heightCm: 20, volumeM3: 0.012),
  'M': CaseDims(lengthCm: 40, widthCm: 30, heightCm: 25, volumeM3: 0.030),
  'L': CaseDims(lengthCm: 60, widthCm: 40, heightCm: 30, volumeM3: 0.072),
};

/// Standard pallet dimensions by size tier.
const Map<String, PalletDims> kPalletDims = {
  'S': PalletDims(
      baseLengthCm: 80, baseWidthCm: 60, heightCm: 150, volumeM3: 0.72),
  'M': PalletDims(
      baseLengthCm: 100, baseWidthCm: 80, heightCm: 150, volumeM3: 1.20),
  'L': PalletDims(
      baseLengthCm: 120, baseWidthCm: 100, heightCm: 150, volumeM3: 1.80),
};

/// Vehicle capacity by size tier.
/// Named after common Indian commercial trucks.
const Map<String, TruckCapacity> kTruckCapacity = {
  'S': TruckCapacity(name: 'Tata Ace', maxWeightKg: 1000, maxVolumeM3: 4.0),
  'M': TruckCapacity(name: 'Tata 407', maxWeightKg: 3000, maxVolumeM3: 12.0),
  'L': TruckCapacity(name: 'Eicher 20ft', maxWeightKg: 7000, maxVolumeM3: 33.0),
  'XL': TruckCapacity(
      name: 'Container 32ft', maxWeightKg: 15000, maxVolumeM3: 67.0),
};

/// Number of picks that triggers forklift requirement (> this value).
const int kPickForkLiftThreshold = 1;

/// Number of picks that triggers cart requirement (> this value).
const int kPickCartThreshold = 5;
