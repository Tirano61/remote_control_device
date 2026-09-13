import 'package:flutter/services.dart';

/// Formats typing into the `384-729-142` shape the backend expects
/// (`/^\d{3}-\d{3}-\d{3}$/`): digits only, grouped in threes, 9 digits max.
///
/// This is a convenience for the operator, not a security check — the backend
/// validates the value and stays authoritative.
class PublicIdInputFormatter extends TextInputFormatter {
  const PublicIdInputFormatter();

  static const int digitCount = 9;

  /// Number of characters of a fully formatted `publicId`.
  static const int formattedLength = digitCount + 2;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final limited = digits.length > digitCount
        ? digits.substring(0, digitCount)
        : digits;

    final buffer = StringBuffer();
    for (var i = 0; i < limited.length; i++) {
      if (i == 3 || i == 6) buffer.write('-');
      buffer.write(limited[i]);
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
