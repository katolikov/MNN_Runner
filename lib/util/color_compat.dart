import 'dart:ui';

// Backward-compat shim for Color.withValues used in code.
// Maps `alpha` in 0.0..1.0 to Color.withOpacity.
extension ColorWithValuesCompat on Color {
  Color withValues({double? alpha}) {
    if (alpha != null) {
      return withOpacity(alpha);
    }
    return this;
  }
}

